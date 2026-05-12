import SwiftUI

struct ImportDetailView: View {
    @EnvironmentObject private var store: ImportStore
    @Environment(\.dismiss) private var dismiss
    @State private var selectedTab = "summary"
    @State private var showDetails = false
    @State private var isHoveringTranscript = false
    var item: ImportItem

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(24)

            Divider()

            Picker("", selection: $selectedTab) {
                Text("Summary").tag("summary")
                Text("Transcript").tag("transcript")
                Text("Files").tag("files")
            }
            .pickerStyle(.segmented)
            .padding([.horizontal, .top], 24)

            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    if selectedTab == "summary" {
                        summarySection
                    } else if selectedTab == "transcript" {
                        transcriptSection
                    } else {
                        filesSection
                    }

                    DisclosureGroup("Technical details", isExpanded: $showDetails) {
                        technicalDetails
                            .padding(.top, 8)
                    }
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                }
                .padding(24)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 18) {
            VStack(alignment: .leading, spacing: 8) {
                Text(item.displayTitle)
                    .font(.system(size: 24, weight: .semibold))
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)

                HStack(spacing: 10) {
                    Text(DateFormatter.itemDate.string(from: item.recordingDate))
                    if let duration = item.durationSeconds {
                        Text(durationText(duration))
                    }
                    Text(generatedFilename)
                        .monospaced()
                }
                .font(.subheadline)
                .foregroundStyle(.secondary)
            }

            Spacer()

            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .trailing, spacing: 10) {
                    StatusPill(status: item.status)
                    primaryAction
                }
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.borderless)
                .help("Close")
            }
        }
    }

    @ViewBuilder
    private var primaryAction: some View {
        if let title = item.primaryActionTitle {
            Button {
                handlePrimaryAction()
            } label: {
                Label(title, systemImage: primaryActionIcon)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
        }
    }

    private var primaryActionIcon: String {
        switch item.status {
        case .readyForReview: "square.and.arrow.down"
        case .needsAttention, .failed: "arrow.clockwise"
        case .imported: "folder"
        default: "arrow.right"
        }
    }

    private var summarySection: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Summary")
                    .font(.headline)
                Text(item.analysis?.summary ?? placeholderText)
                    .font(.body)
                    .foregroundStyle(item.analysis == nil ? .secondary : .primary)
                    .textSelection(.enabled)
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("Workflow")
                    .font(.headline)
                Picker("Destination", selection: workflowBinding) {
                    ForEach(store.settings.workflows.filter(\.isEnabled)) { workflow in
                        Text(workflow.name).tag(workflow.id)
                    }
                }
                .labelsHidden()
                .frame(maxWidth: 260)
            }

            if !item.recordingDateIsCertain {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Recording date")
                        .font(.headline)
                    DatePicker("Recording date", selection: recordingDateBinding)
                        .labelsHidden()
                        .frame(maxWidth: 260)
                    Text("Estimated from file metadata. Adjust it before importing if needed.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            if let themes = item.analysis?.themes, !themes.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Themes")
                        .font(.headline)
                    FlowLayout(items: themes)
                }
            }

            if let error = item.error {
                AttentionBox(error: error, item: item, showDetails: $showDetails)
            }
        }
    }

    private var filesSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            FileActionRow(title: "Source audio", path: item.originalPath, openInsteadOfReveal: false)
            if let exportedAudio = exportedAudioPath {
                FileActionRow(title: "Exported audio", path: exportedAudio, openInsteadOfReveal: false)
            }
            FileActionRow(
                title: markdownNoteTitle,
                path: item.exportedMarkdownPath,
                openInsteadOfReveal: true,
                unavailableText: markdownNoteUnavailableText
            )
        }
    }

    private var transcriptSection: some View {
        ZStack(alignment: .topTrailing) {
            Text(item.transcript ?? "Transcript will appear here after MacWhisper finishes.")
                .font(.body.monospaced())
                .foregroundStyle(item.transcript == nil ? .secondary : .primary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)

            if isHoveringTranscript, let transcript = item.transcript, !transcript.isEmpty {
                CopyButton(text: transcript, help: "Copy transcript")
                    .padding(6)
            }
        }
        .onHover { isHoveringTranscript = $0 }
    }

    private var technicalDetails: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Spacer()
                CopyButton(text: technicalDetailsText, help: "Copy technical details")
            }
            DetailLine(label: "Source audio", value: item.originalPath)
            if let managedAudioPath = item.managedAudioPath {
                DetailLine(label: "Legacy processing copy", value: managedAudioPath)
            }
            DetailLine(label: "Generated filename", value: generatedFilename)
            DetailLine(label: "Slug", value: item.analysis?.slug ?? "Not analyzed")
            DetailLine(label: "Short slug", value: item.analysis?.shortSlug ?? "Not analyzed")
            DetailLine(label: "Recording date", value: item.recordingDateIsCertain ? "Certain" : "Estimated")
            if let exported = item.exportedMarkdownPath {
                DetailLine(label: markdownNoteTitle, value: exported)
            }
            ForEach(temporaryOperations) { operation in
                DetailLine(label: operation.kind.replacingOccurrences(of: "_", with: " "), value: operation.destinationPath.isEmpty ? operation.sourcePath : operation.destinationPath)
            }
            if let error = item.error {
                DetailLine(label: "Last error", value: error.technicalDetails)
            }
        }
    }

    private var technicalDetailsText: String {
        var lines = [
            "Source audio: \(item.originalPath)",
            "Generated filename: \(generatedFilename)",
            "Slug: \(item.analysis?.slug ?? "Not analyzed")",
            "Short slug: \(item.analysis?.shortSlug ?? "Not analyzed")",
            "Recording date: \(item.recordingDateIsCertain ? "Certain" : "Estimated")"
        ]
        if let managedAudioPath = item.managedAudioPath {
            lines.insert("Legacy processing copy: \(managedAudioPath)", at: 1)
        }
        if let exported = item.exportedMarkdownPath {
            lines.append("\(markdownNoteTitle): \(exported)")
        }
        lines.append(contentsOf: temporaryOperations.map { operation in
            let label = operation.kind.replacingOccurrences(of: "_", with: " ")
            let value = operation.destinationPath.isEmpty ? operation.sourcePath : operation.destinationPath
            return "\(label): \(value)"
        })
        if let error = item.error {
            lines.append("Last error: \(error.technicalDetails)")
        }
        return lines.joined(separator: "\n")
    }

    private var workflowBinding: Binding<String> {
        Binding {
            item.workflow
        } set: { workflow in
            var updated = item
            updated.workflow = workflow
            store.update(updated)
        }
    }

    private var recordingDateBinding: Binding<Date> {
        Binding {
            item.recordingDate
        } set: { date in
            var updated = item
            updated.recordingDate = date
            updated.recordingDateIsCertain = true
            store.update(updated)
        }
    }

    private var placeholderText: String {
        switch item.status {
        case .queued, .transcribing, .analyzing:
            "Processing is running."
        case .needsAttention, .failed:
            item.error?.message ?? "This memo needs attention."
        default:
            "No summary yet."
        }
    }

    private func handlePrimaryAction() {
        switch item.status {
        case .new:
            ImportProcessor(store: store).process(item.id)
        case .readyForReview:
            ImportProcessor(store: store).export(item.id)
        case .needsAttention, .failed:
            ImportProcessor(store: store).process(item.id)
        case .imported:
            Finder.reveal(item.exportedMarkdownPath ?? exportedAudioPath ?? item.originalPath)
        default:
            break
        }
    }

    private func durationText(_ duration: Double) -> String {
        let total = Int(duration.rounded())
        return "\(total / 60)m \(total % 60)s"
    }

    private var generatedFilename: String {
        let policy = store.workflowPolicy(for: item.workflow)
        guard item.analysis != nil else { return "New filename pending" }
        return FilenamePattern.render(pattern: policy.filenamePattern, item: item, workflowName: policy.name)
    }

    private var markdownNoteTitle: String {
        let policy = store.workflowPolicy(for: item.workflow)
        return policy.transcriptBehavior == .appendToMonthlyNote ? "Monthly note" : "Markdown note"
    }

    private var markdownNoteUnavailableText: String {
        let policy = store.workflowPolicy(for: item.workflow)
        switch policy.transcriptBehavior {
        case .doNotExportTranscript:
            return "Not generated by this workflow"
        case .appendToMonthlyNote, .createMarkdownFile, .saveTranscriptOnly:
            return "Created after export"
        }
    }

    private var exportedAudioPath: String? {
        item.fileOperations.last { operation in
            ["copy", "move"].contains(operation.kind) && !isCachePath(operation.destinationPath)
        }?.destinationPath
    }

    private var temporaryOperations: [FileOperationRecord] {
        item.fileOperations.filter { operation in
            operation.kind.contains("temporary_processing") || operation.kind == "clear_cache"
        }
    }

    private func isCachePath(_ path: String) -> Bool {
        path.hasPrefix(AppPaths.managedAudioDirectory.path)
            || path.hasPrefix(AppPaths.processingCacheDirectory.path)
            || path.hasPrefix(AppPaths.dropImportDirectory.path)
    }
}

struct StatusPill: View {
    var status: ImportStatus

    var body: some View {
        Text(status.label)
            .font(.caption.weight(.medium))
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(color.opacity(0.14))
            .foregroundStyle(color)
            .clipShape(Capsule())
    }

    private var color: Color {
        switch status {
        case .readyForReview: .accentColor
        case .imported: .green
        case .failed, .needsAttention: .red
        case .transcribing, .analyzing, .importing, .queued: .orange
        default: .secondary
        }
    }
}

struct FileActionRow: View {
    var title: String
    var path: String?
    var openInsteadOfReveal: Bool
    var unavailableText = "Not available"

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.subheadline.weight(.medium))
                Text(path ?? unavailableText)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            if path != nil {
                Button(openInsteadOfReveal ? "Open" : "Show in Finder") {
                    if openInsteadOfReveal {
                        Finder.open(path)
                    } else {
                        Finder.reveal(path)
                    }
                }
            }
        }
        .padding(12)
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}

struct AttentionBox: View {
    var error: ProcessingError
    var item: ImportItem
    @Binding var showDetails: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(error.message)
                .font(.headline)
            HStack {
                Button("Open in Finder") {
                    Finder.reveal(item.originalPath)
                }
                Button("Show technical details") {
                    showDetails = true
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.red.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}

struct DetailLine: View {
    var label: String
    var value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.caption.monospaced())
                .textSelection(.enabled)
        }
    }
}

struct CopyButton: View {
    var text: String
    var help: String

    var body: some View {
        Button {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
        } label: {
            Image(systemName: "doc.on.doc")
        }
        .buttonStyle(.borderless)
        .help(help)
    }
}

struct FlowLayout: View {
    var items: [String]

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 96), spacing: 8)], alignment: .leading, spacing: 8) {
            ForEach(items, id: \.self) { item in
                Text(item)
                    .font(.caption)
                    .lineLimit(1)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .background(Color(nsColor: .controlBackgroundColor))
                    .clipShape(Capsule())
            }
        }
    }
}
