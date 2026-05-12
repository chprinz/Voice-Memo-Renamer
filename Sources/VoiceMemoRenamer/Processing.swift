import Darwin
import Foundation

struct MacWhisperService {
    var executablePath: String
    var timeoutSeconds: Int

    func version() async throws -> String {
        try await run(arguments: ["version"], timeoutSeconds: 20)
    }

    func transcribe(filePath: String) async throws -> String {
        let output = try await run(arguments: ["transcribe", filePath], timeoutSeconds: timeoutSeconds)
        return formatTranscript(output)
    }

    private func formatTranscript(_ transcript: String) -> String {
        let normalized = transcript
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return "" }

        var blocks: [[String]] = [[]]
        for line in normalized.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty {
                if blocks.last?.isEmpty == false {
                    blocks.append([])
                }
            } else {
                blocks[blocks.count - 1].append(trimmed)
            }
        }

        return blocks
            .filter { !$0.isEmpty }
            .flatMap { balancedParagraphs(from: $0.joined(separator: " ")) }
            .joined(separator: "\n\n")
    }

    private func balancedParagraphs(from text: String) -> [String] {
        let compacted = text.replacingOccurrences(
            of: #"\s+"#,
            with: " ",
            options: .regularExpression
        )
        .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !compacted.isEmpty else { return [] }

        let sentences = splitSentences(compacted)
        guard sentences.count > 1 else {
            return wrapText(compacted, targetLength: 720)
        }

        var paragraphs: [String] = []
        var current: [String] = []
        var currentLength = 0
        for sentence in sentences {
            let nextLength = currentLength + sentence.count + (current.isEmpty ? 0 : 1)
            if !current.isEmpty, current.count >= 4 || nextLength > 720 {
                paragraphs.append(current.joined(separator: " "))
                current = []
                currentLength = 0
            }
            current.append(sentence)
            currentLength += sentence.count + (current.count == 1 ? 0 : 1)
        }
        if !current.isEmpty {
            paragraphs.append(current.joined(separator: " "))
        }
        return paragraphs
    }

    private func splitSentences(_ text: String) -> [String] {
        var sentences: [String] = []
        var current = ""
        for character in text {
            current.append(character)
            if ".!?".contains(character) {
                let sentence = current.trimmingCharacters(in: .whitespacesAndNewlines)
                if !sentence.isEmpty {
                    sentences.append(sentence)
                }
                current = ""
            }
        }
        let remainder = current.trimmingCharacters(in: .whitespacesAndNewlines)
        if !remainder.isEmpty {
            sentences.append(remainder)
        }
        return sentences
    }

    private func wrapText(_ text: String, targetLength: Int) -> [String] {
        var paragraphs: [String] = []
        var current = ""
        for word in text.split(separator: " ").map(String.init) {
            if !current.isEmpty, current.count + word.count + 1 > targetLength {
                paragraphs.append(current)
                current = word
            } else {
                current = current.isEmpty ? word : "\(current) \(word)"
            }
        }
        if !current.isEmpty {
            paragraphs.append(current)
        }
        return paragraphs
    }

    private func run(arguments: [String], timeoutSeconds: Int) async throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executablePath)
        process.arguments = arguments

        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr

        let stdoutBuffer = PipeOutputBuffer(fileHandle: stdout.fileHandleForReading)
        let stderrBuffer = PipeOutputBuffer(fileHandle: stderr.fileHandleForReading)
        let timeoutState = ProcessTimeoutState()
        let effectiveTimeout = max(1, timeoutSeconds)

        do {
            try process.run()
        } catch {
            stdoutBuffer.finish(readRemaining: false)
            stderrBuffer.finish(readRemaining: false)
            throw ProcessingFailure(
                message: "Could not start MacWhisper.",
                details: "\(executablePath)\n\(error.localizedDescription)"
            )
        }

        let waitTask = Task.detached {
            process.waitUntilExit()
            return process.terminationStatus
        }

        let timeoutTask = Task {
            do {
                try await Task.sleep(nanoseconds: UInt64(effectiveTimeout) * 1_000_000_000)
            } catch {
                return
            }
            timeoutState.markTimedOut()
            Self.stop(process)
        }

        let terminationStatus = await withTaskCancellationHandler {
            await waitTask.value
        } onCancel: {
            Self.stop(process)
        }

        timeoutTask.cancel()
        stdoutBuffer.finish()
        stderrBuffer.finish()

        if timeoutState.didTimeOut {
            throw ProcessingFailure(message: "MacWhisper timed out.", details: "No result after \(effectiveTimeout) seconds.")
        }

        try Task.checkCancellation()

        let output = stdoutBuffer.string()
        let errorOutput = stderrBuffer.string()
        guard terminationStatus == 0 else {
            throw ProcessingFailure(message: "MacWhisper failed.", details: errorOutput.isEmpty ? output : errorOutput)
        }
        return output
    }

    private static func stop(_ process: Process) {
        guard process.isRunning else { return }
        let pid = process.processIdentifier
        process.terminate()
        Task.detached {
            do {
                try await Task.sleep(nanoseconds: 2_000_000_000)
            } catch {
                return
            }
            if process.isRunning {
                Darwin.kill(pid, SIGKILL)
            }
        }
    }
}

private final class PipeOutputBuffer {
    private let fileHandle: FileHandle
    private let lock = NSLock()
    private var data = Data()

    init(fileHandle: FileHandle) {
        self.fileHandle = fileHandle
        fileHandle.readabilityHandler = { [weak self] handle in
            let chunk = handle.availableData
            guard !chunk.isEmpty else { return }
            self?.append(chunk)
        }
    }

    func finish(readRemaining: Bool = true) {
        fileHandle.readabilityHandler = nil
        guard readRemaining else { return }
        let remaining = fileHandle.availableData
        if !remaining.isEmpty {
            append(remaining)
        }
    }

    func string() -> String {
        lock.lock()
        let snapshot = data
        lock.unlock()
        return String(data: snapshot, encoding: .utf8) ?? ""
    }

    private func append(_ chunk: Data) {
        lock.lock()
        data.append(chunk)
        lock.unlock()
    }
}

private final class ProcessTimeoutState {
    private let lock = NSLock()
    private var timedOut = false

    var didTimeOut: Bool {
        lock.lock()
        let value = timedOut
        lock.unlock()
        return value
    }

    func markTimedOut() {
        lock.lock()
        timedOut = true
        lock.unlock()
    }
}

struct LMStudioService {
    var baseURL: URL
    var modelID: String?
    var maxTranscriptCharacters: Int

    func analyze(transcript: String) async throws -> AnalysisMetadata {
        let model = try await loadedModel()
        let transcriptLimit = await contextAwareTranscriptLimit(for: model)
        let attempts: [(prompt: String, maxTokens: Int)] = [
            (analysisPrompt(for: transcript, maxCharacters: transcriptLimit), 900),
            (compactAnalysisPrompt(for: transcript, maxCharacters: min(transcriptLimit, 8_000)), 650)
        ]
        var lastJSONFailure: ProcessingFailure?

        for attempt in attempts {
            let body: [String: Any] = [
                "model": model,
                "messages": [
                    ["role": "system", "content": "Return only one compact valid JSON object. No markdown. No explanations. Do not repeat words."],
                    ["role": "user", "content": attempt.prompt]
                ],
                "temperature": 0.0,
                "frequency_penalty": 0.6,
                "max_tokens": attempt.maxTokens,
                "response_format": analysisResponseFormat,
                "stream": false
            ]
            let data = try JSONSerialization.data(withJSONObject: body)
            let responseData = try await post(path: "chat/completions", body: data, timeout: 120)
            let response = try JSONDecoder().decode(ChatCompletionResponse.self, from: responseData)
            guard let choice = response.choices.first else {
                throw ProcessingFailure(message: "LM Studio returned no analysis.", details: String(data: responseData, encoding: .utf8) ?? "")
            }
            let content = choice.message.content.trimmingCharacters(in: .whitespacesAndNewlines)
            let reasoningContent = choice.message.reasoningContent?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let analysisText = content.isEmpty ? reasoningContent : content
            do {
                return try parseAnalysis(from: analysisText, transcript: transcript)
            } catch {
                let rawResponse = String(data: responseData, encoding: .utf8) ?? analysisText
                lastJSONFailure = ProcessingFailure(
                    message: choice.finishReason == "length" ? "LM Studio response was cut off before valid JSON." : "LM Studio returned invalid JSON.",
                    details: "Raw response: \(rawResponse)"
                )
            }
        }

        if lastJSONFailure != nil {
            return fallbackAnalysis(from: transcript)
        }

        throw ProcessingFailure(message: "LM Studio returned no analysis.", details: "")
    }

    private var analysisResponseFormat: [String: Any] {
        [
            "type": "json_schema",
            "json_schema": [
                "name": "voice_memo_analysis",
                "strict": true,
                "schema": [
                    "type": "object",
                    "additionalProperties": false,
                    "properties": [
                        "title": ["type": "string"],
                        "slug": ["type": "string"],
                        "short_slug": ["type": "string"],
                        "summary": ["type": "string"],
                        "themes": [
                            "type": "array",
                            "items": ["type": "string"]
                        ],
                        "mood": ["type": "string"],
                        "suggested_workflow": [
                            "type": "string",
                            "enum": ["obsidianJournal", "obsidianInbox", ""]
                        ]
                    ],
                    "required": [
                        "title",
                        "slug",
                        "short_slug",
                        "summary",
                        "themes",
                        "mood",
                        "suggested_workflow"
                    ]
                ]
            ]
        ]
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
        - Schreibe kein Markdown, keine Analyse und keine Gedankenschritte.
        - Deutsch.
        - title: klarer natürlicher Titel, nicht generisch.
        - title: maximal 80 Zeichen.
        - slug: 5-12 Wörter, maximal 90 Zeichen, klein, bindestriche, keine Umlaute, keine Wiederholungen.
        - short_slug: 2-4 prägnante Wörter aus dem slug, maximal 45 Zeichen.
        - summary: ein kurzer, klarer Satz, maximal 220 Zeichen.
        - summary: keine Details auflisten, nur den Kern des Memos benennen.
        - themes: 3-6 Tags/Themen, jedes maximal 35 Zeichen.
        - mood: optionaler Text; falls unbekannt, leerer String.
        - suggested_workflow: einer von obsidianJournal, obsidianInbox; falls unklar, leerer String.
        - Gib niemals das Transkript oder lange Wortketten im JSON wieder.

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

    private func compactAnalysisPrompt(for transcript: String, maxCharacters: Int) -> String {
        let prepared = prepareTranscript(transcript, maxCharacters: maxCharacters)
        return """
        Analysiere dieses Voice-Memo-Transkript knapp. Antworte nur mit kompaktem JSON:
        {"title":"","slug":"","short_slug":"","summary":"","themes":[],"mood":"","suggested_workflow":""}

        Grenzen:
        title <= 80 Zeichen.
        slug <= 70 Zeichen, lowercase-kebab-case, keine Wiederholungen.
        short_slug <= 35 Zeichen.
        summary <= 180 Zeichen, ein klarer Satz.
        themes: max 5 kurze Strings.
        suggested_workflow: "obsidianJournal", "obsidianInbox" oder "".

        Transkript:
        \(prepared)
        """
    }

    private func prepareTranscript(_ transcript: String, maxCharacters: Int) -> String {
        let safeMaxCharacters = max(1, maxCharacters)
        guard transcript.count > safeMaxCharacters else { return transcript }
        let sectionLength = max(1, safeMaxCharacters / 3)
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

    private func parseAnalysis(from content: String, transcript: String) throws -> AnalysisMetadata {
        guard let start = content.firstIndex(of: "{"), let end = content.lastIndex(of: "}") else {
            throw ProcessingFailure(message: "LM Studio did not return JSON.", details: content)
        }
        let json = String(content[start...end])
        let data = Data(json.utf8)
        let decoded: AnalysisResponse
        do {
            decoded = try JSONDecoder().decode(AnalysisResponse.self, from: data)
        } catch {
            throw ProcessingFailure(message: "LM Studio returned invalid JSON.", details: "\(error.localizedDescription)\n\n\(json)")
        }
        let fallback = fallbackAnalysis(from: transcript)
        let decodedTitle = decoded.title.trimmingCharacters(in: .whitespacesAndNewlines).bounded(to: 80)
        let title = isGarbledText(decodedTitle) ? fallback.title : decodedTitle
        let decodedSummary = boundedSummary(decoded.summary)
        let summary = isGarbledText(decodedSummary) ? fallback.summary : decodedSummary
        let slug = boundedSlug(decoded.slug, fallback: title, maxComponents: 12, maxCharacters: 90)
        let shortSlug = boundedSlug(decoded.shortSlug ?? "", fallback: slug, maxComponents: 4, maxCharacters: 45)
        return AnalysisMetadata(
            title: title.isEmpty ? "Voice Memo" : title,
            slug: slug,
            shortSlug: shortSlug,
            summary: summary,
            themes: boundedThemes(decoded.themes),
            mood: decoded.mood?.bounded(to: 80).nilIfBlank,
            suggestedWorkflow: decoded.suggestedWorkflow?.nilIfBlank
        )
    }

    private func isGarbledText(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }

        let words = trimmed
            .components(separatedBy: CharacterSet.whitespacesAndNewlines.union(.punctuationCharacters))
            .filter { !$0.isEmpty }

        return words.contains { word in
            let normalized = word
                .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
                .lowercased()
            return normalized.count > 55 || hasRepeatedFragment(normalized)
        }
    }

    private func hasRepeatedFragment(_ word: String) -> Bool {
        guard word.count >= 12 else { return false }
        let characters = Array(word)
        for fragmentLength in 3...12 where fragmentLength * 3 <= characters.count {
            var index = 0
            while index + fragmentLength * 3 <= characters.count {
                let fragment = characters[index..<(index + fragmentLength)]
                var repetitions = 1
                var nextIndex = index + fragmentLength
                while nextIndex + fragmentLength <= characters.count,
                      Array(characters[nextIndex..<(nextIndex + fragmentLength)]) == Array(fragment) {
                    repetitions += 1
                    nextIndex += fragmentLength
                }
                if repetitions >= 3 {
                    return true
                }
                index += 1
            }
        }
        return false
    }

    private func boundedSlug(_ value: String, fallback: String, maxComponents: Int, maxCharacters: Int) -> String {
        let source = value.slugSafe.isEmpty ? fallback.slugSafe : value.slugSafe
        var components: [String] = []
        for component in source.split(separator: "-").map(String.init) {
            guard components.last != component else { continue }
            components.append(component)
            let candidate = components.joined(separator: "-")
            if components.count >= maxComponents || candidate.count >= maxCharacters {
                break
            }
        }
        let joined = components.joined(separator: "-")
        return joined.isEmpty ? "voice-memo" : joined.bounded(to: maxCharacters).trimmingCharacters(in: CharacterSet(charactersIn: "-"))
    }

    private func boundedThemes(_ themes: [String]) -> [String] {
        var seen = Set<String>()
        let cleanedThemes: [String] = themes.compactMap { theme -> String? in
            let value = theme.trimmingCharacters(in: .whitespacesAndNewlines).bounded(to: 35)
            guard !value.isEmpty, !seen.contains(value.lowercased()) else { return nil }
            seen.insert(value.lowercased())
            return value
        }
        return Array(cleanedThemes.prefix(6))
    }

    private func boundedSummary(_ summary: String) -> String {
        let compacted = summary.replacingOccurrences(
            of: #"\s+"#,
            with: " ",
            options: .regularExpression
        )
        .trimmingCharacters(in: .whitespacesAndNewlines)
        return compacted.bounded(to: 220)
    }

    private func fallbackAnalysis(from transcript: String) -> AnalysisMetadata {
        let sentences = transcript
            .replacingOccurrences(of: "\n", with: " ")
            .split(whereSeparator: { ".!?".contains($0) })
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        let firstSentence = sentences.first ?? transcript
        let title = firstSentence
            .split(separator: " ")
            .prefix(10)
            .joined(separator: " ")
            .bounded(to: 80)
        let summary = boundedSummary(sentences.first ?? "")
        let slug = boundedSlug(title, fallback: "voice memo", maxComponents: 8, maxCharacters: 70)
        return AnalysisMetadata(
            title: title.isEmpty ? "Voice Memo" : title,
            slug: slug,
            shortSlug: boundedSlug(slug, fallback: "voice memo", maxComponents: 4, maxCharacters: 45),
            summary: summary.isEmpty ? "Transcript was captured, but LM Studio did not return usable JSON." : summary,
            themes: [],
            mood: nil,
            suggestedWorkflow: nil
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

@MainActor
struct ObsidianJournalExporter {
    var settings: AppSettings
    var checkpoint: ((ImportItem) -> Void)?

    func export(_ item: ImportItem) throws -> ImportItem {
        let policy = settings.policy(for: item.workflow)
        let vaultRoot = URL(fileURLWithPath: settings.vaultRootPath)
        let sourceAudioURL = try audioSourceURL(for: item)
        let generatedFilename = FilenamePattern.render(pattern: policy.filenamePattern, item: item, workflowName: policy.name)
        var updated = item
        var exportedAudioURL: URL?

        if policy.audioFileBehavior == .copyToFolder || policy.audioFileBehavior == .moveToFolder {
            let audioDirectory = audioDestinationDirectory(for: policy, vaultRoot: vaultRoot, item: item)
            try FileManager.default.createDirectory(at: audioDirectory, withIntermediateDirectories: true)
            let destinationAudioURL = uniqueURL(in: audioDirectory, filename: generatedFilename)
            if policy.audioFileBehavior == .moveToFolder {
                try FileManager.default.moveItem(at: sourceAudioURL, to: destinationAudioURL)
                updated.originalPath = destinationAudioURL.path
                updated.originalFilename = destinationAudioURL.lastPathComponent
                updated.managedAudioPath = nil
            } else {
                try FileManager.default.copyItem(at: sourceAudioURL, to: destinationAudioURL)
            }
            exportedAudioURL = destinationAudioURL
            updated.fileOperations.append(FileOperationRecord(
                kind: policy.audioFileBehavior == .moveToFolder ? "move" : "copy",
                sourcePath: sourceAudioURL.path,
                destinationPath: destinationAudioURL.path,
                occurredAt: Date()
            ))
            checkpoint?(updated)
        }

        if policy.audioFileBehavior == .renameInPlace {
            let originalURL = sourceAudioURL
            let destinationURL = uniqueURL(in: originalURL.deletingLastPathComponent(), filename: generatedFilename)
            try FileManager.default.moveItem(at: originalURL, to: destinationURL)
            updated.originalPath = destinationURL.path
            updated.originalFilename = destinationURL.lastPathComponent
            if updated.managedAudioPath == originalURL.path {
                updated.managedAudioPath = nil
            }
            updated.fileOperations.append(FileOperationRecord(
                kind: "rename_original",
                sourcePath: originalURL.path,
                destinationPath: destinationURL.path,
                occurredAt: Date()
            ))
            checkpoint?(updated)
        }

        if let markdownURL = try exportTranscriptIfNeeded(
            item: updated,
            policy: policy,
            vaultRoot: vaultRoot,
            audioFilename: exportedAudioURL?.lastPathComponent
        ) {
            updated.exportedMarkdownPath = markdownURL.path
            updated.fileOperations.append(FileOperationRecord(
                kind: policy.transcriptBehavior == .appendToMonthlyNote ? "append" : "write",
                sourcePath: markdownURL.path,
                destinationPath: markdownURL.path,
                occurredAt: Date()
            ))
            checkpoint?(updated)
        }

        updated.status = .imported
        updated.importedAt = Date()
        return updated
    }

    private func audioSourceURL(for item: ImportItem) throws -> URL {
        let originalURL = URL(fileURLWithPath: item.originalPath)
        if FileManager.default.fileExists(atPath: originalURL.path) {
            return originalURL
        }
        if let managedAudioPath = item.managedAudioPath,
           FileManager.default.fileExists(atPath: managedAudioPath) {
            return URL(fileURLWithPath: managedAudioPath)
        }
        throw ProcessingFailure(
            message: "Source audio is not available.",
            details: "Original: \(item.originalPath)\nLegacy processing copy: \(item.managedAudioPath ?? "None")"
        )
    }

    private func audioDestinationDirectory(for policy: WorkflowPolicy, vaultRoot: URL, item: ImportItem) -> URL {
        if !policy.audioDestinationPath.isEmpty {
            return resolvedFolder(policy.audioDestinationPath, vaultRoot: vaultRoot)
        }
        return workflowFolder(for: policy, vaultRoot: vaultRoot, item: item)
    }

    private func transcriptDestinationDirectory(for policy: WorkflowPolicy, vaultRoot: URL, item: ImportItem) -> URL {
        workflowFolder(for: policy, vaultRoot: vaultRoot, item: item)
    }

    private func workflowFolder(for policy: WorkflowPolicy, vaultRoot: URL, item: ImportItem) -> URL {
        policy.destinationPath.isEmpty
            ? URL(fileURLWithPath: item.originalPath).deletingLastPathComponent()
            : resolvedFolder(policy.destinationPath, vaultRoot: vaultRoot)
    }

    private func resolvedFolder(_ path: String, vaultRoot: URL) -> URL {
        let expanded = NSString(string: path).expandingTildeInPath
        if expanded.hasPrefix("/") {
            return URL(fileURLWithPath: expanded, isDirectory: true)
        }
        return vaultRoot.appendingPathComponent(path, isDirectory: true)
    }

    private func exportTranscriptIfNeeded(item: ImportItem, policy: WorkflowPolicy, vaultRoot: URL, audioFilename: String?) throws -> URL? {
        switch policy.transcriptBehavior {
        case .appendToMonthlyNote:
            let monthlyDirectory = transcriptDestinationDirectory(for: policy, vaultRoot: vaultRoot, item: item)
            try FileManager.default.createDirectory(at: monthlyDirectory, withIntermediateDirectories: true)
            let monthlyURL = monthlyDirectory.appendingPathComponent("\(DateFormatter.monthlyNote.string(from: item.recordingDate)).md")
            let entry = markdownEntry(for: item, audioFilename: audioFilename)
            if FileManager.default.fileExists(atPath: monthlyURL.path) {
                let handle = try FileHandle(forWritingTo: monthlyURL)
                try handle.seekToEnd()
                try handle.write(contentsOf: Data(("\n\n" + entry).utf8))
                try handle.close()
            } else {
                try Data((entry + "\n").utf8).write(to: monthlyURL, options: [.atomic])
            }
            return monthlyURL
        case .createMarkdownFile, .saveTranscriptOnly:
            let directory = transcriptDestinationDirectory(for: policy, vaultRoot: vaultRoot, item: item)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let base = FilenamePattern.render(pattern: policy.filenamePattern, item: item, workflowName: policy.name, includeExtension: false)
            let markdownURL = uniqueURL(in: directory, filename: "\(base).md")
            try Data(markdownDocument(for: item, audioFilename: audioFilename).utf8).write(to: markdownURL, options: [.atomic])
            return markdownURL
        case .doNotExportTranscript:
            return nil
        }
    }

    private func markdownEntry(for item: ImportItem, audioFilename: String?) -> String {
        let title = item.analysis?.title ?? item.displayTitle
        let summary = item.analysis?.summary ?? ""
        let transcript = item.transcript ?? ""
        let embed = audioFilename.map { "![[\($0)]]\n" } ?? ""
        return """
        ## \(DateFormatter.itemDate.string(from: item.recordingDate))
        \(embed)**\(title)**

        \(summary)

        \(transcript)
        """
    }

    private func markdownDocument(for item: ImportItem, audioFilename: String?) -> String {
        let title = item.analysis?.title ?? item.displayTitle
        let summary = item.analysis?.summary ?? ""
        let transcript = item.transcript ?? ""
        let embed = audioFilename.map { "![[\($0)]]\n\n" } ?? ""
        return """
        # \(title)

        \(summary)

        \(embed)\(transcript)
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
        let task = Task {
            defer { store.finishProcessingTask(for: id) }
            guard var item = store.item(id: id) else { return }
            guard item.status == .needsAttention || item.status == .failed || item.retryCount < store.settings.retryLimit else {
                item.status = .needsAttention
                item.error = ProcessingError(
                    message: "Retry limit reached.",
                    technicalDetails: "This item already failed \(item.retryCount) time(s). Check MacWhisper or LM Studio settings before starting it again.",
                    occurredAt: Date()
                )
                store.update(item)
                return
            }
            do {
                try Task.checkCancellation()
                item.status = .transcribing
                item.error = nil
                store.update(item)

                let whisper = MacWhisperService(executablePath: store.settings.macWhisperPath, timeoutSeconds: store.settings.transcriptionTimeoutSeconds)
                let transcription = try await transcribe(item: item, with: whisper)
                item = transcription.item
                let transcript = transcription.transcript
                try Task.checkCancellation()
                guard !transcript.isEmpty else {
                    throw ProcessingFailure(message: "MacWhisper returned an empty transcript.", details: item.originalPath)
                }
                item = store.item(id: id) ?? item
                item.transcript = transcript
                item.status = .analyzing
                store.update(item)

                guard let lmStudioURL = URL(string: store.settings.lmStudioBaseURL),
                      lmStudioURL.scheme != nil,
                      lmStudioURL.host != nil else {
                    throw ProcessingFailure(
                        message: "Invalid LM Studio URL.",
                        details: store.settings.lmStudioBaseURL
                    )
                }
                let lm = LMStudioService(
                    baseURL: lmStudioURL,
                    modelID: store.settings.lmStudioModelID,
                    maxTranscriptCharacters: store.settings.maxTranscriptCharactersForAnalysis
                )
                let analysis = try await lm.analyze(transcript: transcript)
                try Task.checkCancellation()
                item = store.item(id: id) ?? item
                item.analysis = analysis
                if let watchFolderWorkflowID = watchFolderWorkflowID(for: item) {
                    item.workflow = watchFolderWorkflowID
                } else if let suggested = analysis.suggestedWorkflow,
                   shouldApplySuggestedWorkflow(suggested, to: item) {
                    item.workflow = suggested
                }
                item.status = .readyForReview
                store.update(item)
                if shouldAutoExport(item) {
                    export(id)
                }
            } catch is CancellationError {
                item = store.item(id: id) ?? item
                item.status = .needsAttention
                item.error = ProcessingError(
                    message: "Processing cancelled.",
                    technicalDetails: "Cancelled by the user before the workflow finished.",
                    occurredAt: Date()
                )
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
        store.registerProcessingTask(task, for: id)
    }

    private func transcribe(item: ImportItem, with whisper: MacWhisperService) async throws -> (transcript: String, item: ImportItem) {
        let sourceURL = try audioSourceURL(for: item)
        do {
            return (try await whisper.transcribe(filePath: sourceURL.path), item)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            try Task.checkCancellation()
            let tempURL = try temporaryProcessingCopyURL(for: sourceURL)
            try FileManager.default.createDirectory(at: AppPaths.processingCacheDirectory, withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: sourceURL, to: tempURL)
            var updated = item
            updated.fileOperations.append(FileOperationRecord(
                kind: "temporary_processing_copy",
                sourcePath: sourceURL.path,
                destinationPath: tempURL.path,
                occurredAt: Date()
            ))
            store.update(updated)
            do {
                let transcript = try await whisper.transcribe(filePath: tempURL.path)
                try? FileManager.default.removeItem(at: tempURL)
                updated.fileOperations.append(FileOperationRecord(
                    kind: "delete_temporary_processing_copy",
                    sourcePath: tempURL.path,
                    destinationPath: "",
                    occurredAt: Date()
                ))
                store.update(updated)
                return (transcript, updated)
            } catch {
                try? FileManager.default.removeItem(at: tempURL)
                var failed = store.item(id: item.id) ?? updated
                failed.fileOperations.append(FileOperationRecord(
                    kind: "delete_temporary_processing_copy",
                    sourcePath: tempURL.path,
                    destinationPath: "",
                    occurredAt: Date()
                ))
                store.update(failed)
                throw error
            }
        }
    }

    private func audioSourceURL(for item: ImportItem) throws -> URL {
        let originalURL = URL(fileURLWithPath: item.originalPath)
        if FileManager.default.fileExists(atPath: originalURL.path) {
            return originalURL
        }
        if let managedAudioPath = item.managedAudioPath,
           FileManager.default.fileExists(atPath: managedAudioPath) {
            return URL(fileURLWithPath: managedAudioPath)
        }
        throw ProcessingFailure(
            message: "Source audio is not available.",
            details: "Original: \(item.originalPath)\nLegacy processing copy: \(item.managedAudioPath ?? "None")"
        )
    }

    private func temporaryProcessingCopyURL(for sourceURL: URL) throws -> URL {
        let ext = sourceURL.pathExtension.isEmpty ? "m4a" : sourceURL.pathExtension
        let filename = FileNaming.filename(
            preferredName: sourceURL.lastPathComponent,
            fallbackBase: sourceURL.deletingPathExtension().lastPathComponent,
            fallbackExtension: ext
        )
        return FileNaming.uniqueURL(in: AppPaths.processingCacheDirectory, filename: filename)
    }

    func export(_ id: ImportItem.ID) {
        guard var item = store.item(id: id) else { return }
        if let watchFolderWorkflowID = watchFolderWorkflowID(for: item) {
            item.workflow = watchFolderWorkflowID
        }
        item.status = .importing
        item.error = nil
        store.update(item)

        do {
            let exporter = ObsidianJournalExporter(settings: store.settings) { [store] checkpoint in
                store.update(checkpoint)
            }
            let exported = try exporter.export(item)
            store.update(exported)
        } catch {
            var failed = store.item(id: id) ?? item
            failed.status = .needsAttention
            failed.error = ProcessingError(
                message: (error as? ProcessingFailure)?.message ?? "Import failed.",
                technicalDetails: (error as? ProcessingFailure)?.details ?? error.localizedDescription,
                occurredAt: Date()
            )
            store.update(failed)
        }
    }

    private func shouldAutoExport(_ item: ImportItem) -> Bool {
        let policy = store.workflowPolicy(for: item.workflow)
        switch policy.reviewBehavior {
        case .autoExportWhenReady:
            return true
        case .requireReview:
            return false
        case .requireReviewWhenUncertain:
            let titleIsMissing = item.analysis?.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false
            return item.recordingDateIsCertain && !titleIsMissing
        }
    }

    private func shouldApplySuggestedWorkflow(_ suggestedWorkflow: String, to item: ImportItem) -> Bool {
        let suggestedID = WorkflowPolicy.canonicalID(suggestedWorkflow)
        guard !suggestedID.isEmpty else { return false }
        guard store.settings.workflows.contains(where: { $0.id == suggestedID && $0.isEnabled }) else {
            return false
        }

        if watchFolderWorkflowID(for: item) != nil {
            return false
        }
        return item.workflow != suggestedID
    }

    private func watchFolderWorkflowID(for item: ImportItem) -> String? {
        let currentPolicy = store.workflowPolicy(for: item.workflow)
        if itemMatchesWatchFolderPolicy(item, currentPolicy) {
            return currentPolicy.id
        }
        return store.settings.workflows.first { itemMatchesWatchFolderPolicy(item, $0) }?.id
    }

    private func itemMatchesWatchFolderPolicy(_ item: ImportItem, _ policy: WorkflowPolicy) -> Bool {
        guard policy.usesWatchFolder else { return false }
        return [item.sourcePath, item.originalPath]
            .compactMap { $0 }
            .contains { isPath($0, inWatchFolderFor: policy) }
    }

    private func isPath(_ path: String, inWatchFolderFor policy: WorkflowPolicy) -> Bool {
        let folderPath = NSString(string: policy.watchFolderPath).expandingTildeInPath
        let standardizedFolderPath = URL(fileURLWithPath: folderPath).standardizedFileURL.path
        let standardizedSourceURL = URL(fileURLWithPath: path).standardizedFileURL
        let sourcePath = standardizedSourceURL.path

        if policy.includeWatchFolderSubfolders {
            return sourcePath == standardizedFolderPath
                || sourcePath.hasPrefix(standardizedFolderPath + "/")
        }
        return standardizedSourceURL.deletingLastPathComponent().path == standardizedFolderPath
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
        struct Message: Decodable {
            var content: String
            var reasoningContent: String?

            enum CodingKeys: String, CodingKey {
                case content
                case reasoningContent = "reasoning_content"
            }
        }

        var message: Message
        var finishReason: String?

        enum CodingKeys: String, CodingKey {
            case message
            case finishReason = "finish_reason"
        }
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
    var suggestedWorkflow: String?

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
