import Foundation

struct MacWhisperService {
    var executablePath: String
    var timeoutSeconds: Int

    func version() async throws -> String {
        try await run(arguments: ["version"], timeoutSeconds: 20)
    }

    func transcribe(filePath: String) async throws -> String {
        let output = try await run(arguments: ["transcribe", filePath], timeoutSeconds: timeoutSeconds)
        return output.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func run(arguments: [String], timeoutSeconds: Int) async throws -> String {
        try await withThrowingTaskGroup(of: String.self) { group in
            group.addTask {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: executablePath)
                process.arguments = arguments

                let stdout = Pipe()
                let stderr = Pipe()
                process.standardOutput = stdout
                process.standardError = stderr

                try process.run()
                process.waitUntilExit()

                let output = String(data: stdout.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                let errorOutput = String(data: stderr.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                guard process.terminationStatus == 0 else {
                    throw ProcessingFailure(message: "MacWhisper failed.", details: errorOutput.isEmpty ? output : errorOutput)
                }
                return output
            }

            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(timeoutSeconds) * 1_000_000_000)
                throw ProcessingFailure(message: "MacWhisper timed out.", details: "No result after \(timeoutSeconds) seconds.")
            }

            let result = try await group.next() ?? ""
            group.cancelAll()
            return result
        }
    }
}

struct LMStudioService {
    var baseURL: URL
    var modelID: String?
    var maxTranscriptCharacters: Int

    func analyze(transcript: String) async throws -> AnalysisMetadata {
        let model = try await loadedModel()
        let transcriptLimit = await contextAwareTranscriptLimit(for: model)
        let prompt = analysisPrompt(for: transcript, maxCharacters: transcriptLimit)
        let body: [String: Any] = [
            "model": model,
            "messages": [
                ["role": "system", "content": "You analyze personal voice memo transcripts. Output only valid JSON."],
                ["role": "user", "content": prompt]
            ],
            "temperature": 0.2,
            "max_tokens": 900,
            "stream": false
        ]
        let data = try JSONSerialization.data(withJSONObject: body)
        let responseData = try await post(path: "chat/completions", body: data, timeout: 90)
        let response = try JSONDecoder().decode(ChatCompletionResponse.self, from: responseData)
        guard let content = response.choices.first?.message.content else {
            throw ProcessingFailure(message: "LM Studio returned no analysis.", details: String(data: responseData, encoding: .utf8) ?? "")
        }
        return try parseAnalysis(from: content)
    }

    private func loadedModel() async throws -> String {
        let data = try await get(path: "models", timeout: 10)
        let response = try JSONDecoder().decode(ModelsResponse.self, from: data)
        if let modelID, !modelID.isEmpty, response.data.contains(where: { $0.id == modelID }) {
            return modelID
        }
        guard let model = response.data.first?.id else {
            throw ProcessingFailure(message: "No LM Studio model is loaded.", details: "Open LM Studio and load a local model.")
        }
        return model
    }

    private func contextAwareTranscriptLimit(for modelID: String) async -> Int {
        guard let info = try? await loadedContextInfo(for: modelID) else {
            return maxTranscriptCharacters
        }
        return min(maxTranscriptCharacters, safeTranscriptCharacterLimit(for: info.loadedContextTokens))
    }

    private func analysisPrompt(for transcript: String, maxCharacters: Int) -> String {
        let prepared = prepareTranscript(transcript, maxCharacters: maxCharacters)
        return """
        Du bekommst ein Voice-Memo-Transkript. Erzeuge strukturierte Review-Daten.

        Regeln:
        - Antworte nur mit einem JSON-Objekt.
        - Deutsch.
        - title: klarer natürlicher Titel, nicht generisch.
        - slug: ausführlich und beschreibend, 5-12 Wörter falls sinnvoll, klein, bindestriche, keine Umlaute.
        - short_slug: 2-4 prägnante Wörter aus dem slug.
        - summary: kurze, konkrete Zusammenfassung in 2-4 Sätzen.
        - themes: 3-8 Tags/Themen.
        - mood: optional.
        - suggested_workflow: optional, einer von obsidianJournal, obsidianInbox.

        JSON:
        {
          "title": "...",
          "slug": "...",
          "short_slug": "...",
          "summary": "...",
          "themes": ["..."],
          "mood": "...",
          "suggested_workflow": "obsidianJournal"
        }

        Transkript:
        \(prepared)
        """
    }

    private func prepareTranscript(_ transcript: String, maxCharacters: Int) -> String {
        guard transcript.count > maxCharacters else { return transcript }
        let sectionLength = maxCharacters / 3
        let start = String(transcript.prefix(sectionLength))
        let end = String(transcript.suffix(sectionLength))
        let middleStart = transcript.index(transcript.startIndex, offsetBy: max(0, transcript.count / 2 - sectionLength / 2))
        let middleEnd = transcript.index(middleStart, offsetBy: min(sectionLength, transcript.distance(from: middleStart, to: transcript.endIndex)))
        let middle = String(transcript[middleStart..<middleEnd])
        return """
        [ANFANG]
        \(start)

        [MITTE]
        \(middle)

        [ENDE]
        \(end)
        """
    }

    private func safeTranscriptCharacterLimit(for contextTokens: Int) -> Int {
        let reservedTokens = 2_500
        let availableTokens = max(2_000, contextTokens - reservedTokens)
        return max(6_000, availableTokens * 3)
    }

    private func loadedContextInfo(for modelID: String) async throws -> LMStudioLoadedContextInfo? {
        let requestURL = nativeBaseURL.appendingPathComponent("models")
        var request = URLRequest(url: requestURL)
        request.timeoutInterval = 10
        let (data, response) = try await URLSession.shared.data(for: request)
        try validate(response: response, data: data, fallbackMessage: "LM Studio model metadata request failed.")
        let decoded = try JSONDecoder().decode(LMStudioNativeModelsResponse.self, from: data)
        let loadedModels = decoded.models.filter { !$0.loadedInstances.isEmpty }
        let selectedModel = loadedModels.first { model in
            model.key == modelID || model.loadedInstances.contains { $0.id == modelID }
        } ?? loadedModels.first
        guard let selectedModel, let instance = selectedModel.loadedInstances.first else {
            return nil
        }
        return LMStudioLoadedContextInfo(loadedContextTokens: instance.config.contextLength)
    }

    private func parseAnalysis(from content: String) throws -> AnalysisMetadata {
        guard let start = content.firstIndex(of: "{"), let end = content.lastIndex(of: "}") else {
            throw ProcessingFailure(message: "LM Studio did not return JSON.", details: content)
        }
        let json = String(content[start...end])
        let data = Data(json.utf8)
        let decoded = try JSONDecoder().decode(AnalysisResponse.self, from: data)
        let slug = decoded.slug.slugSafe
        let shortSlug = (decoded.shortSlug?.slugSafe.isEmpty == false ? decoded.shortSlug!.slugSafe : slug.split(separator: "-").prefix(3).joined(separator: "-"))
        return AnalysisMetadata(
            title: decoded.title.trimmingCharacters(in: .whitespacesAndNewlines),
            slug: slug,
            shortSlug: shortSlug,
            summary: decoded.summary.trimmingCharacters(in: .whitespacesAndNewlines),
            themes: decoded.themes,
            mood: decoded.mood,
            suggestedWorkflow: decoded.suggestedWorkflow
        )
    }

    private func get(path: String, timeout: TimeInterval) async throws -> Data {
        var request = URLRequest(url: baseURL.appendingPathComponent(path))
        request.timeoutInterval = timeout
        let (data, response) = try await URLSession.shared.data(for: request)
        try validate(response: response, data: data, fallbackMessage: "LM Studio request failed.")
        return data
    }

    private func post(path: String, body: Data, timeout: TimeInterval) async throws -> Data {
        var request = URLRequest(url: baseURL.appendingPathComponent(path))
        request.timeoutInterval = timeout
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = body
        let (data, response) = try await URLSession.shared.data(for: request)
        try validate(response: response, data: data, fallbackMessage: "LM Studio analysis request failed.")
        return data
    }

    private var nativeBaseURL: URL {
        if baseURL.path.hasSuffix("/v1") {
            return baseURL
                .deletingLastPathComponent()
                .appendingPathComponent("api")
                .appendingPathComponent("v1")
        }
        return baseURL
            .appendingPathComponent("api")
            .appendingPathComponent("v1")
    }

    private func validate(response: URLResponse, data: Data, fallbackMessage: String) throws {
        guard let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) else {
            return
        }
        let body = String(data: data, encoding: .utf8) ?? ""
        throw ProcessingFailure(
            message: fallbackMessage,
            details: "HTTP \(http.statusCode): \(body)"
        )
    }
}

struct ObsidianJournalExporter {
    var settings: AppSettings

    func export(_ item: ImportItem) throws -> ImportItem {
        guard item.workflow == .obsidianJournal else {
            throw ProcessingFailure(message: "Workflow is not implemented yet.", details: item.workflow.label)
        }
        guard let managedAudioPath = item.managedAudioPath else {
            throw ProcessingFailure(message: "No managed audio file is available.", details: item.originalPath)
        }

        let vaultRoot = URL(fileURLWithPath: settings.vaultRootPath)
        let audioDirectory = vaultRoot.appendingPathComponent(settings.journalAudioRelativePath, isDirectory: true)
        let monthlyDirectory = vaultRoot.appendingPathComponent(settings.monthlyNotesRelativePath, isDirectory: true)
        try FileManager.default.createDirectory(at: audioDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: monthlyDirectory, withIntermediateDirectories: true)

        let sourceAudioURL = URL(fileURLWithPath: managedAudioPath)
        let datePart = DateFormatter.filenameDate.string(from: item.recordingDate)
        let slug = item.analysis?.shortSlug ?? item.analysis?.slug ?? sourceAudioURL.deletingPathExtension().lastPathComponent.slugSafe
        let audioFilename = "\(datePart)_\(slug)_memo.\(sourceAudioURL.pathExtension.isEmpty ? "m4a" : sourceAudioURL.pathExtension)"
        let destinationAudioURL = uniqueURL(in: audioDirectory, filename: audioFilename)
        try FileManager.default.copyItem(at: sourceAudioURL, to: destinationAudioURL)

        let monthlyURL = monthlyDirectory.appendingPathComponent("\(DateFormatter.monthlyNote.string(from: item.recordingDate)).md")
        let entry = markdownEntry(for: item, audioFilename: destinationAudioURL.lastPathComponent)
        if FileManager.default.fileExists(atPath: monthlyURL.path) {
            let handle = try FileHandle(forWritingTo: monthlyURL)
            try handle.seekToEnd()
            try handle.write(contentsOf: Data(("\n\n" + entry).utf8))
            try handle.close()
        } else {
            try Data((entry + "\n").utf8).write(to: monthlyURL, options: [.atomic])
        }

        var updated = item
        updated.status = .imported
        updated.importedAt = Date()
        updated.exportedMarkdownPath = monthlyURL.path
        updated.fileOperations.append(FileOperationRecord(
            kind: "copy",
            sourcePath: sourceAudioURL.path,
            destinationPath: destinationAudioURL.path,
            occurredAt: Date()
        ))
        updated.fileOperations.append(FileOperationRecord(
            kind: "append",
            sourcePath: monthlyURL.path,
            destinationPath: monthlyURL.path,
            occurredAt: Date()
        ))
        return updated
    }

    private func markdownEntry(for item: ImportItem, audioFilename: String) -> String {
        let title = item.analysis?.title ?? item.displayTitle
        let summary = item.analysis?.summary ?? ""
        let transcript = item.transcript ?? ""
        return """
        ## \(DateFormatter.itemDate.string(from: item.recordingDate))
        ![[\(audioFilename)]]
        **\(title)**

        \(summary)

        \(transcript)
        """
    }

    private func uniqueURL(in directory: URL, filename: String) -> URL {
        let base = (filename as NSString).deletingPathExtension
        let ext = (filename as NSString).pathExtension
        var candidate = directory.appendingPathComponent(filename)
        var counter = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = directory.appendingPathComponent("\(base)-\(counter)").appendingPathExtension(ext)
            counter += 1
        }
        return candidate
    }
}

@MainActor
final class ImportProcessor {
    private let store: ImportStore

    init(store: ImportStore) {
        self.store = store
    }

    func process(_ id: ImportItem.ID) {
        Task {
            guard var item = store.item(id: id), let path = item.managedAudioPath else { return }
            guard item.retryCount < store.settings.retryLimit else {
                item.status = .needsAttention
                item.error = ProcessingError(
                    message: "Retry limit reached.",
                    technicalDetails: "This item already failed \(item.retryCount) time(s). Check MacWhisper or LM Studio settings before trying again.",
                    occurredAt: Date()
                )
                store.update(item)
                return
            }
            do {
                item.status = .transcribing
                item.error = nil
                store.update(item)

                let whisper = MacWhisperService(executablePath: store.settings.macWhisperPath, timeoutSeconds: store.settings.transcriptionTimeoutSeconds)
                let transcript = try await whisper.transcribe(filePath: path)
                guard !transcript.isEmpty else {
                    throw ProcessingFailure(message: "MacWhisper returned an empty transcript.", details: path)
                }
                item = store.item(id: id) ?? item
                item.transcript = transcript
                item.status = .analyzing
                store.update(item)

                let lm = LMStudioService(
                    baseURL: URL(string: store.settings.lmStudioBaseURL) ?? URL(string: "http://localhost:1234/v1")!,
                    modelID: store.settings.lmStudioModelID,
                    maxTranscriptCharacters: store.settings.maxTranscriptCharactersForAnalysis
                )
                let analysis = try await lm.analyze(transcript: transcript)
                item = store.item(id: id) ?? item
                item.analysis = analysis
                if let suggested = analysis.suggestedWorkflow {
                    item.workflow = suggested
                }
                item.status = .readyForReview
                store.update(item)
            } catch {
                item = store.item(id: id) ?? item
                item.retryCount += 1
                item.status = .needsAttention
                item.error = ProcessingError(
                    message: (error as? ProcessingFailure)?.message ?? "Processing failed.",
                    technicalDetails: (error as? ProcessingFailure)?.details ?? error.localizedDescription,
                    occurredAt: Date()
                )
                store.update(item)
            }
        }
    }

    func export(_ id: ImportItem.ID) {
        guard var item = store.item(id: id) else { return }
        item.status = .importing
        item.error = nil
        store.update(item)

        do {
            let exporter = ObsidianJournalExporter(settings: store.settings)
            let exported = try exporter.export(item)
            store.update(exported)
        } catch {
            item.status = .needsAttention
            item.error = ProcessingError(
                message: (error as? ProcessingFailure)?.message ?? "Import failed.",
                technicalDetails: (error as? ProcessingFailure)?.details ?? error.localizedDescription,
                occurredAt: Date()
            )
            store.update(item)
        }
    }
}

struct ProcessingFailure: Error {
    var message: String
    var details: String
}

private struct ModelsResponse: Decodable {
    struct Model: Decodable { var id: String }
    var data: [Model]
}

private struct LMStudioLoadedContextInfo {
    var loadedContextTokens: Int
}

private struct LMStudioNativeModelsResponse: Decodable {
    struct Model: Decodable {
        struct LoadedInstance: Decodable {
            struct Config: Decodable {
                var contextLength: Int

                enum CodingKeys: String, CodingKey {
                    case contextLength = "context_length"
                }
            }

            var id: String
            var config: Config
        }

        var key: String
        var loadedInstances: [LoadedInstance]

        enum CodingKeys: String, CodingKey {
            case key
            case loadedInstances = "loaded_instances"
        }
    }

    var models: [Model]
}

private struct ChatCompletionResponse: Decodable {
    struct Choice: Decodable {
        struct Message: Decodable { var content: String }
        var message: Message
    }
    var choices: [Choice]
}

private struct AnalysisResponse: Decodable {
    var title: String
    var slug: String
    var shortSlug: String?
    var summary: String
    var themes: [String]
    var mood: String?
    var suggestedWorkflow: WorkflowID?

    enum CodingKeys: String, CodingKey {
        case title
        case slug
        case shortSlug = "short_slug"
        case summary
        case themes
        case mood
        case suggestedWorkflow = "suggested_workflow"
    }
}
