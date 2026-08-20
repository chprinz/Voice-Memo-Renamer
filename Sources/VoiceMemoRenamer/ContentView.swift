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

/// A lens on one list rather than a separate mode. "Needs you" is the only state
/// that actually waits for a person; "Failed" is everything that stopped.
enum QueueFilter: String, CaseIterable, Identifiable {
    case all
    case needsYou
    case failed

    var id: String { rawValue }

    var label: String {
        switch self {
        case .all: "All"
        case .needsYou: "Needs you"
        case .failed: "Failed"
        }
    }

    var statuses: Set<ImportStatus> {
        switch self {
        case .all: []
        case .needsYou: [.readyForReview]
        case .failed: [.needsAttention, .failed]
        }
    }
}

enum ConnectivityState {
    case ok
    case idle(String)
    case unknown
    case unavailable(String)

    var color: Color {
        switch self {
        case .ok: .green
        case .idle: .yellow
        case .unknown: .secondary
        case .unavailable: .red
        }
    }

    var summary: String {
        switch self {
        case .ok: "Connected"
        case .idle: "No model loaded"
        case .unknown: "Not checked yet"
        case .unavailable: "No connection"
        }
    }

    var detail: String? {
        switch self {
        case .idle(let message): message
        case .unavailable(let message): message
        default: nil
        }
    }

    var isAvailable: Bool {
        switch self {
        case .ok, .idle: true
        default: false
        }
    }
}

struct ContentView: View {
    @EnvironmentObject private var store: ImportStore
    @State private var mode: QueueViewMode = .current
    @State private var selectedItemID: ImportItem.ID?
    @State private var showingSettings = false
    @State private var showingClearConfirmation = false
    @State private var pendingClearMode: QueueViewMode?
    @State private var pendingClearFilter: QueueFilter = .all
    @State private var filter: QueueFilter = .all
    @State private var searchText = ""
    @State private var sessionWorkflow = ""
    @State private var isTargeted = false
    @State private var macWhisperState: ConnectivityState = .unknown
    @State private var lmStudioState: ConnectivityState = .unknown

    var body: some View {
        VStack(spacing: 0) {
            serviceBanner
            importNotices
            importDropZone
            Divider()
            HStack(spacing: 0) {
                sidebar
                    .frame(width: 316)
                Divider()
                detailPane
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            Divider()
            statusFooter
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                ServiceBadge(
                    name: "MacWhisper",
                    role: "transcribes recordings",
                    state: macWhisperState,
                    isActive: isMacWhisperActive
                )
                ServiceBadge(
                    name: "LM Studio",
                    role: "writes titles and summaries",
                    state: lmStudioState,
                    isActive: isLMStudioActive
                )
                Button {
                    showingSettings = true
                } label: {
                    Label("Settings", systemImage: "gearshape")
                }
                .keyboardShortcut(",", modifiers: .command)
                .help("Settings")
            }
        }
        .onDrop(of: supportedTypes, isTargeted: $isTargeted) { providers in
            handleDrop(providers)
        }
        .overlay {
            if isTargeted {
                RoundedRectangle(cornerRadius: 0)
                    .strokeBorder(Color.accentColor, lineWidth: 3)
                    .background(Color.accentColor.opacity(0.06))
                    .allowsHitTesting(false)
            }
        }
        .sheet(isPresented: $showingSettings) {
            SettingsView()
                .environmentObject(store)
                .frame(minWidth: 720, idealWidth: 780, minHeight: 620, idealHeight: 740)
        }
        .confirmationDialog(clearDialogTitle, isPresented: $showingClearConfirmation, titleVisibility: .visible) {
            Button(clearDialogButtonTitle, role: .destructive) {
                performPendingClear()
            }
            Button("Cancel", role: .cancel) {
                pendingClearMode = nil
                pendingClearFilter = .all
            }
        } message: {
            Text(clearDialogMessage)
        }
        .onExitCommand { selectedItemID = nil }
        .onAppear(perform: adoptDefaultWorkflow)
        .task(id: connectivityRefreshKey) {
            await refreshConnectivityLoop()
        }
    }

    // MARK: - Top bar

    /// A single row: the audio you add on the left, and on the right the workflow
    /// with the destinations it implies. Keeping the destinations beside the picker
    /// rather than below it ties them to the control that changes them, and holds
    /// the bar to one line.
    private var importDropZone: some View {
        HStack(spacing: Space.xl) {
            HStack(spacing: Space.m) {
                Button {
                    chooseAudioFiles()
                } label: {
                    Label("Add Audio", systemImage: "plus")
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)

                Text(isTargeted ? "Drop to add" : "or drop audio anywhere in this window")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Divider()
                .frame(height: 36)

            HStack(spacing: Space.xl) {
                HStack(spacing: Space.s) {
                    Text("Workflow:")
                        .foregroundStyle(.secondary)

                    Picker("Workflow", selection: $sessionWorkflow) {
                        ForEach(enabledWorkflows) { workflow in
                            Text(workflow.name).tag(workflow.id)
                        }
                    }
                    .labelsHidden()
                    .controlSize(.large)
                    .frame(minWidth: 180, maxWidth: 240, alignment: .leading)
                    .help("Applies to audio you add here. The watch folder keeps the default set in Settings.")
                }
                .layoutPriority(1)

                destinationSummary
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, Space.l)
        .padding(.horizontal, Space.xxl)
        .frame(maxWidth: .infinity)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
        .overlay {
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(isTargeted ? Color.accentColor : Color(nsColor: .separatorColor), lineWidth: isTargeted ? 2 : 1)
        }
        .padding(.horizontal, Space.xl)
        .padding(.top, Space.l)
        .padding(.bottom, Space.m)
    }

    /// Label and value in two aligned columns. Read-only: these paths belong to the
    /// workflow, and the workflow is edited in Settings.
    private var destinationSummary: some View {
        Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: Space.m, verticalSpacing: Space.xs) {
            ForEach(destinationRows, id: \.label) { row in
                GridRow {
                    Text(row.label)
                        .foregroundStyle(.secondary)
                        .gridColumnAlignment(.leading)
                    Text(row.value)
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
        }
        .font(.caption)
    }

    // MARK: - Sidebar

    private var sidebar: some View {
        VStack(spacing: 0) {
            HStack(alignment: .bottom, spacing: Space.xl) {
                QueueModeTabs(selection: modeSelection)
                Spacer()
                sidebarCountLabel
            }
            .padding(.horizontal, Space.l)
            .padding(.top, Space.s)

            SearchField(text: $searchText)
                .padding(.horizontal, Space.l)
                .padding(.top, Space.s)
                .padding(.bottom, Space.s)

            if mode == .current && (needsYouCount > 0 || failedCount > 0) {
                Picker("Filter", selection: $filter) {
                    ForEach(QueueFilter.allCases) { option in
                        Text(filterLabel(option)).tag(option)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .controlSize(.small)
                .padding(.horizontal, Space.l)
                .padding(.bottom, Space.s)
            }

            Divider()

            if visibleItems.isEmpty {
                EmptyQueueState(
                    mode: mode,
                    isSearching: !searchText.isEmpty,
                    historyCount: historyItems.count,
                    showHistory: { mode = .history; filter = .all }
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(selection: $selectedItemID) {
                    ForEach(dayGroups) { group in
                        Section(group.title) {
                            ForEach(group.items) { item in
                                QueueRow(item: item, policy: store.workflowPolicy(for: item.workflow))
                                    .tag(item.id)
                                    .listRowInsets(EdgeInsets(top: Space.s, leading: Space.m, bottom: Space.s, trailing: Space.m))
                                    .contextMenu {
                                        Button("Remove from List", role: .destructive) {
                                            removeItem(item)
                                        }
                                    }
                            }
                        }
                    }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
            }

            Divider()
            HStack(spacing: Space.s) {
                if store.hasActiveProcessing {
                    Button {
                        store.cancelActiveProcessing()
                    } label: {
                        Label("Cancel", systemImage: "xmark.circle")
                    }
                    .controlSize(.small)
                }
                Spacer()
                if let clearAction {
                    Menu {
                        Button(role: .destructive) {
                            requestClear(clearAction.mode, filter: clearAction.filter)
                        } label: {
                            Label(clearAction.title, systemImage: "trash")
                        }
                        .keyboardShortcut("k", modifiers: .command)
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                    .menuIndicator(.hidden)
                    .frame(width: 28)
                    .help("More actions")
                }
            }
            .padding(.horizontal, Space.m)
            .padding(.vertical, Space.s)
        }
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.5))
    }

    @ViewBuilder
    private var sidebarCountLabel: some View {
        if !searchText.isEmpty {
            Text("\(visibleItems.count) of \(modeItems.count)")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .padding(.bottom, 3)
        } else if mode == .history {
            Text("\(historyItems.count)")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .padding(.bottom, 3)
        }
    }

    // MARK: - Detail

    @ViewBuilder
    private var detailPane: some View {
        if let item = selectedItem {
            ImportDetailPane(item: item) {
                selectedItemID = nil
            }
            .environmentObject(store)
        } else {
            EmptyDetailState(hasItems: !store.items.isEmpty)
        }
    }

    // MARK: - Footer

    /// Where the app is watching is a property of the window, not of whatever is
    /// selected, so it sits in one fixed place and stays there.
    private var statusFooter: some View {
        HStack(spacing: 7) {
            Circle()
                .fill(activeWatchFolders.isEmpty ? Color(nsColor: .tertiaryLabelColor) : Color.green)
                .frame(width: 6, height: 6)
            if activeWatchFolders.isEmpty {
                Text("No watch folder")
                    .foregroundStyle(.secondary)
            } else {
                Text("Watching")
                    .foregroundStyle(.secondary)
                Text(activeWatchFolders.joined(separator: ", "))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer()
        }
        .font(.caption)
        .padding(.horizontal, Space.l)
        .padding(.vertical, 6)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.5))
    }

    // MARK: - Banners

    @ViewBuilder
    private var serviceBanner: some View {
        if let message = serviceBannerMessage {
            HStack(alignment: .top, spacing: Space.m) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
                VStack(alignment: .leading, spacing: 2) {
                    Text(message.title)
                        .font(.subheadline.weight(.semibold))
                    Text(message.consequence)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Settings") { showingSettings = true }
                    .controlSize(.small)
            }
            .padding(.horizontal, Space.xl)
            .padding(.vertical, Space.m)
            .background(Color.red.opacity(0.08))
            .overlay(alignment: .bottom) { Divider() }
        }
    }

    @ViewBuilder
    private var importNotices: some View {
        if !store.importNotices.isEmpty {
            VStack(alignment: .leading, spacing: Space.s) {
                ForEach(store.importNotices) { notice in
                    HStack(alignment: .firstTextBaseline, spacing: Space.s) {
                        Image(systemName: notice.kind == .duplicate ? "doc.on.doc" : "exclamationmark.triangle")
                            .foregroundStyle(.orange)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Not added: \(notice.filename)")
                                .font(.caption.weight(.medium))
                            Text(notice.message)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        if notice.kind == .duplicate {
                            Button("Add Anyway") {
                                importAudioFile(notice.url, allowDuplicate: true)
                                store.dismissImportNotice(notice.id)
                            }
                            .controlSize(.small)
                        }
                        Button {
                            store.dismissImportNotice(notice.id)
                        } label: {
                            Image(systemName: "xmark")
                        }
                        .buttonStyle(.borderless)
                        .help("Dismiss")
                    }
                    .padding(.horizontal, Space.m)
                    .padding(.vertical, Space.s)
                    .background(Color.orange.opacity(0.10), in: RoundedRectangle(cornerRadius: 6))
                }
            }
            .padding(.horizontal, Space.xl)
            .padding(.top, Space.m)
        }
    }

    // MARK: - Derived state

    private var enabledWorkflows: [WorkflowPolicy] {
        let enabled = store.settings.workflows.filter(\.isEnabled)
        return enabled.isEmpty ? store.settings.workflows : enabled
    }

    private var activeWorkflowPolicy: WorkflowPolicy {
        store.workflowPolicy(for: sessionWorkflow.isEmpty ? store.settings.defaultWorkflow : sessionWorkflow)
    }

    private var destinationRows: [(label: String, value: String)] {
        WorkflowSummary.destinations(for: activeWorkflowPolicy)
    }

    private var activeWatchFolders: [String] {
        store.settings.workflows
            .filter { $0.isEnabled && $0.sourceBehavior.usesWatchFolder && !$0.watchFolderPath.isEmpty }
            .map { PathDisplay.short($0.watchFolderPath, components: 2) }
    }

    /// A selection only survives while the recording it points at is actually in the
    /// list on the left. Switching to History, filtering, or searching it away
    /// therefore clears the panel instead of stranding a recording you can no
    /// longer see next to a list that no longer contains it.
    private var selectedItem: ImportItem? {
        guard let selectedItemID, let item = store.item(id: selectedItemID) else { return nil }
        return visibleItems.contains { $0.id == item.id } ? item : nil
    }

    private var modeSelection: Binding<QueueViewMode> {
        Binding {
            mode
        } set: { newMode in
            mode = newMode
            filter = .all
            selectedItemID = nil
        }
    }

    private var modeItems: [ImportItem] {
        switch mode {
        case .current: currentItems
        case .history: historyItems
        }
    }

    /// Statuses that mean "actively working on it" stay visible under every filter tab,
    /// so a recording never vanishes from the list mid-transcription only to reappear
    /// (or not) once it lands on a terminal status.
    private static let inFlightStatuses: Set<ImportStatus> = [
        .new, .queued, .transcribing, .transcribed, .analyzing, .importing,
    ]

    private var visibleItems: [ImportItem] {
        modeItems.filter { item in
            let matchesFilter = mode == .history
                || filter == .all
                || Self.inFlightStatuses.contains(item.status)
                || filter.statuses.contains(item.status)
            return matchesFilter && matchesSearch(item)
        }
    }

    private var dayGroups: [DayGrouping.Group] {
        DayGrouping.groups(for: visibleItems)
    }

    private var currentItems: [ImportItem] {
        store.items.filter { $0.status != .imported }
    }

    private var historyItems: [ImportItem] {
        store.items.filter { $0.status == .imported }
    }

    private var needsYouCount: Int {
        currentItems.filter { QueueFilter.needsYou.statuses.contains($0.status) }.count
    }

    private var failedCount: Int {
        currentItems.filter { QueueFilter.failed.statuses.contains($0.status) }.count
    }

    private func filterLabel(_ option: QueueFilter) -> String {
        switch option {
        case .all: "All"
        case .needsYou: needsYouCount > 0 ? "Needs you (\(needsYouCount))" : "Needs you"
        case .failed: failedCount > 0 ? "Failed (\(failedCount))" : "Failed"
        }
    }

    private func matchesSearch(_ item: ImportItem) -> Bool {
        guard !searchText.isEmpty else { return true }
        let needle = searchText.lowercased()
        if item.displayTitle.lowercased().contains(needle) { return true }
        if item.originalFilename.lowercased().contains(needle) { return true }
        if let summary = item.analysis?.summary, summary.lowercased().contains(needle) { return true }
        if let transcript = item.transcript, transcript.lowercased().contains(needle) { return true }
        return false
    }

    private var serviceBannerMessage: (title: String, consequence: String)? {
        if case .unavailable = lmStudioState {
            return (
                "No connection to LM Studio",
                "Recordings still transcribe, then stop before the title and summary step."
            )
        }
        if case .unavailable = macWhisperState {
            return (
                "No connection to MacWhisper",
                "Recordings cannot be transcribed until this is reachable."
            )
        }
        return nil
    }

    // MARK: - Clearing

    private var clearAction: (mode: QueueViewMode, title: String, filter: QueueFilter)? {
        guard !visibleItems.isEmpty else { return nil }
        switch mode {
        case .current:
            if filter != .all {
                return (.current, "Clear \(filter.label)…", filter)
            }
            return (.current, "Clear Current…", .all)
        case .history:
            return (.history, "Clear History", .all)
        }
    }

    private var clearDialogTitle: String { "\(clearDialogButtonTitle)?" }

    private var clearDialogButtonTitle: String {
        switch pendingClearMode ?? .current {
        case .current:
            pendingClearFilter == .all ? "Clear Current" : "Clear \(pendingClearFilter.label)"
        case .history:
            "Clear History"
        }
    }

    private var clearDialogMessage: String {
        let count = clearCount(for: pendingClearMode ?? .current)
        let noun = count == 1 ? "recording" : "recordings"
        switch pendingClearMode ?? .current {
        case .current:
            if pendingClearFilter != .all {
                return "Removes \(count) visible \(noun) from the list. No files are deleted."
            }
            return "Cancels anything running and removes \(count) \(noun) from the list. No files are deleted."
        case .history:
            return "Removes \(count) imported \(noun) from History. No files are deleted."
        }
    }

    private func requestClear(_ mode: QueueViewMode, filter: QueueFilter) {
        pendingClearMode = mode
        pendingClearFilter = filter
        switch mode {
        case .current: showingClearConfirmation = true
        case .history: performPendingClear()
        }
    }

    private func performPendingClear() {
        switch pendingClearMode ?? .current {
        case .current:
            if pendingClearFilter != .all {
                let statuses = pendingClearFilter.statuses
                store.clearItems { statuses.contains($0.status) }
            } else {
                store.clearItems { $0.status != .imported }
            }
        case .history:
            store.clearItems { $0.status == .imported }
        }
        pendingClearMode = nil
        pendingClearFilter = .all
        filter = .all
    }

    private func removeItem(_ item: ImportItem) {
        store.clearItems { $0.id == item.id }
        if selectedItemID == item.id {
            selectedItemID = nil
        }
    }

    private func clearCount(for mode: QueueViewMode) -> Int {
        switch mode {
        case .current: pendingClearFilter == .all ? currentItems.count : visibleItems.count
        case .history: historyItems.count
        }
    }

    // MARK: - Services

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

    private func adoptDefaultWorkflow() {
        let known = enabledWorkflows.map(\.id)
        if sessionWorkflow.isEmpty || !known.contains(sessionWorkflow) {
            sessionWorkflow = known.contains(store.settings.defaultWorkflow)
                ? store.settings.defaultWorkflow
                : (known.first ?? store.settings.defaultWorkflow)
        }
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
            await MainActor.run { lmStudioState = .unavailable("The LM Studio address is not a valid URL.") }
            return
        }
        do {
            // The OpenAI-compatible /v1/models endpoint lists every downloaded model,
            // loaded or not, so it can't tell us whether one is actually ready. The
            // native endpoint's loaded_instances is the same signal analysis itself
            // relies on (LMStudioService.loadedModel()), so the badge agrees with it.
            let requestURL = connectivityNativeBaseURL(from: baseURL).appendingPathComponent("models")
            var request = URLRequest(url: requestURL)
            request.cachePolicy = .reloadIgnoringLocalCacheData
            request.timeoutInterval = 2
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
                await MainActor.run { lmStudioState = .unavailable("LM Studio answered, but not with a model list.") }
                return
            }
            let decoded = try? JSONDecoder().decode(LMStudioNativeModelsResponse.self, from: data)
            let hasLoadedModel = decoded?.models.contains { !$0.loadedInstances.isEmpty } ?? false
            if hasLoadedModel {
                await MainActor.run { lmStudioState = .ok }
            } else {
                await MainActor.run { lmStudioState = .idle("LM Studio is running, but no model is loaded yet.") }
            }
        } catch {
            await MainActor.run { lmStudioState = .unavailable(error.localizedDescription) }
        }
    }

    private func connectivityNativeBaseURL(from openAIBaseURL: URL) -> URL {
        if openAIBaseURL.path.hasSuffix("/v1") {
            return openAIBaseURL
                .deletingLastPathComponent()
                .appendingPathComponent("api")
                .appendingPathComponent("v1")
        }
        return openAIBaseURL
            .appendingPathComponent("api")
            .appendingPathComponent("v1")
    }

    // MARK: - Import

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        mode = .current
        filter = .all
        store.clearImportNotices()
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

    private func importAudioFile(_ url: URL, allowDuplicate: Bool = false) {
        Task { @MainActor in
            if let imported = await store.addItem(from: url, allowDuplicate: allowDuplicate, workflowOverride: sessionWorkflow) {
                mode = .current
                filter = .all
                selectedItemID = imported.id
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
        panel.allowedContentTypes = [.audio, .mpeg4Audio, .mp3, .wav, .aiff, .movie]

        if panel.runModal() == .OK {
            Task { @MainActor in
                mode = .current
                filter = .all
                store.clearImportNotices()
                for url in panel.urls {
                    if let imported = await store.addItem(from: url, workflowOverride: sessionWorkflow) {
                        selectedItemID = imported.id
                        ImportProcessor(store: store).process(imported.id)
                    }
                }
            }
        }
    }
}

/// Ambient health. Shows the service name spelled out, a dot for reachability, and
/// a pulse while that service is doing work.
struct ServiceBadge: View {
    var name: String
    var role: String
    var state: ConnectivityState
    var isActive: Bool
    @State private var pulse = false

    var body: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(state.color)
                .frame(width: 7, height: 7)
                .opacity(dotOpacity)
            Text(name)
                .font(.caption)
                .foregroundStyle(state.isAvailable ? AnyShapeStyle(.secondary) : AnyShapeStyle(Color.primary))
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .help(helpText)
        .animation(.easeInOut(duration: 0.25), value: state.color)
        .onAppear(perform: updatePulse)
        .onChange(of: isActive) { _ in updatePulse() }
    }

    private var helpText: String {
        var text = "\(name) — \(role). \(state.summary)."
        if let detail = state.detail {
            text += "\n\(detail)"
        }
        return text
    }

    private var dotOpacity: Double {
        guard state.isAvailable else { return 1 }
        return isActive ? (pulse ? 1 : 0.3) : 1
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

struct SearchField: View {
    @Binding var text: String

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.caption)
                .foregroundStyle(.secondary)
            TextField("Search title, summary, transcript", text: $text)
                .textFieldStyle(.plain)
                .font(.caption)
            if !text.isEmpty {
                Button {
                    text = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.borderless)
                .help("Clear search")
            }
        }
        .padding(.horizontal, Space.s)
        .padding(.vertical, 5)
        .background(Color(nsColor: .quaternaryLabelColor).opacity(0.22), in: RoundedRectangle(cornerRadius: 6))
    }
}

struct QueueModeTabs: View {
    @Binding var selection: QueueViewMode

    var body: some View {
        HStack(spacing: Space.xl) {
            ForEach(QueueViewMode.allCases) { mode in
                Button {
                    selection = mode
                } label: {
                    VStack(spacing: 7) {
                        Text(mode.label)
                            .font(.subheadline.weight(selection == mode ? .semibold : .medium))
                            .foregroundStyle(selection == mode ? .primary : .secondary)
                        Capsule()
                            .fill(selection == mode ? Color.accentColor : Color.clear)
                            .frame(height: 2)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(mode.label)
                .accessibilityAddTraits(selection == mode ? [.isSelected, .isButton] : .isButton)
            }
        }
    }
}

/// Slimmed to what identifies a recording in a list: state, title, resulting
/// filename, one line of summary. Workflow details live in the detail panel.
struct QueueRow: View {
    var item: ImportItem
    var policy: WorkflowPolicy

    var body: some View {
        HStack(alignment: .top, spacing: Space.s) {
            Circle()
                .fill(statusColor)
                .frame(width: 8, height: 8)
                .padding(.top, 5)

            VStack(alignment: .leading, spacing: 3) {
                Text(item.displayTitle)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)

                Text(filenameLine)
                    .font(.caption2.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)

                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(.vertical, 2)
    }

    private var filenameLine: String {
        // Prefer the exported audio: with a monthly note every imported recording
        // would otherwise show the same "2026-08.md" and identify nothing.
        if item.status == .imported {
            if let path = item.exportedAudioPath {
                return (path as NSString).lastPathComponent
            }
            if let path = item.exportedMarkdownPath,
               policy.transcriptBehavior != .appendToMonthlyNote {
                return (path as NSString).lastPathComponent
            }
        }
        guard item.analysis != nil else { return "Filename pending" }
        return FilenamePattern.render(pattern: policy.filenamePattern, item: item, workflowName: policy.name)
    }

    private var subtitle: String {
        if let summary = item.analysis?.summary, !summary.isEmpty {
            return summary
        }
        switch item.status {
        case .queued, .transcribing, .analyzing, .importing:
            return "Working on it…"
        case .new:
            return "Waiting to start."
        case .failed, .needsAttention:
            return item.error?.message ?? "Needs attention."
        default:
            return "No summary yet."
        }
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

struct EmptyQueueState: View {
    var mode: QueueViewMode
    var isSearching: Bool
    var historyCount: Int
    var showHistory: () -> Void

    var body: some View {
        VStack(spacing: Space.m) {
            Text(title)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.secondary)
            if let message {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .multilineTextAlignment(.center)
            }
            if mode == .current && !isSearching && historyCount > 0 {
                Button("Show History", action: showHistory)
                    .buttonStyle(.link)
                    .font(.caption)
            }
        }
        .padding(Space.xl)
    }

    private var title: String {
        if isSearching { return "No matches" }
        return mode == .current ? "Nothing waiting" : "No history yet"
    }

    private var message: String? {
        if isSearching { return "Try a different word." }
        switch mode {
        case .current:
            return historyCount > 0 ? "\(historyCount) imported so far." : nil
        case .history:
            return "Imported recordings collect here."
        }
    }
}

struct EmptyDetailState: View {
    var hasItems: Bool

    var body: some View {
        VStack(spacing: Space.l) {
            Image(systemName: "arrow.down.doc")
                .font(.system(size: 40, weight: .light))
                .foregroundStyle(.tertiary)
            Text(hasItems ? "Nothing selected" : "Ready for audio")
                .font(.title3.weight(.semibold))
            Text(hasItems
                 ? "Pick a recording on the left to review it."
                 : "Drop a file anywhere in this window, or use Add Audio.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)
        }
        .padding(Space.xxl)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
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

