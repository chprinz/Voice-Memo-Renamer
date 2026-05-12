import SwiftUI
import UniformTypeIdentifiers

enum QueueFilter: String, CaseIterable, Identifiable {
    case all
    case active
    case review
    case attention
    case imported

    var id: String { rawValue }

    var label: String {
        switch self {
        case .all: "All"
        case .active: "Active"
        case .review: "Review"
        case .attention: "Attention"
        case .imported: "Imported"
        }
    }
}

enum ConnectivityState {
    case ok
    case unknown
    case unavailable(String)

    var color: Color {
        switch self {
        case .ok: .green
        case .unknown: .secondary
        case .unavailable: .red
        }
    }

    var tooltip: String {
        switch self {
        case .ok: "Connected"
        case .unknown: "Status unknown"
        case .unavailable(let message): message
        }
    }
}

struct ContentView: View {
    @EnvironmentObject private var store: ImportStore
    @State private var filter: QueueFilter = .all
    @State private var inspectedItemID: ImportItem.ID?
    @State private var showingSettings = false
    @State private var isTargeted = false
    @State private var macWhisperState: ConnectivityState = .unknown
    @State private var lmStudioState: ConnectivityState = .unknown

    var body: some View {
        VStack(spacing: 0) {
            header
            filterBar
            Divider()
            queue
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .onDrop(of: supportedTypes, isTargeted: $isTargeted) { providers in
            handleDrop(providers)
        }
        .sheet(item: inspectedItemBinding) { item in
            ImportDetailView(item: item)
                .environmentObject(store)
                .frame(minWidth: 720, idealWidth: 800, minHeight: 620, idealHeight: 700)
        }
        .sheet(isPresented: $showingSettings) {
            SettingsView()
                .environmentObject(store)
                .frame(minWidth: 860, idealWidth: 980, minHeight: 680, idealHeight: 760)
        }
        .task {
            await refreshConnectivity()
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Text("Voice Memo Renamer")
                .font(.headline)

            Picker("Default Workflow", selection: defaultWorkflowBinding) {
                ForEach(store.settings.workflows.filter(\.isEnabled)) { workflow in
                    Text(workflow.name).tag(workflow.id)
                }
            }
            .labelsHidden()
            .frame(width: 210)

            Button {
                chooseAudioFiles()
            } label: {
                Label("Choose Audio", systemImage: "waveform.badge.plus")
            }
            .buttonStyle(.borderedProminent)

            Button {
                showingSettings = true
            } label: {
                Image(systemName: "gearshape")
            }
            .buttonStyle(.borderless)
            .help("Settings")

            Spacer()

            if store.hasActiveProcessing {
                Button {
                    store.cancelActiveProcessing()
                } label: {
                    Label("Cancel Active", systemImage: "xmark.circle")
                }
                .controlSize(.small)
            }

            if store.items.contains(where: { $0.status == .imported }) {
                Button {
                    store.clearCompletedItems()
                } label: {
                    Label("Clear Completed", systemImage: "checkmark.circle")
                }
                .controlSize(.small)
            }

            ConnectivityIcon(systemName: "waveform.path.ecg", state: macWhisperState)
                .help("MacWhisper CLI: \(macWhisperState.tooltip)")
            ConnectivityIcon(systemName: "brain.head.profile", state: lmStudioState)
                .help("LM Studio: \(lmStudioState.tooltip)")
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    private var filterBar: some View {
        HStack {
            Picker("Filter", selection: $filter) {
                ForEach(QueueFilter.allCases) { filter in
                    Text(filter.label).tag(filter)
                }
            }
            .pickerStyle(.segmented)
            .frame(width: 430)

            Spacer()
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 12)
    }

    private var queue: some View {
        Group {
            if filteredItems.isEmpty {
                EmptyQueueState(isTargeted: isTargeted)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(filteredItems) { item in
                    QueueRow(
                        item: item,
                        policy: store.workflowPolicy(for: item.workflow),
                        action: { handlePrimaryAction(item) }
                    )
                    .contentShape(Rectangle())
                    .onTapGesture {
                        inspectedItemID = item.id
                    }
                    .listRowInsets(EdgeInsets(top: 8, leading: 20, bottom: 8, trailing: 20))
                }
                .listStyle(.inset)
                .scrollContentBackground(.hidden)
            }
        }
        .background(isTargeted ? Color.accentColor.opacity(0.08) : Color.clear)
    }

    private var inspectedItemBinding: Binding<ImportItem?> {
        Binding {
            guard let inspectedItemID else { return nil }
            return store.item(id: inspectedItemID)
        } set: { item in
            inspectedItemID = item?.id
        }
    }

    private var defaultWorkflowBinding: Binding<String> {
        Binding {
            store.settings.defaultWorkflow
        } set: { workflow in
            store.setDefaultWorkflow(workflow)
        }
    }

    private var filteredItems: [ImportItem] {
        store.items.filter { item in
            switch filter {
            case .all:
                true
            case .active:
                [.new, .queued, .transcribing, .transcribed, .analyzing, .importing].contains(item.status)
            case .review:
                item.status == .readyForReview
            case .attention:
                item.status == .needsAttention || item.status == .failed
            case .imported:
                item.status == .imported
            }
        }
    }

    private var supportedTypes: [UTType] {
        [.fileURL, .audio, .mpeg4Audio, .mp3, .wav, .aiff, .mpeg4Movie, .quickTimeMovie]
    }

    private func refreshConnectivity() async {
        do {
            let service = MacWhisperService(
                executablePath: store.settings.macWhisperPath,
                timeoutSeconds: store.settings.transcriptionTimeoutSeconds
            )
            _ = try await service.version()
            await MainActor.run { macWhisperState = .ok }
        } catch {
            await MainActor.run {
                macWhisperState = .unavailable((error as? ProcessingFailure)?.details ?? error.localizedDescription)
            }
        }

        guard let baseURL = URL(string: store.settings.lmStudioBaseURL) else {
            lmStudioState = .unavailable("Invalid LM Studio URL")
            return
        }
        do {
            let requestURL = baseURL.appendingPathComponent("models")
            let (_, response) = try await URLSession.shared.data(from: requestURL)
            if let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) {
                await MainActor.run { lmStudioState = .ok }
            } else {
                await MainActor.run { lmStudioState = .unavailable("LM Studio did not respond with a valid model list") }
            }
        } catch {
            await MainActor.run { lmStudioState = .unavailable(error.localizedDescription) }
        }
    }

    private func handlePrimaryAction(_ item: ImportItem) {
        switch item.status {
        case .new:
            ImportProcessor(store: store).process(item.id)
        case .readyForReview:
            ImportProcessor(store: store).export(item.id)
        case .failed, .needsAttention:
            ImportProcessor(store: store).process(item.id)
        case .imported:
            Finder.reveal(item.exportedMarkdownPath ?? item.originalPath)
        default:
            break
        }
    }

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        providers.forEach(importDroppedProvider)
        return true
    }

    private func importDroppedProvider(_ provider: NSItemProvider) {
        if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, error in
                guard error == nil, let url = fileURL(from: item) else { return }
                importAudioFile(url)
            }
            return
        }

        guard let type = supportedTypes.first(where: { provider.hasItemConformingToTypeIdentifier($0.identifier) }) else {
            return
        }
        provider.loadFileRepresentation(forTypeIdentifier: type.identifier) { temporaryURL, error in
            guard error == nil, let temporaryURL else { return }
            let destinationURL = AppPaths.dropImportDirectory
                .appendingPathComponent(UUID().uuidString)
                .appendingPathExtension(temporaryURL.pathExtension.isEmpty ? "m4a" : temporaryURL.pathExtension)
            do {
                try FileManager.default.createDirectory(at: AppPaths.dropImportDirectory, withIntermediateDirectories: true)
                try? FileManager.default.removeItem(at: destinationURL)
                try FileManager.default.copyItem(at: temporaryURL, to: destinationURL)
                importAudioFile(destinationURL)
            } catch {
                return
            }
        }
    }

    private func importAudioFile(_ url: URL) {
        Task { @MainActor in
            if let imported = await store.addItem(from: url) {
                ImportProcessor(store: store).process(imported.id)
            }
        }
    }

    private func fileURL(from item: NSSecureCoding?) -> URL? {
        if let url = item as? URL {
            return url
        }
        if let data = item as? Data {
            return URL(dataRepresentation: data, relativeTo: nil)
        }
        if let string = item as? String {
            return URL(string: string) ?? URL(fileURLWithPath: string)
        }
        if let nsString = item as? NSString {
            let string = nsString as String
            return URL(string: string) ?? URL(fileURLWithPath: string)
        }
        return nil
    }

    private func chooseAudioFiles() {
        let panel = NSOpenPanel()
        panel.title = "Choose audio files"
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowedContentTypes = [.audio, .mpeg4Audio, .mp3, .wav, .aiff]

        if panel.runModal() == .OK {
            Task { @MainActor in
                for url in panel.urls {
                    if let imported = await store.addItem(from: url) {
                        ImportProcessor(store: store).process(imported.id)
                    }
                }
            }
        }
    }
}

struct ConnectivityIcon: View {
    var systemName: String
    var state: ConnectivityState

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            Image(systemName: systemName)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 24, height: 24)
            Circle()
                .fill(state.color)
                .frame(width: 7, height: 7)
                .overlay(Circle().stroke(Color(nsColor: .windowBackgroundColor), lineWidth: 1))
        }
    }
}

struct EmptyQueueState: View {
    var isTargeted: Bool

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: isTargeted ? "arrow.down.doc" : "waveform.badge.plus")
                .font(.system(size: 40, weight: .regular))
                .foregroundStyle(isTargeted ? Color.accentColor : Color.secondary)
            Text(isTargeted ? "Drop to add audio" : "Drop an audio file")
                .font(.title3.weight(.semibold))
            Text("The queue is the workspace. New recordings from watch folders appear here when the app starts.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)
        }
        .padding(40)
    }
}

struct QueueRow: View {
    var item: ImportItem
    var policy: WorkflowPolicy
    var action: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            StatusGlyph(status: item.status)
                .padding(.top, 2)

            VStack(alignment: .leading, spacing: 5) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(item.status.label)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(statusColor)
                    Text(item.displayTitle)
                        .font(.headline)
                        .lineLimit(1)
                }

                Text("-> \(generatedFilename)")
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)

                if let summary = item.analysis?.summary, !summary.isEmpty {
                    Text(summary)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                } else {
                    Text(placeholder)
                        .font(.subheadline)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }

                Text("\(policy.name) · \(plan)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 16)

            primaryActionButton
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private var primaryActionButton: some View {
        if let actionTitle = item.primaryActionTitle {
            if item.status == .readyForReview {
                Button(actionTitle) {
                    action()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .padding(.top, 2)
            } else {
                Button(actionTitle) {
                    action()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .padding(.top, 2)
            }
        }
    }

    private var generatedFilename: String {
        if item.analysis == nil {
            return "New filename pending"
        }
        return FilenamePattern.render(pattern: policy.filenamePattern, item: item, workflowName: policy.name)
    }

    private var placeholder: String {
        switch item.status {
        case .queued, .transcribing, .analyzing:
            "Processing transcript and routing details."
        case .new:
            "Ready to process when you choose Try Again or open the item."
        case .failed, .needsAttention:
            item.error?.message ?? "This item needs attention."
        default:
            "Summary pending."
        }
    }

    private var plan: String {
        let transcript: String
        switch policy.transcriptBehavior {
        case .appendToMonthlyNote: transcript = "appends monthly note"
        case .createMarkdownFile: transcript = "creates markdown"
        case .saveTranscriptOnly: transcript = "saves transcript"
        case .doNotExportTranscript: transcript = "no transcript export"
        }

        let audio: String
        switch policy.audioBehavior {
        case .copyAudioToDestination: audio = "copies audio"
        case .moveAudioToDestination: audio = "moves audio"
        case .doNotExportAudio: audio = "no audio export"
        case .linkExistingAudio: audio = "links audio"
        }
        return "\(audio) · \(transcript)"
    }

    private var statusColor: Color {
        switch item.status {
        case .readyForReview: .accentColor
        case .imported: .green
        case .failed, .needsAttention: .red
        case .transcribing, .analyzing, .importing, .queued: .orange
        default: .secondary
        }
    }
}

struct StatusGlyph: View {
    var status: ImportStatus

    var body: some View {
        Image(systemName: icon)
            .font(.system(size: 16, weight: .semibold))
            .foregroundStyle(color)
            .frame(width: 24, height: 24)
    }

    private var icon: String {
        switch status {
        case .new, .queued: "clock"
        case .transcribing, .transcribed, .analyzing, .importing: "arrow.triangle.2.circlepath"
        case .readyForReview: "checkmark.circle"
        case .imported: "checkmark.circle.fill"
        case .failed, .needsAttention: "exclamationmark.triangle.fill"
        }
    }

    private var color: Color {
        switch status {
        case .readyForReview: .accentColor
        case .imported: .green
        case .failed, .needsAttention: .red
        case .transcribing, .transcribed, .analyzing, .importing, .queued: .orange
        case .new: .secondary
        }
    }
}
