import AppKit
import AVFoundation
import Foundation

enum AppPaths {
    static var applicationSupport: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("MemoImportCenter", isDirectory: true)
    }

    static var managedAudioDirectory: URL {
        applicationSupport.appendingPathComponent("Managed Audio", isDirectory: true)
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
}
