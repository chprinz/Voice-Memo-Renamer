import SwiftUI
import UniformTypeIdentifiers

enum QueueViewMode: String, CaseIterable, Identifiable {
    case current
    case history

    var id: String { rawValue }

    var label: String {
        switch self {
        case .current: "Current"
        case .history: "History"
        }
    }
}

enum CurrentStatusFilter {
    case all
    case needsAction
    case needsAttention

    var statuses: Set<ImportStatus> {
        switch self {
        case .all:
            return []
        case .needsAction:
            return [.readyForReview]
        case .needsAttention:
            return [.needsAttention, .failed]
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

    var isAvailable: Bool {
        if case .ok = self { return true }
        return false
    }
}

struct ContentView: View {
    @EnvironmentObject private var store: ImportStore
    @State private var mode: QueueViewMode = .current
    @State private var inspectedItemID: ImportItem.ID?
    @State private var showingSettings = false
    @State private var showingClearConfirmation = false
    @State private var pendingClearMode: QueueViewMode?
    @State private var pendingClearStatusFilter: CurrentStatusFilter = .all
    @State private var currentStatusFilter: CurrentStatusFilter = .all
    @State private var isTargeted = false
    @State private var macWhisperState: ConnectivityState = .unknown
    @State private var lmStudioState: ConnectivityState = .unknown

    var body: some View {
        VStack(spacing: 0) {
            header
            if store.items.isEmpty {
                Spacer(minLength: 28)
                importDropZone
                Spacer(minLength: 80)
            } else {
                importDropZone
                listToolbar
                Divider()
                queue
            }
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
        .confirmationDialog(clearDialogTitle, isPresented: $showingClearConfirmation, titleVisibility: .visible) {
            Button(clearDialogButtonTitle, role: .destructive) {
                performPendingClear()
            }
            Button("Cancel", role: .cancel) {
                pendingClearMode = nil
                pendingClearStatusFilter = .all
            }
        } message: {
            Text(clearDialogMessage)
        }
        .task(id: connectivityRefreshKey) {
            await refreshConnectivityLoop()
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Text("Voice Memo Renamer")
                .font(.headline)

            Spacer()

            ServiceStatusIndicator(label: "MW", state: macWhisperState, isActive: isMacWhisperActive)
                .help("MacWhisper CLI: \(macWhisperState.tooltip)")
            ServiceStatusIndicator(label: "LM", state: lmStudioState, isActive: isLMStudioActive)
                .help("LM Studio: \(lmStudioState.tooltip)")

            Button {
                showingSettings = true
            } label: {
                Label("Settings", systemImage: "gearshape")
            }
            .buttonStyle(.bordered)
            .keyboardShortcut(",", modifiers: .command)
            .help("Settings")
        }
        .padding(.horizontal, 20)
        .padding(.top, 16)
        .padding(.bottom, 12)
    }

    private var importDropZone: some View {
        HStack(alignment: .center, spacing: 18) {
            ZStack {
                Circle()
                    .fill(isTargeted ? Color.accentColor.opacity(0.16) : Color.accentColor.opacity(0.10))
                    .frame(width: store.items.isEmpty ? 64 : 52, height: store.items.isEmpty ? 64 : 52)
                Image(systemName: isTargeted ? "arrow.down.doc.fill" : "waveform.badge.plus")
                    .font(.system(size: store.items.isEmpty ? 28 : 24, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
            }

            VStack(alignment: .leading, spacing: 10) {
                Text(isTargeted ? "Drop to add audio" : "Drop audio here")
                    .font(.title3.weight(.semibold))

                HStack(alignment: .center, spacing: 8) {
                    Button {
                        chooseAudioFiles()
                    } label: {
                        Label("or Choose Audio", systemImage: "plus")
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)

                    Image(systemName: "arrow.right")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.tertiary)
                        .frame(width: 18, height: 30)
                        .padding(.leading, 3)
                        .padding(.trailing, 1)

                    Picker("Manual workflow", selection: defaultWorkflowBinding) {
                        ForEach(store.settings.workflows.filter(\.isEnabled)) { workflow in
                            Text(workflow.name).tag(workflow.id)
                        }
                    }
                    .labelsHidden()
                    .controlSize(.large)
                    .frame(width: 268, height: 30)
                }
            }

            Spacer(minLength: 20)
        }
        .padding(18)
        .frame(maxWidth: .infinity, minHeight: store.items.isEmpty ? 168 : 104)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
        .overlay {
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(isTargeted ? Color.accentColor : Color(nsColor: .separatorColor), lineWidth: isTargeted ? 2 : 1)
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 14)
    }

    private var listToolbar: some View {
        HStack(alignment: .bottom, spacing: 14) {
            QueueModeTabs(selection: modeSelection)

            if needsActionCount > 0 {
                Button {
                    mode = .current
                    toggleStatusFilter(.needsAction)
                } label: {
                    Label("\(needsActionCount) need action", systemImage: "exclamationmark.circle.fill")
                        .font(.caption.weight(.medium))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.orange)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(Color.orange.opacity(currentStatusFilter == .needsAction ? 0.16 : 0), in: RoundedRectangle(cornerRadius: 6))
                .padding(.bottom, 5)
                .help(currentStatusFilter == .needsAction ? "Show all current items" : "Show only items that need action")
            }

            if needsAttentionCount > 0 {
                Button {
                    mode = .current
                    toggleStatusFilter(.needsAttention)
                } label: {
                    Label("\(needsAttentionCount) need attention", systemImage: "exclamationmark.triangle.fill")
                        .font(.caption.weight(.medium))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.red)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(Color.red.opacity(currentStatusFilter == .needsAttention ? 0.14 : 0), in: RoundedRectangle(cornerRadius: 6))
                .padding(.bottom, 5)
                .help(currentStatusFilter == .needsAttention ? "Show all current items" : "Show only items that need attention")
            }

            Spacer()

            if store.hasActiveProcessing {
                Button {
                    store.cancelActiveProcessing()
                } label: {
                    Label("Cancel Active", systemImage: "xmark.circle")
                }
                .controlSize(.small)
            }

            toolbarMenu

        }
        .padding(.horizontal, 20)
        .padding(.top, 2)
    }

    @ViewBuilder
    private var toolbarMenu: some View {
        if let clearAction {
            Menu {
                Button(role: .destructive) {
                    requestClearView(clearAction.mode, statusFilter: clearAction.statusFilter)
                } label: {
                    Label(clearAction.title, systemImage: "trash")
                }
                .keyboardShortcut("k", modifiers: .command)
            } label: {
                Image(systemName: "ellipsis.circle")
                    .font(.system(size: 15, weight: .medium))
                    .frame(width: 24, height: 24)
            }
            .menuIndicator(.hidden)
            .help("More actions")
            .padding(.bottom, 7)
        }
    }

    private var queue: some View {
        Group {
            if visibleItems.isEmpty {
                EmptyQueueState(
                    mode: mode,
                    hasAnyItems: !store.items.isEmpty,
                    historyCount: historyItems.count,
                    showHistory: { mode = .history }
                )
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollViewReader { proxy in
                    List(visibleItems) { item in
                        QueueRow(
                            item: item,
                            policy: store.workflowPolicy(for: item.workflow),
                            action: { handlePrimaryAction(item) },
                            remove: { removeItem(item) }
                        )
                        .id(item.id)
                        .contentShape(Rectangle())
                        .onTapGesture {
                            inspectedItemID = item.id
                        }
                        .listRowInsets(EdgeInsets(top: 8, leading: 20, bottom: 8, trailing: 20))
                    }
                    .listStyle(.inset)
                    .scrollContentBackground(.hidden)
                    .onChange(of: visibleItems.first?.id) { id in
                        guard let id else { return }
                        withAnimation(.easeOut(duration: 0.18)) {
                            proxy.scrollTo(id, anchor: .top)
                        }
                    }
                }
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

    private var modeSelection: Binding<QueueViewMode> {
        Binding {
            mode
        } set: { newMode in
            mode = newMode
            currentStatusFilter = .all
        }
    }

    private var visibleItems: [ImportItem] {
        store.items.filter { item in
            switch mode {
            case .current:
                item.status != .imported
                    && (currentStatusFilter == .all || currentStatusFilter.statuses.contains(item.status))
            case .history:
                item.status == .imported
            }
        }
    }

    private var currentItems: [ImportItem] {
        store.items.filter { $0.status != .imported }
    }

    private var historyItems: [ImportItem] {
        store.items.filter { $0.status == .imported }
    }

    private var needsActionCount: Int {
        currentItems.filter { CurrentStatusFilter.needsAction.statuses.contains($0.status) }.count
    }

    private var needsAttentionCount: Int {
        currentItems.filter { CurrentStatusFilter.needsAttention.statuses.contains($0.status) }.count
    }

    private var isNeedsActionFilterActive: Bool {
        mode == .current && currentStatusFilter != .all
    }

    private var clearAction: (mode: QueueViewMode, title: String, statusFilter: CurrentStatusFilter)? {
        guard !visibleItems.isEmpty else { return nil }
        switch mode {
        case .current:
            if isNeedsActionFilterActive {
                return (QueueViewMode.current, currentStatusFilter == .needsAttention ? "Clear Needs Attention..." : "Clear Needs Action...", currentStatusFilter)
            }
            return (QueueViewMode.current, "Clear Current...", .all)
        case .history:
            return (QueueViewMode.history, "Clear History", .all)
        }
    }

    private var clearDialogTitle: String {
        return "\(clearDialogButtonTitle)?"
    }

    private var clearDialogButtonTitle: String {
        switch pendingClearMode ?? .current {
        case .current:
            switch pendingClearStatusFilter {
            case .all: "Clear Current"
            case .needsAction: "Clear Needs Action"
            case .needsAttention: "Clear Needs Attention"
            }
        case .history: "Clear History"
        }
    }

    private var clearDialogMessage: String {
        let count = clearCount(for: pendingClearMode ?? .current)
        let noun = count == 1 ? "item" : "items"
        switch pendingClearMode ?? .current {
        case .current:
            if pendingClearStatusFilter != .all {
                return "This removes \(count) visible \(noun) waiting for review or fixes. Source and exported files are not deleted."
            }
            return "This cancels active processing and removes \(count) current \(noun) from the list. Source files are not deleted."
        case .history:
            return "This removes \(count) imported \(noun) from history. Source and exported files are not deleted."
        }
    }

    private func requestClearView(_ mode: QueueViewMode, statusFilter: CurrentStatusFilter) {
        pendingClearMode = mode
        pendingClearStatusFilter = statusFilter
        switch mode {
        case .current:
            showingClearConfirmation = true
        case .history:
            performPendingClear()
        }
    }

    private func performPendingClear() {
        let mode = pendingClearMode ?? .current
        switch mode {
        case .current:
            if pendingClearStatusFilter != .all {
                let statuses = pendingClearStatusFilter.statuses
                store.clearItems { statuses.contains($0.status) }
            } else {
                store.clearItems { $0.status != .imported }
            }
        case .history:
            store.clearItems { $0.status == .imported }
        }
        pendingClearMode = nil
        pendingClearStatusFilter = .all
        currentStatusFilter = .all
    }

    private func removeItem(_ item: ImportItem) {
        store.clearItems { $0.id == item.id }
        if inspectedItemID == item.id {
            inspectedItemID = nil
        }
    }

    private func clearCount(for mode: QueueViewMode) -> Int {
        switch mode {
        case .current:
            if pendingClearStatusFilter != .all {
                return visibleItems.count
            }
            return currentItems.count
        case .history:
            return historyItems.count
        }
    }

    private func toggleStatusFilter(_ filter: CurrentStatusFilter) {
        currentStatusFilter = currentStatusFilter == filter ? .all : filter
    }

    private func modeLabel(for mode: QueueViewMode) -> String {
        switch mode {
        case .current:
            return "Current"
        case .history:
            return "History"
        }
    }

    private var supportedTypes: [UTType] {
        [.fileURL, .audio, .mpeg4Audio, .mp3, .wav, .aiff, .mpeg4Movie, .quickTimeMovie]
    }

    private var connectivityRefreshKey: String {
        "\(store.settings.macWhisperPath)|\(store.settings.lmStudioBaseURL)"
    }

    private var isMacWhisperActive: Bool {
        store.items.contains { $0.status == .transcribing }
    }

    private var isLMStudioActive: Bool {
        store.items.contains { $0.status == .analyzing }
    }

    private func refreshConnectivityLoop() async {
        while !Task.isCancelled {
            await refreshConnectivity()
            try? await Task.sleep(nanoseconds: 5_000_000_000)
        }
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
            await MainActor.run { lmStudioState = .unavailable("Invalid LM Studio URL") }
            return
        }
        do {
            let requestURL = baseURL.appendingPathComponent("models")
            var request = URLRequest(url: requestURL)
            request.cachePolicy = .reloadIgnoringLocalCacheData
            request.timeoutInterval = 2
            let (_, response) = try await URLSession.shared.data(for: request)
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
        mode = .current
        currentStatusFilter = .all
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
            let fallbackExtension = temporaryURL.pathExtension.isEmpty ? "m4a" : temporaryURL.pathExtension
            let filename = FileNaming.filename(
                preferredName: provider.suggestedName,
                fallbackBase: temporaryURL.deletingPathExtension().lastPathComponent,
                fallbackExtension: fallbackExtension
            )
            let destinationURL = FileNaming.uniqueURL(in: AppPaths.dropImportDirectory, filename: filename)
            do {
                try FileManager.default.createDirectory(at: AppPaths.dropImportDirectory, withIntermediateDirectories: true)
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
                mode = .current
                currentStatusFilter = .all
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
                mode = .current
                currentStatusFilter = .all
                for url in panel.urls {
                    if let imported = await store.addItem(from: url) {
                        ImportProcessor(store: store).process(imported.id)
                    }
                }
            }
        }
    }
}

struct ServiceStatusIndicator: View {
    var label: String
    var state: ConnectivityState
    var isActive: Bool
    @State private var pulse = false

    var body: some View {
        VStack(spacing: 2) {
            ZStack(alignment: .topTrailing) {
                Text(label)
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .foregroundStyle(.primary)
                    .frame(width: 28, height: 20)
                    .background(.quaternary, in: RoundedRectangle(cornerRadius: 5))
                Circle()
                    .fill(state.color)
                    .frame(width: 7, height: 7)
                    .overlay(Circle().stroke(Color(nsColor: .windowBackgroundColor), lineWidth: 1))
                    .offset(x: 2, y: -2)
            }

            Capsule()
                .fill(activityColor)
                .frame(width: 18, height: 3)
                .opacity(activityOpacity)
                .shadow(color: activityColor.opacity(isActive ? 0.6 : 0), radius: isActive ? 3 : 0)
        }
        .frame(width: 30, height: 26)
        .animation(.easeInOut(duration: 0.25), value: state.color)
        .onAppear { updatePulse() }
        .onChange(of: isActive) { _ in updatePulse() }
    }

    private var activityColor: Color {
        guard state.isAvailable else { return state.color }
        return isActive ? .green : .secondary
    }

    private var activityOpacity: Double {
        guard state.isAvailable else { return 0.75 }
        return isActive ? (pulse ? 1 : 0.25) : 0.35
    }

    private func updatePulse() {
        if isActive {
            withAnimation(.easeInOut(duration: 0.35).repeatForever(autoreverses: true)) {
                pulse = true
            }
        } else {
            withAnimation(.easeOut(duration: 0.2)) {
                pulse = false
            }
        }
    }
}

struct EmptyQueueState: View {
    var mode: QueueViewMode
    var hasAnyItems: Bool
    var historyCount: Int
    var showHistory: () -> Void

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: icon)
                .font(.system(size: 34, weight: .regular))
                .foregroundStyle(Color.secondary)
            Text(title)
                .font(.title3.weight(.semibold))
            Text(message)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)
            if shouldShowHistoryButton {
                Button {
                    showHistory()
                } label: {
                    Label("Show History", systemImage: "clock.arrow.circlepath")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        }
        .padding(40)
    }

    private var icon: String {
        switch mode {
        case .current:
            return hasAnyItems ? "tray" : "arrow.up.doc"
        case .history:
            return "clock.arrow.circlepath"
        }
    }

    private var title: String {
        switch mode {
        case .current:
            return hasAnyItems ? "No current imports" : "Ready for audio"
        case .history:
            return "No history yet"
        }
    }

    private var message: String {
        switch mode {
        case .current:
            if historyCount > 0 {
                return "\(historyCount) imported \(historyCount == 1 ? "recording is" : "recordings are") in History."
            }
            return hasAnyItems
                ? "Imported recordings move to History."
                : "Use the drop zone above or choose audio files to start."
        case .history:
            return "Imported recordings collect here after they leave Current."
        }
    }

    private var shouldShowHistoryButton: Bool {
        mode == .current && historyCount > 0
    }
}

struct QueueModeTabs: View {
    @Binding var selection: QueueViewMode

    var body: some View {
        HStack(spacing: 20) {
            ForEach(QueueViewMode.allCases) { mode in
                Button {
                    selection = mode
                } label: {
                    VStack(spacing: 8) {
                        Text(mode.label)
                            .font(.subheadline.weight(selection == mode ? .semibold : .medium))
                            .foregroundStyle(selection == mode ? .primary : .secondary)
                        Capsule()
                            .fill(selection == mode ? Color.accentColor : Color.clear)
                            .frame(width: 28, height: 2)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .accessibilityLabel("List")
    }
}

struct QueueRow: View {
    var item: ImportItem
    var policy: WorkflowPolicy
    var action: () -> Void
    var remove: () -> Void
    @State private var isHovering = false

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

                HStack(spacing: 6) {
                    MetadataTag(text: policy.name)
                    MetadataTag(text: plan)
                }
                .padding(.top, 2)
            }

            Spacer(minLength: 16)

            primaryActionButton
            removeButton
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 6)
        .background(Color.primary.opacity(isHovering ? 0.045 : 0), in: RoundedRectangle(cornerRadius: 6))
        .onHover { isHovering = $0 }
        .animation(.easeOut(duration: 0.12), value: isHovering)
    }

    private var removeButton: some View {
        Button(role: .destructive) {
            remove()
        } label: {
            Image(systemName: "xmark.circle.fill")
                .symbolRenderingMode(.hierarchical)
                .font(.system(size: 15, weight: .semibold))
                .frame(width: 24, height: 24)
        }
        .buttonStyle(.borderless)
        .foregroundStyle(.secondary)
        .padding(.top, 0)
        .help("Remove from list")
        .opacity(isHovering ? 1 : 0)
        .allowsHitTesting(isHovering)
        .animation(.easeOut(duration: 0.12), value: isHovering)
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
        switch policy.audioFileBehavior {
        case .copyToFolder: audio = "copies audio"
        case .moveToFolder: audio = "moves audio"
        case .renameInPlace: audio = "renames audio"
        case .leaveInPlace: audio = "leaves audio"
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

struct MetadataTag: View {
    var text: String

    var body: some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(Color(nsColor: .quaternaryLabelColor).opacity(0.18), in: RoundedRectangle(cornerRadius: 5))
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
