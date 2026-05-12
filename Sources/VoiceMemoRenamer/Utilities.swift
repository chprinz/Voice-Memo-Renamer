import AppKit
import AVFoundation
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
