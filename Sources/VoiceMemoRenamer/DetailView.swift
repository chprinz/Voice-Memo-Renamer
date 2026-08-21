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
    /// Snapshots of the drafts as of the last `syncDrafts()`. Comparing against these
    /// instead of the live store value is what tells "the user typed something" apart
    /// from "a draft synced before a background step finished is now stale" — the
    /// latter must never overwrite a result that only just arrived.
    @State private var titleBaseline = ""
    @State private var summaryBaseline = ""
    @State private var transcriptBaseline = ""
    /// The date is read from the file, so it reads as a fact until the pencil says
    /// otherwise. Unlocking is per recording, never carried to the next one.
    @State private var isEditingRecordingDate = false
    /// Which recording the drafts above belong to. In the split view this panel is
    /// reused for the next selection, so without this the drafts of one recording
    /// would be shown — and saved — on the next one.
    @State private var loadedItemID: ImportItem.ID?
    var item: ImportItem
    /// Closing means "dismiss the sheet" in one place and "clear the selection" in
    /// the other. Both need the same button.
    var onClose: (() -> Void)?

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

                            DisclosureGroup("Technical details", isExpanded: $showDetails) {
                                technicalDetails
                                    .padding(.top, 8)
                            }
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        }
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
        .onAppear {
            loadedItemID = item.id
            syncDrafts()
        }
        // Keyed on the whole item, not just status, so a transcript or analysis that
        // lands from a background task always reaches the pane — waiting on a status
        // transition alone missed cases where the pane had been sitting on this
        // recording since before that background task even started.
        .onChange(of: item) { _ in refreshPristineDrafts() }
        .onChange(of: item.id) { newID in
            commitTextEdits(to: loadedItemID)
            loadedItemID = newID
            isEditingRecordingDate = false
            syncDrafts()
        }
        .onDisappear { commitTextEdits() }
    }

    /// Editing is only safe once a background task can no longer overwrite it —
    /// otherwise a finished analysis could silently clobber what you just typed.
    private var isEditable: Bool {
        Self.isEditable(item)
    }

    private static func isEditable(_ item: ImportItem) -> Bool {
        ![.new, .queued, .transcribing, .analyzing, .importing, .imported].contains(item.status)
    }

    private func syncDrafts() {
        titleDraft = item.analysis?.title ?? item.displayTitle
        summaryDraft = item.analysis?.summary ?? ""
        transcriptDraft = item.transcript ?? ""
        titleBaseline = titleDraft
        summaryBaseline = summaryDraft
        transcriptBaseline = transcriptDraft
    }

    /// Adopts the item's current values for whichever drafts the user hasn't actually
    /// touched yet (draft still equal to its own baseline). A draft that differs from
    /// its baseline is being edited, or holds an edit not yet committed, so it's left
    /// alone — this only ever pulls in a background result, never overwrites a person.
    private func refreshPristineDrafts() {
        guard isEditable else { return }
        let freshTitle = item.analysis?.title ?? item.displayTitle
        if titleDraft == titleBaseline, titleDraft != freshTitle {
            titleDraft = freshTitle
            titleBaseline = freshTitle
        }
        let freshSummary = item.analysis?.summary ?? ""
        if summaryDraft == summaryBaseline, summaryDraft != freshSummary {
            summaryDraft = freshSummary
            summaryBaseline = freshSummary
        }
        let freshTranscript = item.transcript ?? ""
        if transcriptDraft == transcriptBaseline, transcriptDraft != freshTranscript {
            transcriptDraft = freshTranscript
            transcriptBaseline = freshTranscript
        }
    }

    /// Saves edited title/summary/transcript back to the store. Called on tab switch,
    /// when the selection moves to another recording, on dismiss, and before the
    /// primary action — not on every keystroke, so typing doesn't trigger a
    /// history.json write per character.
    ///
    /// The target is passed explicitly because the selection may already have moved
    /// on by the time the edits are saved; they belong to the recording that was on
    /// screen while they were typed.
    private func commitTextEdits(to itemID: ImportItem.ID? = nil) {
        guard var updated = store.item(id: itemID ?? item.id), Self.isEditable(updated) else { return }
        var changed = false

        // Requiring a difference from the baseline (what was on screen right after the
        // last sync), not just from the live store value, is what keeps a draft that
        // went stale while a background step was still running from clobbering the
        // result that step just produced.
        if titleDraft != titleBaseline, titleDraft != (updated.analysis?.title ?? updated.displayTitle) {
            if updated.analysis == nil {
                updated.analysis = ImportProcessor.filenameOnlyAnalysis(for: updated)
            }
            updated.analysis?.title = titleDraft
            changed = true
        }
        if summaryDraft != summaryBaseline, summaryDraft != (updated.analysis?.summary ?? "") {
            if updated.analysis == nil {
                updated.analysis = ImportProcessor.filenameOnlyAnalysis(for: updated)
            }
            updated.analysis?.summary = summaryDraft
            changed = true
        }
        if transcriptDraft != transcriptBaseline, transcriptDraft != (updated.transcript ?? "") {
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
                }
                .font(.subheadline)
                .foregroundStyle(.secondary)

                Text(generatedFilename)
                    .font(.subheadline.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer()

            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .trailing, spacing: 10) {
                    StatusPill(status: item.status)
                    primaryAction
                }
                Button {
                    if let onClose {
                        onClose()
                    } else {
                        dismiss()
                    }
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.borderless)
                .help(onClose == nil ? "Close" : "Close \u{2014} or press Escape")
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
        default: "arrow.right"
        }
    }

    private var summarySection: some View {
        VStack(alignment: .leading, spacing: 18) {
            if item.status == .imported {
                filedNotice
            }

            if !summaryIsDisabledForWorkflow || hasSummaryContent {
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
            }

            workflowLine

            VStack(alignment: .leading, spacing: 8) {
                Text("Recording date")
                    .font(.headline)
                if isEditable && isEditingRecordingDate {
                    DatePicker("Recording date", selection: recordingDateBinding)
                        .labelsHidden()
                        .frame(maxWidth: 260)
                } else {
                    HStack(spacing: 6) {
                        Text(DateFormatter.itemDate.string(from: item.recordingDate))
                            .font(.body)
                        if isEditable {
                            EditPencil(help: "Edit the recording date") {
                                isEditingRecordingDate = true
                            }
                        }
                    }
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
                AttentionBox(error: error, item: item, showDetails: $showDetails) {
                    selectedTab = "files"
                }
            }
        }
    }

    /// Read-only after import needs a reason on screen, not just greyed-out fields:
    /// the note and the filename are already written, so the place to change them is
    /// review, before the write.
    @ViewBuilder
    private var filedNotice: some View {
        let policy = store.workflowPolicy(for: item.workflow)
        HStack(alignment: .firstTextBaseline, spacing: 7) {
            Image(systemName: "lock")
                .foregroundStyle(.secondary)
            Text(policy.reviewBehavior == .autoExportWhenReady
                 ? "Already filed. This workflow imports automatically \u{2014} set it to \"Always review first\" in Settings to edit before the note and filename are written."
                 : "Already filed. Title, summary and date can be edited during review, before the note and filename are written.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .font(.caption)
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
    }

    /// A statement rather than a second control: the workflow was already chosen in
    /// the top bar. Overriding it for a single recording stays possible, one step
    /// behind "Change".
    @ViewBuilder
    private var workflowLine: some View {
        let policy = store.workflowPolicy(for: item.workflow)
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text("Workflow:")
                    .foregroundStyle(.secondary)
                Text(policy.name)
                if item.workflow == store.settings.defaultWorkflow {
                    Text("(Default)")
                        .foregroundStyle(.secondary)
                }
                if isEditable {
                    Text("·")
                        .foregroundStyle(.tertiary)
                    Menu("Change") {
                        ForEach(store.settings.workflows.filter(\.isEnabled)) { workflow in
                            Button {
                                applyWorkflow(workflow.id)
                            } label: {
                                if workflow.id == item.workflow {
                                    Label(workflow.name, systemImage: "checkmark")
                                } else {
                                    Text(workflow.name)
                                }
                            }
                        }
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .fixedSize()
                    .help("File this one recording under a different workflow.")
                }
            }
            .font(.subheadline)

            Text(WorkflowSummary.planTags(for: policy))
                .font(.caption)
                .foregroundStyle(.secondary)

            if isEditable, let suggestion = suggestedWorkflow {
                HStack(spacing: 8) {
                    Text("The model would file this under \(suggestion.name).")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Button("Use") {
                        applyWorkflow(suggestion.id)
                    }
                    .controlSize(.small)
                }
                .padding(.top, 2)
            }
        }
    }

    private var filesSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            FileActionRow(
                title: "Original file",
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
            DetailLine(label: "Audio in use", value: item.originalPath)
            if let managedAudioPath = item.managedAudioPath {
                DetailLine(label: "Temporary copy", value: managedAudioPath)
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
                DetailLine(label: Self.operationLabel(operation.kind), value: operation.destinationPath.isEmpty ? operation.sourcePath : operation.destinationPath)
            }
            if let error = item.error {
                DetailLine(label: "Last error", value: error.technicalDetails)
            }
        }
    }

    /// Internal operation kinds are snake_case identifiers meant for the log, not
    /// for reading. Map the ones that surface here; fall back to a de-underscored
    /// form so a new kind degrades instead of disappearing.
    static func operationLabel(_ kind: String) -> String {
        switch kind {
        case "managed_processing_copy": "Temporary copy made"
        case "delete_managed_processing_copy": "Temporary copy deleted"
        case "delete_drop_import_copy": "Dropped copy deleted"
        case "temporary_processing_copy": "Converted copy made"
        case "delete_temporary_processing_copy": "Converted copy deleted"
        case "normalize": "Normalized"
        case "delete_normalized_copy": "Normalized copy deleted"
        case "clear_cache": "Cleared from cache"
        case "rename_original": "Original renamed"
        case "append": "Appended to note"
        case "write": "Note written"
        case "move", "normalize_move", "compress_move", "normalize_compress_move": "Audio moved"
        case "copy", "normalize_copy", "compress_copy", "normalize_compress_copy": "Audio copied"
        default: kind.replacingOccurrences(of: "_", with: " ").capitalizedFirst
        }
    }

    private var technicalDetailsText: String {
        var lines = [
            "Original filename: \(item.sourceFilename ?? item.originalFilename)",
            "Audio in use: \(item.originalPath)",
            "Generated filename: \(generatedFilename)",
            "Slug: \(item.analysis?.slug ?? "Not analyzed")",
            "Short slug: \(item.analysis?.shortSlug ?? "Not analyzed")",
            "Recording date: \(item.recordingDateIsCertain ? "Certain" : "Estimated")"
        ]
        if let sourcePath = item.sourcePath, sourcePath != item.originalPath {
            let label = isCachePath(sourcePath) ? "Temporary copy" : "Original path"
            lines.insert("\(label): \(sourcePath)", at: 1)
        }
        if let managedAudioPath = item.managedAudioPath {
            lines.insert("Temporary copy: \(managedAudioPath)", at: min(2, lines.count))
        }
        if let fingerprint = item.audioFingerprint {
            lines.append("Audio fingerprint: \(fingerprint)")
        }
        if let exported = item.exportedMarkdownPath {
            lines.append("\(markdownNoteTitle): \(exported)")
        }
        lines.append(contentsOf: temporaryOperations.map { operation in
            let label = Self.operationLabel(operation.kind)
            let value = operation.destinationPath.isEmpty ? operation.sourcePath : operation.destinationPath
            return "\(label): \(value)"
        })
        if let error = item.error {
            lines.append("Last error: \(error.technicalDetails)")
        }
        return lines.joined(separator: "\n")
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

    private var summaryIsDisabledForWorkflow: Bool {
        let policy = store.workflowPolicy(for: item.workflow)
        return !policy.usesSmartAnalysis || policy.summaryStyle == .none
    }

    private var hasSummaryContent: Bool {
        item.analysis?.summaryPoints?.isEmpty == false || item.analysis?.summary.nilIfBlank != nil
    }

    private var placeholderText: String {
        switch item.status {
        case .queued, .transcribing, .analyzing:
            "Processing is running."
        case .needsAttention, .failed:
            item.error?.message ?? "This recording needs attention."
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
            // A user-initiated retry should always get a fresh shot: retryCount only
            // exists to stop unattended auto-retry loops, not to lock the user out.
            var updated = item
            updated.retryCount = 0
            store.update(updated)
            ImportProcessor(store: store).process(item.id)
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
        guard item.analysis != nil else { return "Filename pending" }
        return FilenamePattern.render(pattern: policy.filenamePattern, item: item, workflowName: policy.name)
    }

    private var markdownNoteTitle: String {
        let policy = store.workflowPolicy(for: item.workflow)
        return policy.transcriptBehavior == .appendToMonthlyNote ? "Monthly note" : "Note"
    }

    private var markdownNoteUnavailableText: String {
        let policy = store.workflowPolicy(for: item.workflow)
        switch policy.transcriptBehavior {
        case .doNotExportTranscript:
            return "Not written by this workflow"
        case .appendToMonthlyNote, .createMarkdownFile, .saveTranscriptOnly:
            return "Written when the recording is imported"
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
            return "The temporary copy was cleared and no original path was recorded."
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
    var onShowTechnicalDetails: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(error.message)
                .font(.headline)
            HStack {
                Button("Show in Finder") {
                    Finder.reveal(item.originalPath)
                }
                Button("Show technical details") {
                    onShowTechnicalDetails()
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


/// The review panel as it appears in the split view. Same content as the sheet,
/// without the sheet's close button, so moving through several recordings does not
/// mean opening and dismissing each one.
struct ImportDetailPane: View {
    var item: ImportItem
    var onClose: () -> Void

    var body: some View {
        ImportDetailView(item: item, onClose: onClose)
    }
}
