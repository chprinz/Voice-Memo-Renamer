import Foundation
import SwiftUI

/// The spacing scale. Every padding and gap in the interface comes from here, so
/// alignment is a consequence of the scale rather than of hand-tuned offsets.
enum Space {
    static let xs: CGFloat = 4
    static let s: CGFloat = 8
    static let m: CGFloat = 12
    static let l: CGFloat = 16
    static let xl: CGFloat = 20
    static let xxl: CGFloat = 28
}

/// Shortens a filesystem path for display, keeping the tail because that is the
/// part that identifies the destination.
enum PathDisplay {
    static func short(_ path: String, components: Int = 2) -> String {
        guard !path.isEmpty else { return "No folder selected" }
        let parts = (path as NSString).pathComponents
            .filter { $0 != "/" }
            .map(readableComponent)
        guard parts.count > components else { return parts.joined(separator: "/") }
        return parts.suffix(components).joined(separator: "/")
    }

    /// iCloud container folders are named after a bundle id, which is unreadable
    /// in a UI. Show the app's name instead — the part a person recognises.
    private static func readableComponent(_ component: String) -> String {
        guard component.hasPrefix("iCloud~"), let slug = component.split(separator: "~").last else {
            return component
        }
        return slug
            .split(separator: "-")
            .map { $0.prefix(1).uppercased() + $0.dropFirst() }
            .joined(separator: " ")
    }
}

/// Describes in a few words what a workflow will do with a recording. Used by the
/// drop zone's destination block and by the detail panel, so both always agree.
enum WorkflowSummary {

    /// Label/value pairs such as ("Moves audio to", "Journal/Audio").
    static func destinations(for policy: WorkflowPolicy) -> [(label: String, value: String)] {
        var rows: [(label: String, value: String)] = []

        switch policy.audioFileBehavior {
        case .moveToFolder:
            rows.append(("Moves audio to", PathDisplay.short(policy.audioDestinationPath)))
        case .copyToFolder:
            rows.append(("Copies audio to", PathDisplay.short(policy.audioDestinationPath)))
        case .renameInPlace:
            rows.append(("Renames audio", "in its original folder"))
        case .leaveInPlace:
            rows.append(("Leaves audio", "where it is"))
        }

        switch policy.transcriptBehavior {
        case .appendToMonthlyNote:
            rows.append(("Appends note to", PathDisplay.short(policy.destinationPath) + "/" + monthlyNoteName()))
        case .createMarkdownFile:
            rows.append(("Creates note in", PathDisplay.short(policy.destinationPath)))
        case .saveTranscriptOnly:
            rows.append(("Saves transcript to", PathDisplay.short(policy.destinationPath)))
        case .doNotExportTranscript:
            rows.append(("Writes no note", "transcript stays in the app"))
        }

        return rows
    }

    /// The one-line form used on queue rows and in the detail panel header.
    static func planTags(for policy: WorkflowPolicy) -> String {
        let audio: String
        switch policy.audioFileBehavior {
        case .copyToFolder: audio = "copies audio"
        case .moveToFolder: audio = "moves audio"
        case .renameInPlace: audio = "renames audio"
        case .leaveInPlace: audio = "leaves audio"
        }

        let note: String
        switch policy.transcriptBehavior {
        case .appendToMonthlyNote: note = "appends monthly note"
        case .createMarkdownFile: note = "creates note"
        case .saveTranscriptOnly: note = "saves transcript"
        case .doNotExportTranscript: note = "no note"
        }

        return "\(audio) · \(note)"
    }

    private static func monthlyNoteName() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM"
        return formatter.string(from: Date()) + ".md"
    }
}

/// Groups recordings into day buckets with relative headers, which is how people
/// look for a recording they made ("the one from Tuesday").
enum DayGrouping {

    struct Group: Identifiable {
        let id: Date
        let title: String
        let items: [ImportItem]
    }

    static func groups(for items: [ImportItem], calendar: Calendar = .current) -> [Group] {
        let buckets = Dictionary(grouping: items) { calendar.startOfDay(for: $0.recordingDate) }
        return buckets.keys.sorted(by: >).map { day in
            Group(
                id: day,
                title: title(for: day, calendar: calendar),
                items: buckets[day]?.sorted { $0.recordingDate > $1.recordingDate } ?? []
            )
        }
    }

    static func title(for day: Date, calendar: Calendar = .current) -> String {
        if calendar.isDateInToday(day) { return "Today" }
        if calendar.isDateInYesterday(day) { return "Yesterday" }

        let formatter = DateFormatter()
        if calendar.isDate(day, equalTo: Date(), toGranularity: .year) {
            formatter.setLocalizedDateFormatFromTemplate("EEE d MMM")
        } else {
            formatter.setLocalizedDateFormatFromTemplate("d MMM yyyy")
        }
        return formatter.string(from: day)
    }
}

extension String {
    /// Capitalises only the first character, leaving the rest as written.
    var capitalizedFirst: String {
        guard let first else { return self }
        return first.uppercased() + dropFirst()
    }
}
