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
    static let supportedAudioExtensions = Set(["m4a", "mp3", "wav", "aiff", "aif", "caf", "mp4", "mov"])

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
                    details: "The source file size changed while the app was making a local processing copy. Wait until iCloud or the recording app finishes writing the file, then try again.\n\nSource: \(sourceURL.path)"
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
    static let targetBitrate = 96_000
    static let fallbackSampleRate = 44_100
    private static let skipBitrateThreshold = 200_000
    private static let skipEligibleExtensions: Set<String> = ["m4a"]

    static func shouldCompress(_ url: URL) -> Bool {
        guard skipEligibleExtensions.contains(url.pathExtension.lowercased()) else { return true }
        guard let bitRate = AudioInspector.bitRate(for: url) else { return true }
        return bitRate >= skipBitrateThreshold
    }

    static func compress(source: URL, to destination: URL) throws {
        let sampleRate = Int(AudioInspector.sampleRate(for: source) ?? Double(fallbackSampleRate))
        let process = Process()
        process.executableURL = URL(fileURLWithPath: toolPath)
        process.arguments = [
            "-f", "m4af",
            "-d", "aac@\(sampleRate)",
            "-c", "1",
            "--mix",
            "-b", "\(targetBitrate)",
            source.path,
            destination.path
        ]
        let stderr = Pipe()
        process.standardError = stderr
        process.standardOutput = Pipe()

        do {
            try process.run()
        } catch {
            throw ProcessingFailure(
                message: "Could not start afconvert.",
                details: "\(toolPath)\n\(error.localizedDescription)"
            )
        }
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            try? FileManager.default.removeItem(at: destination)
            let details = String(data: stderr.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            throw ProcessingFailure(
                message: "Audio compression failed.",
                details: details.isEmpty
                    ? "afconvert exited with status \(process.terminationStatus)."
                    : "\(source.path)\n\(details)"
            )
        }
    }
}

enum AudioNormalizer {
    private static let filterBase = "loudnorm=I=-16:TP=-1.5:LRA=11"

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
        process.standardOutput = Pipe()

        do {
            try process.run()
        } catch {
            throw ProcessingFailure(
                message: "Could not start ffmpeg.",
                details: "\(ffmpegPath)\n\(error.localizedDescription)"
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
    static let placeholders = [
        "{date}", "{time}", "{yyyy}", "{yy}", "{MM}", "{dd}", "{HH}", "{mm}",
        "{title}", "{slug}", "{shortSlug}", "{source}", "{workflow}",
        "{location}", "{project}", "{initials}", "{originalName}", "{extension}"
    ]

    static func render(pattern: String, item: ImportItem, workflowName: String, includeExtension: Bool = true) -> String {
        let calendar = Calendar.current
        let date = item.recordingDate
        let extensionValue = URL(fileURLWithPath: item.originalFilename).pathExtension.isEmpty ? "m4a" : URL(fileURLWithPath: item.originalFilename).pathExtension
        let originalBase = (item.originalFilename as NSString).deletingPathExtension
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
            "{location}": "location",
            "{project}": "project",
            "{initials}": "cp",
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
            originalFilename: "2026-05-12_18-45.m4a",
            originalPath: "/Example/2026-05-12_18-45.m4a",
            managedAudioPath: nil,
            recordingDate: Date(timeIntervalSince1970: 1_747_069_500),
            recordingDateIsCertain: true
        )
        sample.analysis = AnalysisMetadata(
            title: "Spaziergang und Entscheidung",
            slug: "spaziergang-und-entscheidung",
            shortSlug: "spaziergang-und-entscheidung",
            summary: "Reflexion über Morgenruhe, innere Klarheit und eine Arbeitsentscheidung.",
            themes: ["Journal", "Entscheidung"],
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
