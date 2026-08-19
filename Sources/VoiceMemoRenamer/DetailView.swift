import SwiftUI

struct ImportDetailView: View {
    @EnvironmentObject private var store: ImportStore
    @Environment(\.dismiss) private var dismiss
    @State private var selectedTab = "summary"
    @State private var showDetails = false
    @State private var isHoveringTranscript = false
    @State private var copyToastMessage: String?
    @State private var titleDraft = ""
    @State private var summaryDraft = ""
    @State private var transcriptDraft = ""
    var item: ImportItem

    var body: some View {
        ZStack(alignment: .bottom) {
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
                .onChange(of: selectedTab) { _ in commitTextEdits() }

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

            if let copyToastMessage {
                Text(copyToastMessage)
                    .font(.caption.weight(.medium))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(.regularMaterial, in: Capsule())
                    .shadow(radius: 8)
                    .padding(.bottom, 18)
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
            }
        }
        .onAppear { syncDrafts() }
        .onChange(of: item.status) { _ in if isEditable { syncDrafts() } }
        .onDisappear { commitTextEdits() }
    }

    /// Editing is only safe once a background task can no longer overwrite it —
    /// otherwise a finished analysis could silently clobber what you just typed.
    private var isEditable: Bool {
        ![.new, .queued, .transcribing, .analyzing, .importing].contains(item.status)
    }

    private func syncDrafts() {
        titleDraft = item.analysis?.title ?? item.displayTitle
        summaryDraft = item.analysis?.summary ?? ""
        transcriptDraft = item.transcript ?? ""
    }

    /// Saves edited title/summary/transcript back to the store. Called on tab switch,
    /// on dismiss, and before the primary action — not on every keystroke, so typing
    /// doesn't trigger a history.json write per character.
    private func commitTextEdits() {
        guard isEditable else { return }
        var updated = item
        var changed = false

        if titleDraft != (item.analysis?.title ?? item.displayTitle) {
            if updated.analysis == nil {
                updated.analysis = ImportProcessor.filenameOnlyAnalysis(for: updated)
            }
            updated.analysis?.title = titleDraft
            changed = true
        }
        if summaryDraft != (item.analysis?.summary ?? "") {
            if updated.analysis == nil {
                updated.analysis = ImportProcessor.filenameOnlyAnalysis(for: updated)
            }
            updated.analysis?.summary = summaryDraft
            changed = true
        }
        if transcriptDraft != (item.transcript ?? "") {
            updated.transcript = transcriptDraft
            changed = true
        }

        if changed {
            store.update(updated)
        }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 18) {
            VStack(alignment: .leading, spacing: 8) {
                if isEditable {
                    TextField("Title", text: $titleDraft, axis: .vertical)
                        .textFieldStyle(.plain)
                        .font(.system(size: 24, weight: .semibold))
                        .lineLimit(1...2)
                } else {
                    Text(item.displayTitle)
                        .font(.system(size: 24, weight: .semibold))
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }

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
                if let points = item.analysis?.summaryPoints, !points.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(points, id: \.self) { point in
                            Text("• \(point)")
                                .font(.body)
                                .textSelection(.enabled)
                        }
                    }
                }
                if isEditable {
                    TextEditor(text: $summaryDraft)
                        .font(.body)
                        .frame(minHeight: 60, maxHeight: 120)
                        .padding(6)
                        .background(Color(nsColor: .controlBackgroundColor))
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                        .overlay {
                            RoundedRectangle(cornerRadius: 6)
                                .strokeBorder(Color(nsColor: .separatorColor))
                        }
                } else {
                    Text(item.analysis?.summary.nilIfBlank ?? placeholderText)
                        .font(.body)
                        .foregroundStyle(item.analysis?.summary.nilIfBlank == nil ? .secondary : .primary)
                        .textSelection(.enabled)
                }
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
                if let suggestion = suggestedWorkflow {
                    HStack(spacing: 8) {
                        Text("The model would file this under \(suggestion.name).")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Button("Use") {
                            applyWorkflow(suggestion.id)
                        }
                        .controlSize(.small)
                    }
                }
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("Recording date")
                    .font(.headline)
                DatePicker("Recording date", selection: recordingDateBinding)
                    .labelsHidden()
                    .frame(maxWidth: 260)
                Text(recordingDateExplanation)
                    .font(.caption)
                    .foregroundStyle(.secondary)
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
            FileActionRow(
                title: "Source audio",
                path: sourceAudioPath,
                openInsteadOfReveal: false,
                unavailableText: sourceAudioUnavailableText
            )
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

    @ViewBuilder
    private var transcriptSection: some View {
        if isEditable {
            ZStack(alignment: .topTrailing) {
                TextEditor(text: $transcriptDraft)
                    .font(.body.monospaced())
                    .frame(minHeight: 240)
                    .padding(6)
                    .background(Color(nsColor: .controlBackgroundColor))
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    .overlay {
                        RoundedRectangle(cornerRadius: 6)
                            .strokeBorder(Color(nsColor: .separatorColor))
                    }

                if isHoveringTranscript, !transcriptDraft.isEmpty {
                    CopyButton(text: transcriptDraft, help: "Copy transcript") {
                        showCopyToast("Transcript copied")
                    }
                        .padding(10)
                }
            }
            .onHover { isHoveringTranscript = $0 }
        } else {
            ZStack(alignment: .topTrailing) {
                Text(item.transcript ?? "Transcript will appear here after MacWhisper finishes.")
                    .font(.body.monospaced())
                    .foregroundStyle(item.transcript == nil ? .secondary : .primary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)

                if isHoveringTranscript, let transcript = item.transcript, !transcript.isEmpty {
                    CopyButton(text: transcript, help: "Copy transcript") {
                        showCopyToast("Transcript copied")
                    }
                        .padding(6)
                }
            }
            .onHover { isHoveringTranscript = $0 }
        }
    }

    private var technicalDetails: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Spacer()
                CopyButton(text: technicalDetailsText, help: "Copy technical details") {
                    showCopyToast("Details copied")
                }
            }
            DetailLine(label: "Original filename", value: item.sourceFilename ?? item.originalFilename)
            if let sourcePath = item.sourcePath, sourcePath != item.originalPath, !isCachePath(sourcePath) {
                DetailLine(label: "Original path", value: sourcePath)
            }
            DetailLine(label: "Current audio", value: item.originalPath)
            if let managedAudioPath = item.managedAudioPath {
                DetailLine(label: "Processing copy", value: managedAudioPath)
            }
            if let fingerprint = item.audioFingerprint {
                DetailLine(label: "Audio fingerprint", value: fingerprint)
            }
            DetailLine(label: "Generated filename", value: generatedFilename)
            DetailLine(label: "Slug", value: item.analysis?.slug ?? "Not analyzed")
            DetailLine(label: "Short slug", value: item.analysis?.shortSlug ?? "Not analyzed")
            DetailLine(label: "Recording date", value: "\(item.recordingDateIsCertain ? "Certain" : "Estimated") - \(item.recordingDateSource.label)")
            if let format = audioFormatSummary {
                DetailLine(label: "Audio format", value: format)
            }
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
            "Original filename: \(item.sourceFilename ?? item.originalFilename)",
            "Current audio: \(item.originalPath)",
            "Generated filename: \(generatedFilename)",
            "Slug: \(item.analysis?.slug ?? "Not analyzed")",
            "Short slug: \(item.analysis?.shortSlug ?? "Not analyzed")",
            "Recording date: \(item.recordingDateIsCertain ? "Certain" : "Estimated")"
        ]
        if let sourcePath = item.sourcePath, sourcePath != item.originalPath {
            let label = isCachePath(sourcePath) ? "Imported temporary source" : "Original path"
            lines.insert("\(label): \(sourcePath)", at: 1)
        }
        if let managedAudioPath = item.managedAudioPath {
            lines.insert("Processing copy: \(managedAudioPath)", at: min(2, lines.count))
        }
        if let fingerprint = item.audioFingerprint {
            lines.append("Audio fingerprint: \(fingerprint)")
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
            applyWorkflow(workflow)
        }
    }

    private func applyWorkflow(_ workflow: String) {
        var updated = item
        updated.workflow = workflow
        updated.workflowIsUserAssigned = true
        store.update(updated)
    }

    /// Shown only as a hint. The model never reassigns a workflow on its own.
    private var suggestedWorkflow: WorkflowPolicy? {
        guard let suggested = item.analysis?.suggestedWorkflow?.nilIfBlank else { return nil }
        let suggestedID = WorkflowPolicy.canonicalID(suggested)
        guard suggestedID != item.workflow else { return nil }
        return store.settings.workflows.first { $0.id == suggestedID && $0.isEnabled }
    }

    private var recordingDateExplanation: String {
        switch item.recordingDateSource {
        case .transcript:
            return "Taken from a date spoken in the recording. It replaced the date stored in the file."
        case .manual:
            return "Set by you."
        case .fileMetadata:
            return item.recordingDateIsCertain
                ? "Read from the file's creation date."
                : "Estimated from file metadata. Adjust it before importing if needed."
        }
    }

    private var recordingDateBinding: Binding<Date> {
        Binding {
            item.recordingDate
        } set: { date in
            var updated = item
            updated.recordingDate = date
            updated.recordingDateIsCertain = true
            updated.recordingDateSource = .manual
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
        commitTextEdits()
        switch item.status {
        case .new:
            ImportProcessor(store: store).process(item.id)
        case .readyForReview:
            Task { await ImportProcessor(store: store).export(item.id) }
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

    private var sourceAudioPath: String? {
        let candidates = [item.sourcePath, item.originalPath].compactMap { $0 }
        return candidates.first { path in
            !isCachePath(path) || FileManager.default.fileExists(atPath: path)
        }
    }

    private var sourceAudioUnavailableText: String {
        if let sourcePath = item.sourcePath ?? Optional(item.originalPath),
           isCachePath(sourcePath),
           !FileManager.default.fileExists(atPath: sourcePath) {
            return "Temporary import copy was cleared. Original path was not provided."
        }
        return "Not available"
    }

    private var audioFormatSummary: String? {
        guard let path = [item.managedAudioPath, item.originalPath, item.sourcePath]
            .compactMap({ $0 })
            .first(where: { FileManager.default.fileExists(atPath: $0) }) else { return nil }
        return AudioInspector.formatSummary(for: URL(fileURLWithPath: path))
    }

    private var temporaryOperations: [FileOperationRecord] {
        item.fileOperations.filter { operation in
            operation.kind.contains("temporary_processing")
                || operation.kind.contains("managed_processing")
                || operation.kind == "delete_managed_processing_copy"
                || operation.kind == "clear_cache"
        }
    }

    private func isCachePath(_ path: String) -> Bool {
        path.hasPrefix(AppPaths.managedAudioDirectory.path)
            || path.hasPrefix(AppPaths.processingCacheDirectory.path)
            || path.hasPrefix(AppPaths.dropImportDirectory.path)
    }

    private func showCopyToast(_ message: String) {
        withAnimation(.easeOut(duration: 0.12)) {
            copyToastMessage = message
        }
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            if copyToastMessage == message {
                withAnimation(.easeIn(duration: 0.16)) {
                    copyToastMessage = nil
                }
            }
        }
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
    var copied: () -> Void = {}

    var body: some View {
        Button {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
            copied()
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
