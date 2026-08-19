import Darwin
import Foundation
import NaturalLanguage

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
            let details = errorOutput.isEmpty
                ? (output.isEmpty ? "MacWhisper exited with status \(terminationStatus) without error output." : output)
                : errorOutput
            throw ProcessingFailure(message: "MacWhisper failed.", details: details)
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
        let (model, contextTokens) = try await loadedModel()
        let transcriptLimit = contextTokens.map { min(maxTranscriptCharacters, safeTranscriptCharacterLimit(for: $0)) } ?? maxTranscriptCharacters
        // Reasoning models spend most of their budget before writing any JSON, so the
        // budget grows on the retry instead of shrinking. A budget that runs out mid-thought
        // used to end up as a silent first-sentence fallback that looked like a real result.
        let attempts: [(prompt: String, maxTokens: Int)] = [
            (analysisPrompt(for: transcript, maxCharacters: transcriptLimit), 2_400),
            (compactAnalysisPrompt(for: transcript, maxCharacters: min(transcriptLimit, 8_000)), 4_000)
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
                // Honoured by LM Studio for models with a thinking mode, ignored otherwise.
                "chat_template_kwargs": ["enable_thinking": false],
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
                let ranOutOfRoom = choice.finishReason == "length"
                lastJSONFailure = ProcessingFailure(
                    message: ranOutOfRoom
                        ? "LM Studio ran out of room before writing any JSON."
                        : "LM Studio returned invalid JSON.",
                    details: (ranOutOfRoom
                        ? "The model used its whole answer budget on internal reasoning. Load a model without a thinking mode, or turn thinking off for this model in LM Studio.\n\n"
                        : "")
                        + "Raw response: \(rawResponse)"
                )
            }
        }

        // Deliberately not falling back to a made-up analysis. The old fallback copied the
        // first sentence of the transcript into both title and summary, which looked like a
        // real result and hid the fact that analysis never happened.
        if let lastJSONFailure {
            throw lastJSONFailure
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
                        "summary_points": [
                            "type": "array",
                            "items": ["type": "string"]
                        ],
                        "spoken_datetime": ["type": "string"],
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
                        "summary_points",
                        "spoken_datetime",
                        "themes",
                        "mood",
                        "suggested_workflow"
                    ]
                ]
            ]
        ]
    }

    private func loadedModel() async throws -> (id: String, contextTokens: Int?) {
        let data = try await nativeGet(path: "models", timeout: 10)
        let decoded = try JSONDecoder().decode(LMStudioNativeModelsResponse.self, from: data)
        let loadedModels = decoded.models.filter { !$0.loadedInstances.isEmpty }
        guard !loadedModels.isEmpty else {
            throw ProcessingFailure(
                message: "No LM Studio model is loaded.",
                details: "Open LM Studio and load a local model, then try again."
            )
        }
        let selectedModel = loadedModels.first { model in
            model.key == modelID || model.loadedInstances.contains { $0.id == modelID }
        } ?? loadedModels[0]
        let instance = selectedModel.loadedInstances[0]
        return (instance.id, instance.config.contextLength)
    }

    private func analysisPrompt(for transcript: String, maxCharacters: Int) -> String {
        let prepared = prepareTranscript(transcript, maxCharacters: maxCharacters)
        let outputLanguage = outputLanguage(for: transcript)
        return """
        Du bekommst ein Voice-Memo-Transkript. Erzeuge strukturierte Review-Daten.

        Regeln:
        - Antworte nur mit einem JSON-Objekt.
        - Schreibe kein Markdown, keine Analyse und keine Gedankenschritte.
        - Ausgabesprache für title, summary, themes und mood: \(outputLanguage.promptName).
        - title: benenne konkret, worum es in dieser Aufnahme geht.
        - title: nenne die konkrete Sache: Entscheidung, Ort, Person, Gegenstand, Ereignis oder Frage, die wirklich vorkommt.
        - title: keine allgemeinen Themenüberschriften wie "Reflexion über Achtsamkeit", "Gedanken zum Sein" oder "Präsenz im Moment".
        - title: keine Ratgeber- oder Coachingsprache, keine Verlaufsform als Überschrift.
        - title: maximal 80 Zeichen.
        - slug: 5-12 Wörter in derselben Ausgabesprache, maximal 90 Zeichen, klein, bindestriche, keine Umlaute, keine Wiederholungen.
        - short_slug: 2-4 prägnante Wörter aus dem slug, maximal 45 Zeichen.
        - summary: ein kurzer, klarer Satz, maximal 220 Zeichen.
        - summary: muss etwas sagen, das nicht schon im title steht; formuliere den title nicht um.
        - summary: konkret und sachlich, keine Deutung, keine allgemeine Lebensweisheit.
        - summary_points: 2-4 sehr kurze Stichpunkte, je maximal 90 Zeichen, keine ganzen Sätze, kein Punkt am Ende.
        - spoken_datetime: nur wenn am Anfang oder Ende der Aufnahme ein Datum oder eine Uhrzeit ausdrücklich gesagt wird.
        - spoken_datetime: Format YYYY-MM-DD oder YYYY-MM-DD HH:MM. Nichts erfinden. Sonst leerer String.
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
          "summary_points": ["..."],
          "spoken_datetime": "",
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
        let outputLanguage = outputLanguage(for: transcript)
        return """
        Analysiere dieses Voice-Memo-Transkript knapp. Antworte nur mit kompaktem JSON:
        {"title":"","slug":"","short_slug":"","summary":"","summary_points":[],"spoken_datetime":"","themes":[],"mood":"","suggested_workflow":""}

        Grenzen:
        title, summary, themes und mood: \(outputLanguage.promptName).
        title <= 80 Zeichen, konkret, keine allgemeine Themenüberschrift.
        slug <= 70 Zeichen, \(outputLanguage.promptName), lowercase-kebab-case, keine Wiederholungen.
        short_slug <= 35 Zeichen.
        summary <= 180 Zeichen, ein klarer Satz, keine Wiederholung des title.
        summary_points: 2-4 Stichpunkte, je <= 90 Zeichen.
        spoken_datetime: nur ein am Anfang oder Ende gesagtes Datum, YYYY-MM-DD[ HH:MM], sonst "".
        themes: max 5 kurze Strings.
        suggested_workflow: "obsidianJournal", "obsidianInbox" oder "".

        Transkript:
        \(prepared)
        """
    }

    private func outputLanguage(for transcript: String) -> AnalysisOutputLanguage {
        let sample = String(transcript.prefix(8_000))
        guard !sample.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return .german
        }

        let recognizer = NLLanguageRecognizer()
        recognizer.processString(sample)
        let hypotheses = recognizer.languageHypotheses(withMaximum: 3)
        let englishConfidence = hypotheses[.english] ?? 0
        let germanConfidence = hypotheses[.german] ?? 0

        if recognizer.dominantLanguage == .english,
           englishConfidence >= 0.45,
           englishConfidence >= germanConfidence * 1.2 {
            return .english
        }

        let cueScores = languageCueScores(in: sample)
        if cueScores.english >= 8,
           cueScores.english >= cueScores.german * 2 {
            return .english
        }

        return .german
    }

    private func languageCueScores(in text: String) -> (english: Int, german: Int) {
        let words = text
            .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
            .lowercased()
            .components(separatedBy: CharacterSet.letters.inverted)
            .filter { !$0.isEmpty }

        var english = 0
        var german = 0
        for word in words {
            if Self.englishLanguageCues.contains(word) {
                english += 1
            }
            if Self.germanLanguageCues.contains(word) {
                german += 1
            }
        }
        return (english, german)
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
            title: title.isEmpty ? fallback.title : title,
            slug: slug,
            shortSlug: shortSlug,
            summary: summary.isEmpty ? fallback.summary : summary,
            themes: boundedThemes(decoded.themes),
            mood: decoded.mood?.bounded(to: 80).nilIfBlank,
            suggestedWorkflow: decoded.suggestedWorkflow?.nilIfBlank,
            summaryPoints: boundedSummaryPoints(decoded.summaryPoints ?? []),
            spokenDate: TranscriptDateExtractor.parseModelValue(decoded.spokenDatetime, referenceDate: Date())
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

    private func boundedSummaryPoints(_ points: [String]) -> [String] {
        var seen = Set<String>()
        let cleaned: [String] = points.compactMap { point -> String? in
            let value = point
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .trimmingCharacters(in: CharacterSet(charactersIn: "-•* "))
                .bounded(to: 90)
            guard !value.isEmpty, !isGarbledText(value), !seen.contains(value.lowercased()) else { return nil }
            seen.insert(value.lowercased())
            return value
        }
        return Array(cleaned.prefix(4))
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
        let outputLanguage = outputLanguage(for: transcript)
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
        let slug = boundedSlug(title, fallback: outputLanguage.slugFallback, maxComponents: 8, maxCharacters: 70)
        return AnalysisMetadata(
            title: title.isEmpty ? outputLanguage.fallbackTitle : title,
            slug: slug,
            shortSlug: boundedSlug(slug, fallback: outputLanguage.slugFallback, maxComponents: 4, maxCharacters: 45),
            summary: summary.isEmpty ? outputLanguage.fallbackSummary : summary,
            themes: [],
            mood: nil,
            suggestedWorkflow: nil
        )
    }

    private static let englishLanguageCues: Set<String> = [
        "about", "after", "and", "are", "because", "but", "can", "could", "for", "from",
        "have", "how", "into", "just", "like", "not", "of", "our", "should", "that",
        "the", "then", "there", "this", "to", "was", "we", "were", "what", "when",
        "where", "which", "with", "would", "you", "your"
    ]

    private static let germanLanguageCues: Set<String> = [
        "aber", "also", "am", "auf", "aus", "bei", "bin", "das", "dass", "dem",
        "den", "der", "die", "du", "ein", "eine", "einem", "einen", "einer", "es",
        "fur", "habe", "hat", "ich", "im", "ist", "mit", "nicht", "oder", "sind",
        "und", "von", "war", "was", "weil", "wenn", "wie", "wir", "zu"
    ]

    private func nativeGet(path: String, timeout: TimeInterval) async throws -> Data {
        var request = URLRequest(url: nativeBaseURL.appendingPathComponent(path))
        request.timeoutInterval = timeout
        let (data, response) = try await data(for: request)
        try validate(response: response, data: data, fallbackMessage: "LM Studio model metadata request failed.")
        return data
    }

    private func post(path: String, body: Data, timeout: TimeInterval) async throws -> Data {
        var request = URLRequest(url: baseURL.appendingPathComponent(path))
        request.timeoutInterval = timeout
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = body
        let (data, response) = try await data(for: request)
        try validate(response: response, data: data, fallbackMessage: "LM Studio analysis request failed.")
        return data
    }

    private func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        do {
            return try await URLSession.shared.data(for: request)
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as URLError {
            throw ProcessingFailure(
                message: lmStudioConnectionMessage(for: error),
                details: "\(request.url?.absoluteString ?? baseURL.absoluteString)\n\(error.localizedDescription)\n\nCheck that LM Studio is running, the server is started, and the selected model is loaded."
            )
        } catch {
            throw ProcessingFailure(
                message: "LM Studio request failed.",
                details: "\(request.url?.absoluteString ?? baseURL.absoluteString)\n\(error.localizedDescription)"
            )
        }
    }

    private func lmStudioConnectionMessage(for error: URLError) -> String {
        switch error.code {
        case .cannotConnectToHost, .cannotFindHost, .dnsLookupFailed:
            return "Cannot reach LM Studio."
        case .networkConnectionLost, .notConnectedToInternet:
            return "Connection to LM Studio was interrupted."
        case .timedOut:
            return "LM Studio request timed out."
        default:
            return "LM Studio request failed."
        }
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

private enum AnalysisOutputLanguage {
    case german
    case english

    var promptName: String {
        switch self {
        case .german: return "Deutsch"
        case .english: return "English"
        }
    }

    var fallbackTitle: String {
        switch self {
        case .german: return "Sprachnotiz"
        case .english: return "Voice Memo"
        }
    }

    var slugFallback: String {
        switch self {
        case .german: return "sprachnotiz"
        case .english: return "voice memo"
        }
    }

    var fallbackSummary: String {
        switch self {
        case .german: return "Transkript wurde erfasst, aber LM Studio hat kein brauchbares JSON geliefert."
        case .english: return "Transcript was captured, but LM Studio did not return usable JSON."
        }
    }
}

/// Nonisolated on purpose: copying, compressing and normalising audio blocks for
/// seconds, and running that on the main actor froze the whole window, including any
/// sheet opened on top of it.
struct ObsidianJournalExporter {
    var settings: AppSettings
    /// Awaited at each step, so a checkpoint can never land after the final result.
    var checkpoint: (@Sendable (ImportItem) async -> Void)?

    func export(_ item: ImportItem) async throws -> ImportItem {
        let policy = settings.policy(for: item.workflow)
        let vaultRoot = URL(fileURLWithPath: settings.vaultRootPath)
        let generatedFilename = FilenamePattern.render(pattern: policy.filenamePattern, item: item, workflowName: policy.name)
        var updated = item
        var exportedAudioURL: URL?

        if policy.audioFileBehavior == .copyToFolder || policy.audioFileBehavior == .moveToFolder {
            let sourceAudioURL = try audioSourceURL(for: item, behavior: policy.audioFileBehavior)
            let audioDirectory = audioDestinationDirectory(for: policy, vaultRoot: vaultRoot, item: item)
            try FileManager.default.createDirectory(at: audioDirectory, withIntermediateDirectories: true)

            let isMove = policy.audioFileBehavior == .moveToFolder
            let willCompress = settings.compressAudioOnExport
                && AudioCompressor.shouldCompress(sourceAudioURL, targetBitrateKbps: settings.compressionBitrateKbps)
            let willNormalize = settings.normalizeAudio

            var processedAudioURL = sourceAudioURL
            var normalizedTempURL: URL?
            if willNormalize {
                if let existing = item.normalizedAudioPath, FileManager.default.fileExists(atPath: existing) {
                    // Normalized before transcription; reuse it instead of running loudnorm twice.
                    processedAudioURL = URL(fileURLWithPath: existing)
                } else {
                    let tempURL = try AudioNormalizer.normalizedCopy(of: sourceAudioURL, ffmpegPath: settings.ffmpegPath)
                    processedAudioURL = tempURL
                    normalizedTempURL = tempURL
                }
            }

            let willReencode = willCompress || willNormalize
            let audioFilename = willReencode
                ? (generatedFilename as NSString).deletingPathExtension + (willCompress ? ".m4a" : ".wav")
                : generatedFilename
            let destinationAudioURL = uniqueURL(in: audioDirectory, filename: audioFilename)

            if willCompress {
                try AudioCompressor.compress(
                    source: processedAudioURL,
                    to: destinationAudioURL,
                    bitrateKbps: settings.compressionBitrateKbps,
                    forceMono: settings.compressionForceMono
                )
                if isMove {
                    try? FileManager.default.removeItem(at: sourceAudioURL)
                }
            } else if willNormalize {
                try FileManager.default.copyItem(at: processedAudioURL, to: destinationAudioURL)
                if isMove {
                    try? FileManager.default.removeItem(at: sourceAudioURL)
                }
            } else if isMove {
                try FileManager.default.moveItem(at: sourceAudioURL, to: destinationAudioURL)
            } else {
                try FileManager.default.copyItem(at: sourceAudioURL, to: destinationAudioURL)
            }

            if let normalizedTempURL {
                try? FileManager.default.removeItem(at: normalizedTempURL)
            }

            if isMove {
                updated.originalPath = destinationAudioURL.path
                updated.originalFilename = destinationAudioURL.lastPathComponent
                updated.managedAudioPath = nil
            }

            exportedAudioURL = destinationAudioURL
            updated.fileOperations.append(FileOperationRecord(
                kind: (willNormalize ? "normalize_" : "") + (willCompress ? "compress_" : "") + (isMove ? "move" : "copy"),
                sourcePath: sourceAudioURL.path,
                destinationPath: destinationAudioURL.path,
                occurredAt: Date()
            ))
            await checkpoint?(updated)
        }

        if policy.audioFileBehavior == .renameInPlace {
            let originalURL = try audioSourceURL(for: updated, behavior: policy.audioFileBehavior)
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
            await checkpoint?(updated)
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
            await checkpoint?(updated)
        }

        updated.status = .imported
        updated.importedAt = Date()
        return updated
    }

    private func audioSourceURL(for item: ImportItem, behavior: AudioFileBehavior) throws -> URL {
        let originalURL = URL(fileURLWithPath: item.originalPath)
        let managedURL = item.managedAudioPath.map { URL(fileURLWithPath: $0) }

        if behavior == .renameInPlace {
            if FileManager.default.fileExists(atPath: originalURL.path) {
                return originalURL
            }
            throw ProcessingFailure(
                message: "Original audio cannot be renamed in place.",
                details: "The original file is no longer at its original path. Choose a copy or move workflow, or put the file back and try again.\n\nOriginal: \(item.originalPath)\nTemporary copy: \(item.managedAudioPath ?? "None")"
            )
        }

        if let managedURL, FileManager.default.fileExists(atPath: managedURL.path) {
            return managedURL
        }
        if FileManager.default.fileExists(atPath: originalURL.path) {
            return originalURL
        }
        throw ProcessingFailure(
            message: "The original audio is not available.",
            details: "Original: \(item.originalPath)\nTemporary copy: \(item.managedAudioPath ?? "None")"
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
            let entry = markdownEntry(for: item, policy: policy, audioFilename: audioFilename)
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
            try Data(markdownDocument(for: item, policy: policy, audioFilename: audioFilename).utf8).write(to: markdownURL, options: [.atomic])
            return markdownURL
        case .doNotExportTranscript:
            return nil
        }
    }

    private func markdownEntry(for item: ImportItem, policy: WorkflowPolicy, audioFilename: String?) -> String {
        var blocks = ["## \(DateFormatter.itemDate.string(from: item.recordingDate))"]
        if let audioFilename {
            blocks[0] += "\n![[\(audioFilename)]]"
        }
        if policy.noteIncludesTitle {
            blocks[0] += "\n**\(item.analysis?.title ?? item.displayTitle)**"
        }
        blocks.append(contentsOf: summaryBlock(for: item, policy: policy))
        if let transcript = item.transcript?.nilIfBlank {
            blocks.append(transcript)
        }
        return blocks.joined(separator: "\n\n")
    }

    private func markdownDocument(for item: ImportItem, policy: WorkflowPolicy, audioFilename: String?) -> String {
        var blocks: [String] = []
        if policy.noteIncludesTitle {
            blocks.append("# \(item.analysis?.title ?? item.displayTitle)")
        }
        blocks.append(contentsOf: summaryBlock(for: item, policy: policy))
        if let audioFilename {
            blocks.append("![[\(audioFilename)]]")
        }
        if let transcript = item.transcript?.nilIfBlank {
            blocks.append(transcript)
        }
        return blocks.joined(separator: "\n\n") + "\n"
    }

    private func summaryBlock(for item: ImportItem, policy: WorkflowPolicy) -> [String] {
        switch policy.summaryStyle {
        case .none:
            return []
        case .sentence:
            guard let summary = item.analysis?.summary.nilIfBlank else { return [] }
            return [summary]
        case .bullets:
            let points = item.analysis?.summaryPoints?.compactMap(\.nilIfBlank) ?? []
            if points.isEmpty {
                guard let summary = item.analysis?.summary.nilIfBlank else { return [] }
                return ["- \(summary)"]
            }
            return [points.map { "- \($0)" }.joined(separator: "\n")]
        }
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
                let transcript: String
                if let cachedTranscript = item.transcript, !cachedTranscript.isEmpty {
                    transcript = cachedTranscript
                } else {
                    item.status = .transcribing
                    item.error = nil
                    store.update(item)

                    // Levels from field recorders are often far too low for reliable
                    // transcription, so normalization happens here rather than at export.
                    item = try await normalizeIfNeeded(item)

                    let whisper = MacWhisperService(executablePath: store.settings.macWhisperPath, timeoutSeconds: store.settings.transcriptionTimeoutSeconds)
                    let transcription = try await transcribe(item: item, with: whisper)
                    item = transcription.item
                    transcript = transcription.transcript
                    try Task.checkCancellation()
                    guard !transcript.isEmpty else {
                        throw ProcessingFailure(message: "MacWhisper returned an empty transcript.", details: item.originalPath)
                    }
                }
                item = store.item(id: id) ?? item
                item.transcript = transcript
                item.error = nil

                if store.workflowPolicy(for: item.workflow).usesSmartAnalysis {
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
                } else {
                    item.analysis = Self.filenameOnlyAnalysis(for: item)
                }

                item = applySpokenRecordingDate(from: transcript, to: item)
                item = applyAutomaticWorkflow(to: item)
                item.status = .readyForReview
                store.update(item)
                if shouldAutoExport(item) {
                    await export(id)
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

    /// Produces the loudness-normalized copy that both transcription and the exported
    /// audio use. Runs once per item and is reused on retries.
    private func normalizeIfNeeded(_ item: ImportItem) async throws -> ImportItem {
        guard store.settings.normalizeAudio else { return item }
        if let existing = item.normalizedAudioPath, FileManager.default.fileExists(atPath: existing) {
            return item
        }

        let sourceURL = try audioSourceURL(for: item)
        let ffmpegPath = store.settings.ffmpegPath
        let normalizedURL = try await Task.detached(priority: .userInitiated) {
            try AudioNormalizer.normalizedCopy(of: sourceURL, ffmpegPath: ffmpegPath)
        }.value

        var updated = store.item(id: item.id) ?? item
        updated.normalizedAudioPath = normalizedURL.path
        updated.fileOperations.append(FileOperationRecord(
            kind: "normalize",
            sourcePath: sourceURL.path,
            destinationPath: normalizedURL.path,
            occurredAt: Date()
        ))
        store.update(updated)
        return updated
    }

    private func transcribe(item: ImportItem, with whisper: MacWhisperService) async throws -> (transcript: String, item: ImportItem) {
        let sourceURL = try transcriptionSourceURL(for: item)

        // 32 bit float WAV from wireless field recorders is converted up front. It is the
        // format that has caused trouble in practice, and converting is cheap next to
        // transcription.
        if AudioInspector.needsTranscodingForTranscription(sourceURL) {
            return try await transcribeConverted(item: item, sourceURL: sourceURL, with: whisper)
        }

        do {
            return (try await whisper.transcribe(filePath: sourceURL.path), item)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            try Task.checkCancellation()
            return try await transcribeConverted(item: item, sourceURL: sourceURL, with: whisper)
        }
    }

    /// Transcribes a plain 16 bit PCM copy of the source, so odd sample formats and
    /// unreadable originals both get a second chance.
    private func transcribeConverted(item: ImportItem, sourceURL: URL, with whisper: MacWhisperService) async throws -> (transcript: String, item: ImportItem) {
        let ffmpegPath = store.settings.ffmpegPath
        let convertedURL = try await Task.detached(priority: .userInitiated) {
            try AudioTranscoder.transcodeForTranscription(source: sourceURL, ffmpegPath: ffmpegPath)
        }.value

        var updated = item
        updated.fileOperations.append(FileOperationRecord(
            kind: "temporary_processing_copy",
            sourcePath: sourceURL.path,
            destinationPath: convertedURL.path,
            occurredAt: Date()
        ))
        store.update(updated)

        defer {
            try? FileManager.default.removeItem(at: convertedURL)
            var cleaned = store.item(id: item.id) ?? updated
            cleaned.fileOperations.append(FileOperationRecord(
                kind: "delete_temporary_processing_copy",
                sourcePath: convertedURL.path,
                destinationPath: "",
                occurredAt: Date()
            ))
            store.update(cleaned)
        }

        let transcript = try await whisper.transcribe(filePath: convertedURL.path)
        return (transcript, store.item(id: item.id) ?? updated)
    }

    /// The audio MacWhisper actually reads: the normalized copy when there is one.
    private func transcriptionSourceURL(for item: ImportItem) throws -> URL {
        if let normalizedAudioPath = item.normalizedAudioPath,
           FileManager.default.fileExists(atPath: normalizedAudioPath) {
            return URL(fileURLWithPath: normalizedAudioPath)
        }
        return try audioSourceURL(for: item)
    }

    private func audioSourceURL(for item: ImportItem) throws -> URL {
        if let managedAudioPath = item.managedAudioPath,
           FileManager.default.fileExists(atPath: managedAudioPath) {
            return URL(fileURLWithPath: managedAudioPath)
        }
        let candidates = [item.originalPath, item.sourcePath].compactMap { $0 }
        for path in candidates {
            let url = URL(fileURLWithPath: path)
            if FileManager.default.fileExists(atPath: url.path) {
                try AudioFileAccess.validateReadableAudio(at: url)
                return url
            }
        }
        throw ProcessingFailure(
            message: "The original audio is not available.",
            details: "Original: \(item.originalPath)\nTemporary copy: \(item.managedAudioPath ?? "None")"
        )
    }

    func export(_ id: ImportItem.ID) async {
        guard var item = store.item(id: id) else { return }
        item = applyAutomaticWorkflow(to: item)
        item.status = .importing
        item.error = nil
        store.update(item)

        let settings = store.settings
        do {
            let exporter = ObsidianJournalExporter(settings: settings) { [store] checkpoint in
                await MainActor.run { store.update(checkpoint) }
            }
            let exported = try await exporter.export(item)
            store.update(applyProcessingStoragePolicy(to: exported))
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

    /// Falls back to the original filename when a workflow runs without analysis.
    nonisolated static func filenameOnlyAnalysis(for item: ImportItem) -> AnalysisMetadata {
        let base = ((item.sourceFilename ?? item.originalFilename) as NSString).deletingPathExtension
        let slug = base.slugSafe
        return AnalysisMetadata(
            title: base,
            slug: slug,
            shortSlug: slug.split(separator: "-").prefix(4).joined(separator: "-"),
            summary: "",
            themes: []
        )
    }

    /// Prefers a date the speaker actually says over the file's own timestamps,
    /// which are often wrong for files that were copied or synced.
    private func applySpokenRecordingDate(from transcript: String, to item: ImportItem) -> ImportItem {
        guard store.settings.useSpokenDateFromTranscript, item.recordingDateSource != .manual else {
            return item
        }
        let spokenDate = item.analysis?.spokenDate
            ?? TranscriptDateExtractor.detect(in: transcript, referenceDate: Date())
        guard let spokenDate else { return item }

        var updated = item
        updated.recordingDate = Self.merged(spokenDate: spokenDate, keepingClockFrom: item.recordingDate)
        updated.recordingDateIsCertain = true
        updated.recordingDateSource = .transcript
        return updated
    }

    /// A spoken date without a time of day keeps the clock time from the file metadata.
    private static func merged(spokenDate: Date, keepingClockFrom fallback: Date) -> Date {
        let calendar = Calendar.current
        let spokenTime = calendar.dateComponents([.hour, .minute, .second], from: spokenDate)
        guard spokenTime.hour == 0, spokenTime.minute == 0, spokenTime.second == 0 else {
            return spokenDate
        }
        var components = calendar.dateComponents([.year, .month, .day], from: spokenDate)
        let clock = calendar.dateComponents([.hour, .minute, .second], from: fallback)
        components.hour = clock.hour
        components.minute = clock.minute
        components.second = clock.second
        return calendar.date(from: components) ?? spokenDate
    }

    /// Automatic routing must never overwrite a workflow the user picked themselves.
    private func applyAutomaticWorkflow(to item: ImportItem) -> ImportItem {
        guard !item.workflowIsUserAssigned else { return item }
        var updated = item
        if let watchFolderWorkflowID = watchFolderWorkflowID(for: item) {
            updated.workflow = watchFolderWorkflowID
        } else if let suggested = item.analysis?.suggestedWorkflow,
                  shouldApplySuggestedWorkflow(suggested, to: item) {
            updated.workflow = suggested
        }
        return updated
    }

    private func applyProcessingStoragePolicy(to item: ImportItem) -> ImportItem {
        var updated = item

        // The normalized copy is a pure intermediate, so it always goes once it has
        // been transcribed and exported, whatever the storage policy says.
        if let normalizedAudioPath = updated.normalizedAudioPath {
            try? FileManager.default.removeItem(at: URL(fileURLWithPath: normalizedAudioPath))
            updated.normalizedAudioPath = nil
            updated.fileOperations.append(FileOperationRecord(
                kind: "delete_normalized_copy",
                sourcePath: normalizedAudioPath,
                destinationPath: "",
                occurredAt: Date()
            ))
        }

        let policy = store.workflowPolicy(for: updated.workflow)
        guard policy.processingStoragePolicy == .deleteAfterSuccessfulExport else {
            return updated
        }

        // Audio dragged from an app that hands over data rather than a file is copied
        // into the app's own drop folder first. Once the workflow has put that audio
        // somewhere real, the copy is dead weight — and nothing used to remove it, so
        // the folder grew without limit. Only delete once the export is on disk.
        if ImportStore.isDropImportPath(updated.originalPath),
           let exportedAudioPath = updated.exportedAudioPath,
           FileManager.default.fileExists(atPath: exportedAudioPath) {
            try? FileManager.default.removeItem(at: URL(fileURLWithPath: updated.originalPath))
            updated.fileOperations.append(FileOperationRecord(
                kind: "delete_drop_import_copy",
                sourcePath: updated.originalPath,
                destinationPath: "",
                occurredAt: Date()
            ))
        }

        guard let managedAudioPath = updated.managedAudioPath else {
            return updated
        }

        try? FileManager.default.removeItem(at: URL(fileURLWithPath: managedAudioPath))
        updated.managedAudioPath = nil
        updated.fileOperations.append(FileOperationRecord(
            kind: "delete_managed_processing_copy",
            sourcePath: managedAudioPath,
            destinationPath: "",
            occurredAt: Date()
        ))
        return updated
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

struct ProcessingFailure: LocalizedError {
    var message: String
    var details: String

    var errorDescription: String? { message }
    var failureReason: String? { details }
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
    var summaryPoints: [String]?
    var spokenDatetime: String?
    var themes: [String]
    var mood: String?
    var suggestedWorkflow: String?

    enum CodingKeys: String, CodingKey {
        case title
        case slug
        case shortSlug = "short_slug"
        case summary
        case summaryPoints = "summary_points"
        case spokenDatetime = "spoken_datetime"
        case themes
        case mood
        case suggestedWorkflow = "suggested_workflow"
    }
}
