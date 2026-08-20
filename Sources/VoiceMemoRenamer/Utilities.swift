import AppKit
import AudioToolbox
import AVFoundation
import CryptoKit
import Foundation

enum AppPaths {
    static var applicationSupport: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("VoiceMemoRenamer", isDirectory: true)
    }

    static var managedAudioDirectory: URL {
        applicationSupport.appendingPathComponent("Managed Audio", isDirectory: true)
    }

    static var processingCacheDirectory: URL {
        applicationSupport.appendingPathComponent("Processing Cache", isDirectory: true)
    }

    static var dropImportDirectory: URL {
        applicationSupport.appendingPathComponent("Dropped Files", isDirectory: true)
    }

    static var storeURL: URL {
        applicationSupport.appendingPathComponent("history.json")
    }

    static var settingsURL: URL {
        applicationSupport.appendingPathComponent("settings.json")
    }
}

extension DateFormatter {
    static let itemDate: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter
    }()

    static let filenameDate: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd_HH-mm"
        return formatter
    }()

    static let monthlyNote: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM"
        return formatter
    }()

    static let compactDate: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    static let compactTime: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH-mm"
        return formatter
    }()
}

extension String {
    var nilIfBlank: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    var slugSafe: String {
        let replacements = [
            "ä": "ae", "ö": "oe", "ü": "ue", "ß": "ss",
            "Ä": "ae", "Ö": "oe", "Ü": "ue"
        ]
        var value = self
        replacements.forEach { value = value.replacingOccurrences(of: $0.key, with: $0.value) }
        value = value.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "- "))
        value = String(value.unicodeScalars.map { allowed.contains($0) ? Character($0) : " " })
        return value
            .lowercased()
            .split(whereSeparator: { $0 == " " || $0 == "-" })
            .joined(separator: "-")
    }

    var filesystemSafeFilename: String {
        let invalid = CharacterSet(charactersIn: "/:\\").union(.newlines).union(.controlCharacters)
        let cleaned = String(unicodeScalars.map { invalid.contains($0) ? "-" : Character($0) })
            .trimmingCharacters(in: CharacterSet(charactersIn: " ."))
        return cleaned.isEmpty ? "audio" : cleaned
    }

    func bounded(to limit: Int) -> String {
        guard count > limit else { return self }
        return String(prefix(limit)).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

enum FileNaming {
    static func filename(preferredName: String?, fallbackBase: String, fallbackExtension: String) -> String {
        var filename = (preferredName?.nilIfBlank ?? fallbackBase).filesystemSafeFilename
        let ext = URL(fileURLWithPath: filename).pathExtension
        if ext.isEmpty {
            filename += ".\(fallbackExtension.isEmpty ? "m4a" : fallbackExtension)"
        }
        return filename
    }

    static func uniqueURL(in directory: URL, filename: String) -> URL {
        let safeFilename = filename.filesystemSafeFilename
        let base = (safeFilename as NSString).deletingPathExtension
        let ext = (safeFilename as NSString).pathExtension
        var candidate = directory.appendingPathComponent(safeFilename)
        var counter = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = directory.appendingPathComponent("\(base)-\(counter)").appendingPathExtension(ext)
            counter += 1
        }
        return candidate
    }
}

enum AudioFileAccess {
    static let supportedAudioExtensions = Set([
        "m4a", "m4b", "mp3", "wav", "wave", "w64", "aiff", "aif", "aifc",
        "caf", "flac", "aac", "opus", "ogg", "mp4", "mov"
    ])

    static func isSupportedAudioURL(_ url: URL) -> Bool {
        supportedAudioExtensions.contains(url.pathExtension.lowercased())
    }

    static func createManagedCopy(from sourceURL: URL) throws -> URL {
        try validateReadableAudio(at: sourceURL)
        try FileManager.default.createDirectory(at: AppPaths.managedAudioDirectory, withIntermediateDirectories: true)

        let destinationURL = FileNaming.uniqueURL(
            in: AppPaths.managedAudioDirectory,
            filename: FileNaming.filename(
                preferredName: sourceURL.lastPathComponent,
                fallbackBase: sourceURL.deletingPathExtension().lastPathComponent,
                fallbackExtension: sourceURL.pathExtension.isEmpty ? "m4a" : sourceURL.pathExtension
            )
        )

        let sourceSize = try fileSize(for: sourceURL)
        do {
            try FileManager.default.copyItem(at: sourceURL, to: destinationURL)
            let copiedSize = try fileSize(for: destinationURL)
            guard copiedSize == sourceSize else {
                try? FileManager.default.removeItem(at: destinationURL)
                throw ProcessingFailure(
                    message: "Audio file changed while importing.",
                    details: "The source file size changed while the app was making a temporary copy. Wait until iCloud or the recording app finishes writing the file, then try again.\n\nSource: \(sourceURL.path)"
                )
            }
            return destinationURL
        } catch let failure as ProcessingFailure {
            throw failure
        } catch {
            try? FileManager.default.removeItem(at: destinationURL)
            throw ProcessingFailure(
                message: "Could not copy audio into the app cache.",
                details: "\(sourceURL.path)\n\(error.localizedDescription)"
            )
        }
    }

    static func validateReadableAudio(at url: URL) throws {
        guard url.isFileURL else {
            throw ProcessingFailure(message: "Only local files can be imported.", details: url.absoluteString)
        }
        guard isSupportedAudioURL(url) else {
            throw ProcessingFailure(
                message: "Unsupported audio file type.",
                details: "\(url.lastPathComponent)\nSupported: \(supportedAudioExtensions.sorted().joined(separator: ", "))"
            )
        }

        let keys: Set<URLResourceKey> = [
            .isRegularFileKey,
            .fileSizeKey,
            .isUbiquitousItemKey,
            .ubiquitousItemDownloadingStatusKey
        ]
        let values: URLResourceValues
        do {
            values = try url.resourceValues(forKeys: keys)
        } catch {
            throw ProcessingFailure(
                message: "Audio file is not available.",
                details: "\(url.path)\n\(error.localizedDescription)"
            )
        }

        guard values.isRegularFile == true else {
            throw ProcessingFailure(message: "Audio source is not a file.", details: url.path)
        }

        if values.isUbiquitousItem == true,
           values.ubiquitousItemDownloadingStatus == .notDownloaded {
            try? FileManager.default.startDownloadingUbiquitousItem(at: url)
            throw ProcessingFailure(
                message: "Audio is still downloading from iCloud.",
                details: "macOS has been asked to download the file. Wait until it is available locally, then try again.\n\nSource: \(url.path)"
            )
        }

        let size = values.fileSize ?? 0
        guard size > 0 else {
            throw ProcessingFailure(
                message: "Audio file is empty.",
                details: "The file has zero bytes. It may still be syncing or it may be damaged.\n\nSource: \(url.path)"
            )
        }

        guard FileManager.default.isReadableFile(atPath: url.path) else {
            throw ProcessingFailure(
                message: "Audio file is not readable.",
                details: "The app does not have permission to read this file, or the file is not downloaded locally.\n\nSource: \(url.path)"
            )
        }
    }

    private static func fileSize(for url: URL) throws -> Int {
        let values = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
        guard values.isRegularFile == true else {
            throw ProcessingFailure(message: "Audio source is not a file.", details: url.path)
        }
        return values.fileSize ?? 0
    }
}

enum AudioInspector {
    static func recordingDate(for url: URL) -> (date: Date, certain: Bool) {
        let resourceKeys: Set<URLResourceKey> = [.creationDateKey, .contentModificationDateKey]
        let values = try? url.resourceValues(forKeys: resourceKeys)
        if let creationDate = values?.creationDate {
            return (creationDate, true)
        }
        if let modificationDate = values?.contentModificationDate {
            return (modificationDate, false)
        }
        return (Date(), false)
    }

    static func duration(for url: URL) async -> Double? {
        let asset = AVURLAsset(url: url)
        do {
            let duration = try await asset.load(.duration)
            return CMTimeGetSeconds(duration)
        } catch {
            return nil
        }
    }

    static func bitRate(for url: URL) -> UInt32? {
        withAudioFile(at: url) { file in
            var bitRate: UInt32 = 0
            var size = UInt32(MemoryLayout<UInt32>.size)
            let status = AudioFileGetProperty(file, kAudioFilePropertyBitRate, &size, &bitRate)
            return status == noErr ? bitRate : nil
        }
    }

    static func sampleRate(for url: URL) -> Double? {
        withAudioFile(at: url) { file in
            var asbd = AudioStreamBasicDescription()
            var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
            let status = AudioFileGetProperty(file, kAudioFilePropertyDataFormat, &size, &asbd)
            return status == noErr ? asbd.mSampleRate : nil
        }
    }

    /// True for float or >24 bit linear PCM, as written by wireless field recorders.
    /// Support for these is patchy across tools, so they get converted to plain 16 bit
    /// PCM before transcription rather than being handed over as they are.
    static func needsTranscodingForTranscription(_ url: URL) -> Bool {
        withAudioFile(at: url) { file -> Bool? in
            var asbd = AudioStreamBasicDescription()
            var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
            guard AudioFileGetProperty(file, kAudioFilePropertyDataFormat, &size, &asbd) == noErr else {
                return nil
            }
            guard asbd.mFormatID == kAudioFormatLinearPCM else { return false }
            let isFloat = asbd.mFormatFlags & kAudioFormatFlagIsFloat != 0
            return isFloat || asbd.mBitsPerChannel > 24
        } ?? false
    }

    static func formatSummary(for url: URL) -> String? {
        withAudioFile(at: url) { file -> String? in
            var asbd = AudioStreamBasicDescription()
            var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
            guard AudioFileGetProperty(file, kAudioFilePropertyDataFormat, &size, &asbd) == noErr else {
                return nil
            }
            let isFloat = asbd.mFormatFlags & kAudioFormatFlagIsFloat != 0
            let depth = asbd.mBitsPerChannel == 0 ? "compressed" : "\(asbd.mBitsPerChannel) bit\(isFloat ? " float" : "")"
            return "\(Int(asbd.mSampleRate)) Hz, \(asbd.mChannelsPerFrame) ch, \(depth)"
        }
    }

    private static func withAudioFile<T>(at url: URL, _ body: (AudioFileID) -> T?) -> T? {
        var audioFile: AudioFileID?
        let status = AudioFileOpenURL(url as CFURL, .readPermission, 0, &audioFile)
        guard status == noErr, let file = audioFile else { return nil }
        defer { AudioFileClose(file) }
        return body(file)
    }
}

enum AudioCompressor {
    static let toolPath = "/usr/bin/afconvert"
    static let bitrateChoicesKbps = [32, 48, 64, 96, 128, 192, 256]
    static let fallbackSampleRate = 44_100
    private static let skipEligibleExtensions: Set<String> = ["m4a"]

    /// An already-compact M4A is left alone unless it is clearly bigger than the target.
    static func shouldCompress(_ url: URL, targetBitrateKbps: Int) -> Bool {
        guard skipEligibleExtensions.contains(url.pathExtension.lowercased()) else { return true }
        guard let bitRate = AudioInspector.bitRate(for: url) else { return true }
        return bitRate >= UInt32(targetBitrateKbps * 1_000 * 2)
    }

    static func compress(source: URL, to destination: URL, bitrateKbps: Int, forceMono: Bool) throws {
        let sampleRate = Int(AudioInspector.sampleRate(for: source) ?? Double(fallbackSampleRate))
        let process = Process()
        process.executableURL = URL(fileURLWithPath: toolPath)
        var arguments = [
            "-f", "m4af",
            "-d", "aac@\(sampleRate)"
        ]
        if forceMono {
            arguments += ["-c", "1", "--mix"]
        }
        arguments += [
            "-b", "\(max(16, bitrateKbps) * 1_000)",
            source.path,
            destination.path
        ]
        process.arguments = arguments
        let stderr = Pipe()
        process.standardError = stderr
        process.standardOutput = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            throw ProcessingFailure(
                message: "Could not start afconvert.",
                details: "\(toolPath)\n\(error.localizedDescription)"
            )
        }
        let errorData = stderr.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            try? FileManager.default.removeItem(at: destination)
            let details = String(data: errorData, encoding: .utf8) ?? ""
            throw ProcessingFailure(
                message: "Audio compression failed.",
                details: details.isEmpty
                    ? "afconvert exited with status \(process.terminationStatus)."
                    : "\(source.path)\n\(details)"
            )
        }
    }
}

/// Rewrites audio MacWhisper cannot read into plain 16 bit PCM WAV.
/// Only used for transcription, never for the audio that gets exported.
enum AudioTranscoder {
    static func transcodeForTranscription(source: URL, ffmpegPath: String) throws -> URL {
        try FileManager.default.createDirectory(at: AppPaths.processingCacheDirectory, withIntermediateDirectories: true)
        let destination = FileNaming.uniqueURL(
            in: AppPaths.processingCacheDirectory,
            filename: source.deletingPathExtension().lastPathComponent + "-transcode.wav"
        )

        let sampleRate = Int(AudioInspector.sampleRate(for: source) ?? 48_000)
        do {
            try run(
                tool: AudioCompressor.toolPath,
                arguments: ["-f", "WAVE", "-d", "LEI16@\(sampleRate)", "-c", "1", "--mix", source.path, destination.path],
                toolName: "afconvert"
            )
            return destination
        } catch let afconvertFailure as ProcessingFailure {
            try? FileManager.default.removeItem(at: destination)
            guard FileManager.default.isExecutableFile(atPath: ffmpegPath) else { throw afconvertFailure }
            do {
                try run(
                    tool: ffmpegPath,
                    arguments: ["-y", "-hide_banner", "-loglevel", "error", "-i", source.path,
                                "-ac", "1", "-ar", String(sampleRate), "-c:a", "pcm_s16le", destination.path],
                    toolName: "ffmpeg"
                )
                return destination
            } catch {
                try? FileManager.default.removeItem(at: destination)
                throw ProcessingFailure(
                    message: "Could not convert this audio file.",
                    details: "Neither afconvert nor ffmpeg could read it.\n\nafconvert: \(afconvertFailure.details)\nffmpeg: \((error as? ProcessingFailure)?.details ?? error.localizedDescription)"
                )
            }
        }
    }

    private static func run(tool: String, arguments: [String], toolName: String) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        let stderr = Pipe()
        process.standardError = stderr
        process.standardOutput = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            throw ProcessingFailure(message: "Could not start \(toolName).", details: "\(tool)\n\(error.localizedDescription)")
        }
        let errorData = stderr.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let output = String(data: errorData, encoding: .utf8) ?? ""
            throw ProcessingFailure(
                message: "\(toolName) could not convert the audio.",
                details: output.isEmpty ? "\(toolName) exited with status \(process.terminationStatus)." : output
            )
        }
    }
}

/// Finds a date or time the speaker states at the very start or end of a recording,
/// which is often more reliable than the file's own timestamps.
enum TranscriptDateExtractor {
    private static let edgeCharacterCount = 500

    /// Parses what the analysis model returned for the spoken date.
    static func parseModelValue(_ raw: String?, referenceDate: Date) -> Date? {
        guard let value = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
        let formats = [
            "yyyy-MM-dd'T'HH:mm:ssZ", "yyyy-MM-dd'T'HH:mm:ss", "yyyy-MM-dd'T'HH:mm",
            "yyyy-MM-dd HH:mm:ss", "yyyy-MM-dd HH:mm", "yyyy-MM-dd",
            "dd.MM.yyyy HH:mm", "dd.MM.yyyy"
        ]
        for format in formats {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.dateFormat = format
            if let date = formatter.date(from: value) {
                return isPlausible(date, referenceDate: referenceDate) ? date : nil
            }
        }
        return nil
    }

    /// Fallback for transcripts handled without the model, e.g. when analysis is off.
    /// Deliberately strict: only an explicitly written out date counts. A loose date
    /// detector matches things like "half past three" and silently invents a wrong day.
    static func detect(in transcript: String, referenceDate: Date) -> Date? {
        let trimmed = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let edges = [String(trimmed.prefix(edgeCharacterCount)), String(trimmed.suffix(edgeCharacterCount))]
        for edge in edges {
            guard let date = firstDate(in: edge, referenceDate: referenceDate) else { continue }
            return date
        }
        return nil
    }

    private static func firstDate(in text: String, referenceDate: Date) -> Date? {
        for pattern in datePatterns {
            guard let match = pattern.regex.firstMatch(in: text, range: NSRange(text.startIndex..<text.endIndex, in: text)) else {
                continue
            }
            guard var components = pattern.components(match, text) else { continue }
            // A day and month said out loud almost always mean the current year;
            // isPlausible below still rejects it if that guess lands in the future.
            if components.year == nil {
                components.year = Calendar.current.component(.year, from: referenceDate)
            }
            let clock = time(in: text, near: match.range)
            components.hour = clock?.hour ?? 0
            components.minute = clock?.minute ?? 0
            guard let date = Calendar.current.date(from: components),
                  isPlausible(date, referenceDate: referenceDate) else { continue }
            return date
        }
        return nil
    }

    private struct DatePattern {
        var regex: NSRegularExpression
        var components: (NSTextCheckingResult, String) -> DateComponents?
    }

    private static let monthNames: [String: Int] = [
        "januar": 1, "january": 1, "jänner": 1, "februar": 2, "february": 2, "märz": 3, "maerz": 3,
        "march": 3, "april": 4, "mai": 5, "may": 5, "juni": 6, "june": 6, "juli": 7, "july": 7,
        "august": 8, "september": 9, "oktober": 10, "october": 10, "november": 11,
        "dezember": 12, "december": 12
    ]

    private static let datePatterns: [DatePattern] = {
        let monthAlternation = monthNames.keys.sorted { $0.count > $1.count }.joined(separator: "|")
        func regex(_ pattern: String) -> NSRegularExpression {
            try! NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
        }
        func number(_ match: NSTextCheckingResult, _ text: String, _ index: Int) -> Int? {
            guard let range = Range(match.range(at: index), in: text) else { return nil }
            return Int(text[range])
        }
        func month(_ match: NSTextCheckingResult, _ text: String, _ index: Int) -> Int? {
            guard let range = Range(match.range(at: index), in: text) else { return nil }
            return monthNames[text[range].lowercased()]
        }
        return [
            // 2026-08-14
            DatePattern(regex: regex(#"\b(\d{4})-(\d{1,2})-(\d{1,2})\b"#)) { match, text in
                guard let year = number(match, text, 1), let month = number(match, text, 2), let day = number(match, text, 3) else { return nil }
                return DateComponents(year: year, month: month, day: day)
            },
            // 14.08.2026 and 14. 8. 2026
            DatePattern(regex: regex(#"\b(\d{1,2})\.\s?(\d{1,2})\.\s?(\d{4})\b"#)) { match, text in
                guard let day = number(match, text, 1), let month = number(match, text, 2), let year = number(match, text, 3) else { return nil }
                return DateComponents(year: year, month: month, day: day)
            },
            // 14. August 2026
            DatePattern(regex: regex(#"\b(\d{1,2})\.?\s*(\#(monthAlternation))\s+(\d{4})\b"#)) { match, text in
                guard let day = number(match, text, 1), let month = month(match, text, 2), let year = number(match, text, 3) else { return nil }
                return DateComponents(year: year, month: month, day: day)
            },
            // August 14, 2026
            DatePattern(regex: regex(#"\b(\#(monthAlternation))\s+(\d{1,2})(?:st|nd|rd|th)?,?\s+(\d{4})\b"#)) { match, text in
                guard let month = month(match, text, 1), let day = number(match, text, 2), let year = number(match, text, 3) else { return nil }
                return DateComponents(year: year, month: month, day: day)
            },
            // 14. August, no year spoken
            DatePattern(regex: regex(#"\b(\d{1,2})\.?\s*(\#(monthAlternation))\b"#)) { match, text in
                guard let day = number(match, text, 1), let month = month(match, text, 2) else { return nil }
                return DateComponents(month: month, day: day)
            },
            // August 14, no year spoken
            DatePattern(regex: regex(#"\b(\#(monthAlternation))\s+(\d{1,2})(?:st|nd|rd|th)?\b"#)) { match, text in
                guard let month = month(match, text, 1), let day = number(match, text, 2) else { return nil }
                return DateComponents(month: month, day: day)
            }
        ]
    }()

    /// Only accepts a clock time written next to the date, and never inside it, so
    /// neither "14.08.2026" nor unrelated numbers elsewhere can set the recording time.
    private static func time(in text: String, near dateRange: NSRange) -> (hour: Int, minute: Int)? {
        let nsText = text as NSString
        let afterStart = dateRange.location + dateRange.length
        let after = nsText.substring(with: NSRange(
            location: afterStart,
            length: min(40, nsText.length - afterStart)
        ))
        let beforeStart = max(0, dateRange.location - 40)
        let before = nsText.substring(with: NSRange(location: beforeStart, length: dateRange.location - beforeStart))

        for window in [after, before] {
            if let clock = firstTime(in: window) {
                return clock
            }
        }
        return nil
    }

    private static let timeRegex = try! NSRegularExpression(
        pattern: #"(?:\b(\d{1,2}):(\d{2})\b)|(?:\b(\d{1,2})\.(\d{2})\s*uhr\b)"#,
        options: [.caseInsensitive]
    )

    private static func firstTime(in window: String) -> (hour: Int, minute: Int)? {
        guard let match = timeRegex.firstMatch(in: window, range: NSRange(window.startIndex..<window.endIndex, in: window)) else {
            return nil
        }
        for (hourIndex, minuteIndex) in [(1, 2), (3, 4)] {
            guard let hourRange = Range(match.range(at: hourIndex), in: window),
                  let minuteRange = Range(match.range(at: minuteIndex), in: window),
                  let hour = Int(window[hourRange]), let minute = Int(window[minuteRange]),
                  (0...23).contains(hour), (0...59).contains(minute) else { continue }
            return (hour, minute)
        }
        return nil
    }

    /// Guards against the model inventing a date, and against "half past three" style
    /// matches that resolve to today rather than to the day of the recording.
    private static func isPlausible(_ date: Date, referenceDate: Date) -> Bool {
        guard let earliest = Calendar.current.date(byAdding: .year, value: -30, to: referenceDate),
              let latest = Calendar.current.date(byAdding: .day, value: 1, to: referenceDate) else {
            return false
        }
        return date >= earliest && date <= latest
    }
}

enum AudioNormalizer {
    private static let filterBase = "loudnorm=I=-16:TP=-1.5:LRA=11"

    /// Writes a normalized copy into the processing cache and returns it.
    static func normalizedCopy(of source: URL, ffmpegPath: String) throws -> URL {
        try FileManager.default.createDirectory(at: AppPaths.processingCacheDirectory, withIntermediateDirectories: true)
        let destination = FileNaming.uniqueURL(
            in: AppPaths.processingCacheDirectory,
            filename: source.deletingPathExtension().lastPathComponent + "-normalized.wav"
        )
        try normalize(source: source, to: destination, ffmpegPath: ffmpegPath)
        return destination
    }

    static func normalize(source: URL, to destination: URL, ffmpegPath: String) throws {
        let sampleRate = AudioInspector.sampleRate(for: source)
        let measurement = try measure(source: source, ffmpegPath: ffmpegPath)
        do {
            try apply(source: source, to: destination, ffmpegPath: ffmpegPath, sampleRate: sampleRate, measurement: measurement)
        } catch {
            try? FileManager.default.removeItem(at: destination)
            throw error
        }
    }

    private struct Measurement: Decodable {
        var inputI: String
        var inputTP: String
        var inputLRA: String
        var inputThresh: String
        var targetOffset: String

        enum CodingKeys: String, CodingKey {
            case inputI = "input_i"
            case inputTP = "input_tp"
            case inputLRA = "input_lra"
            case inputThresh = "input_thresh"
            case targetOffset = "target_offset"
        }
    }

    private static func measure(source: URL, ffmpegPath: String) throws -> Measurement {
        let output = try run(ffmpegPath: ffmpegPath, arguments: [
            "-hide_banner", "-nostats", "-loglevel", "info",
            "-i", source.path,
            "-af", "\(filterBase):print_format=json",
            "-f", "null", "-"
        ])
        guard let start = output.firstIndex(of: "{"), let end = output.lastIndex(of: "}") else {
            throw ProcessingFailure(message: "Could not measure audio loudness.", details: output)
        }
        let json = String(output[start...end])
        guard let data = json.data(using: .utf8) else {
            throw ProcessingFailure(message: "Could not measure audio loudness.", details: json)
        }
        do {
            return try JSONDecoder().decode(Measurement.self, from: data)
        } catch {
            throw ProcessingFailure(
                message: "Could not parse loudness measurement.",
                details: "\(error.localizedDescription)\n\n\(json)"
            )
        }
    }

    private static func apply(
        source: URL,
        to destination: URL,
        ffmpegPath: String,
        sampleRate: Double?,
        measurement: Measurement
    ) throws {
        var filter = filterBase
        filter += ":measured_I=\(measurement.inputI)"
        filter += ":measured_TP=\(measurement.inputTP)"
        filter += ":measured_LRA=\(measurement.inputLRA)"
        filter += ":measured_thresh=\(measurement.inputThresh)"
        filter += ":offset=\(measurement.targetOffset)"
        filter += ":linear=true"

        var arguments = ["-y", "-hide_banner", "-nostats", "-loglevel", "error", "-i", source.path, "-af", filter]
        if let sampleRate {
            arguments += ["-ar", String(Int(sampleRate))]
        }
        arguments += ["-c:a", "pcm_s24le", destination.path]
        try run(ffmpegPath: ffmpegPath, arguments: arguments)
    }

    @discardableResult
    private static func run(ffmpegPath: String, arguments: [String]) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: ffmpegPath)
        process.arguments = arguments
        let stderr = Pipe()
        process.standardError = stderr
        process.standardOutput = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            throw ProcessingFailure(
                message: "Could not start ffmpeg.",
                details: "\(ffmpegPath)\n\(error.localizedDescription)\n\nLoudness normalization needs ffmpeg. Set its path under Settings → Services, or turn off Normalize to import without it."
            )
        }
        let errorData = stderr.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let output = String(data: errorData, encoding: .utf8) ?? ""

        guard process.terminationStatus == 0 else {
            throw ProcessingFailure(
                message: "Audio normalization failed.",
                details: output.isEmpty ? "ffmpeg exited with status \(process.terminationStatus)." : output
            )
        }
        return output
    }
}

enum AudioFingerprint {
    static func sha256(for url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }

        var hasher = SHA256()
        while true {
            let data = try handle.read(upToCount: 1024 * 1024) ?? Data()
            if data.isEmpty {
                break
            }
            hasher.update(data: data)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

enum Finder {
    static func reveal(_ path: String?) {
        guard let path else { return }
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
    }

    static func open(_ path: String?) {
        guard let path else { return }
        NSWorkspace.shared.open(URL(fileURLWithPath: path))
    }
}

enum FilenamePattern {
    struct Placeholder {
        var token: String
        var explanation: String
    }

    /// Every token the renderer actually understands. Anything listed here works;
    /// anything not listed is not a token, so the popover and the renderer can no
    /// longer disagree.
    static let documentedPlaceholders: [Placeholder] = [
        Placeholder(token: "{filename}", explanation: "Original filename, unchanged (spaces and capitals kept)"),
        Placeholder(token: "{date}", explanation: "Recording date, 2026-05-12"),
        Placeholder(token: "{time}", explanation: "Recording time, 18-45"),
        Placeholder(token: "{yyyy} {yy} {MM} {dd} {HH} {mm}", explanation: "Date/time parts, to build a custom format"),
        Placeholder(token: "{slug}", explanation: "Analysed long slug"),
        Placeholder(token: "{shortSlug}", explanation: "Analysed short slug"),
        Placeholder(token: "{source}", explanation: "Where the file came from, jpr or manual"),
        Placeholder(token: "{title}", explanation: "Analysed title, made filename-safe"),
        Placeholder(token: "{workflow}", explanation: "Name of the workflow that handled it"),
        Placeholder(token: "{filenameSlug}", explanation: "Original filename as a slug (lowercase, hyphenated)"),
        Placeholder(token: "{originalName}", explanation: "Same as {filenameSlug}, kept for older patterns"),
        Placeholder(token: "{extension}", explanation: "File extension without the dot, m4a")
    ]

    /// Placeholders that only have a value once LM Studio has analysed the transcript.
    private static let analysisPlaceholders = ["{title}", "{slug}", "{shortSlug}"]

    static func requiresAnalysis(pattern: String) -> Bool {
        analysisPlaceholders.contains { pattern.contains($0) }
    }

    static func render(pattern: String, item: ImportItem, workflowName: String, includeExtension: Bool = true) -> String {
        let calendar = Calendar.current
        let date = item.recordingDate
        let extensionValue = URL(fileURLWithPath: item.originalFilename).pathExtension.isEmpty ? "m4a" : URL(fileURLWithPath: item.originalFilename).pathExtension
        let originalSourceName = item.sourceFilename ?? item.originalFilename
        let originalBase = (originalSourceName as NSString).deletingPathExtension
        let title = item.analysis?.title ?? originalBase
        let slug = item.analysis?.slug ?? title.slugSafe
        let shortSlug = item.analysis?.shortSlug ?? slug.split(separator: "-").prefix(4).joined(separator: "-")
        let values: [String: String] = [
            "{date}": DateFormatter.compactDate.string(from: date),
            "{time}": DateFormatter.compactTime.string(from: date),
            "{yyyy}": String(format: "%04d", calendar.component(.year, from: date)),
            "{yy}": String(format: "%02d", calendar.component(.year, from: date) % 100),
            "{MM}": String(format: "%02d", calendar.component(.month, from: date)),
            "{dd}": String(format: "%02d", calendar.component(.day, from: date)),
            "{HH}": String(format: "%02d", calendar.component(.hour, from: date)),
            "{mm}": String(format: "%02d", calendar.component(.minute, from: date)),
            "{title}": title.slugSafe,
            "{slug}": slug,
            "{shortSlug}": shortSlug,
            "{source}": sourceName(for: item).slugSafe,
            "{workflow}": workflowName.slugSafe,
            "{filename}": originalBase.filesystemSafeFilename,
            "{filenameSlug}": originalBase.slugSafe,
            "{originalName}": originalBase.slugSafe,
            "{extension}": extensionValue
        ]

        var filename = pattern.isEmpty ? WorkflowPolicy.defaultFilenamePattern : pattern
        values.forEach { filename = filename.replacingOccurrences(of: $0.key, with: $0.value) }
        filename = filename.replacingOccurrences(of: "__", with: "_")
            .trimmingCharacters(in: CharacterSet(charactersIn: "._- "))
        if includeExtension, !filename.hasSuffix(".\(extensionValue)") {
            filename += ".\(extensionValue)"
        }
        return filename
    }

    static func preview(pattern: String, workflowName: String) -> String {
        var sample = ImportItem(
            originalFilename: "Original Filename.m4a",
            originalPath: "/Example/Original Filename.m4a",
            sourceFilename: "Original Filename.m4a",
            sourcePath: "/Example/Original Filename.m4a",
            managedAudioPath: nil,
            recordingDate: Date(timeIntervalSince1970: 1_747_069_500),
            recordingDateIsCertain: true
        )
        sample.analysis = AnalysisMetadata(
            title: "Morning Walk And A Decision",
            slug: "morning-walk-and-a-decision",
            shortSlug: "morning-walk",
            summary: "A short reflection on morning quiet and a decision about work.",
            themes: ["Journal", "Decisions"],
            mood: nil,
            suggestedWorkflow: nil
        )
        return render(pattern: pattern, item: sample, workflowName: workflowName)
    }

    private static func sourceName(for item: ImportItem) -> String {
        let path = item.originalPath.lowercased()
        if path.contains("just-press-record") || path.contains("openplanetsoftware") {
            return "JPR"
        }
        return "manual"
    }
}

enum FileSizeFormatter {
    static func storageText(bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useKB, .useMB, .useGB]
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
    }
}
