import SwiftUI

enum SettingsTab: String, CaseIterable, Identifiable {
    case general
    case workflows
    case services

    var id: String { rawValue }

    var label: String {
        switch self {
        case .general: "General"
        case .workflows: "Workflows"
        case .services: "Services"
        }
    }
}

struct SettingsView: View {
    @EnvironmentObject private var store: ImportStore
    @Environment(\.dismiss) private var dismiss
    @State private var selectedWorkflowID: String = StandardWorkflowID.obsidianJournal
    @State private var macWhisperStatus: String = "Not checked"
    @State private var isChecking = false
    @State private var ffmpegStatus: String = "Not checked"
    @State private var isCheckingFFmpeg = false
    @State private var lmStudioModels: [String] = []
    @State private var lmStudioStatus: String = "Not checked"
    @State private var isLoadingModels = false
    @State private var loadedContextTokens: Int?
    @State private var maxContextTokens: Int?
    @State private var storageBytes: Int64?
    @State private var tab: SettingsTab = .general

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Settings")
                    .font(.title2.weight(.semibold))
                Spacer()
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.borderless)
                .help("Close Settings")
            }
            .padding(.horizontal, Space.xxl)
            .padding(.top, Space.xl)
            .padding(.bottom, Space.m)

            Picker("Section", selection: $tab) {
                ForEach(SettingsTab.allCases) { section in
                    Text(section.label).tag(section)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(maxWidth: 440)
            .padding(.horizontal, Space.xxl)
            .padding(.bottom, Space.l)

            Divider()

            ScrollView {
                Form {
                    switch tab {
                    case .general: generalSection
                    case .workflows: workflowsSection
                    case .services: servicesSection
                    }
                }
                .formStyle(.grouped)
                .frame(maxWidth: 720, alignment: .leading)
                .padding(.horizontal, Space.xl)
                .padding(.bottom, Space.xxl)
            }
        }
        .background(Color(nsColor: .textBackgroundColor))
        .onAppear {
            selectedWorkflowID = store.settings.defaultWorkflow
            checkMacWhisper()
            checkFFmpeg()
            refreshModels()
        }
    }

    private var generalSection: some View {
        Group {
            Section("Startup") {
                Picker("Default workflow", selection: $store.settings.defaultWorkflow) {
                    ForEach(store.settings.workflows.filter(\.isEnabled)) { workflow in
                        Text(workflow.name).tag(workflow.id)
                    }
                }
                .help("Used by watch folders, and preselected in the main window.")
                Toggle("Check watch folders at launch", isOn: $store.settings.checkWatchFoldersAtLaunch)
            }
        }
    }

    private var workflowsSection: some View {
        Group {
            Section {
                HStack {
                    Picker("Workflow", selection: $selectedWorkflowID) {
                        ForEach(store.settings.workflows) { workflow in
                            Text(workflow.name).tag(workflow.id)
                        }
                    }
                    Spacer()
                    Button {
                        let workflow = store.addWorkflow()
                        selectedWorkflowID = workflow.id
                    } label: {
                        Label("Add", systemImage: "plus")
                    }
                    Button {
                        store.deleteWorkflow(id: selectedWorkflowID)
                        selectedWorkflowID = store.settings.defaultWorkflow
                    } label: {
                        Label("Delete", systemImage: "trash")
                    }
                    .disabled(store.settings.workflows.count <= 1)
                }
            }

            if let binding = workflowBinding(for: selectedWorkflowID) {
                WorkflowPolicyEditor(policy: binding)
            }
        }
    }


    private var servicesSection: some View {
        Group {
            Section("Setup") {
                HStack {
                    Text("Re-detect MacWhisper, ffmpeg, and LM Studio from scratch.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Run Setup Assistant Again") {
                        dismiss()
                        store.needsSetup = true
                    }
                }
            }

            Section("Transcription") {
                TextField("MacWhisper", text: $store.settings.macWhisperPath)
                HStack {
                    Text(macWhisperStatus)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                    Spacer()
                    Button(isChecking ? "Checking\u{2026}" : "Check") { checkMacWhisper() }
                        .disabled(isChecking)
                }

                TextField("ffmpeg", text: $store.settings.ffmpegPath)
                HStack {
                    Text(ffmpegStatus)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                    Spacer()
                    Button(isCheckingFFmpeg ? "Checking\u{2026}" : "Check") { checkFFmpeg() }
                        .disabled(isCheckingFFmpeg)
                }
            }

            Section("Analysis") {
                TextField("LM Studio", text: $store.settings.lmStudioBaseURL)
                Picker("Model", selection: modelSelectionBinding) {
                    Text("First loaded model").tag("")
                    ForEach(lmStudioModels, id: \.self) { model in
                        Text(model).tag(model)
                    }
                }
                HStack {
                    Text(lmStudioStatus)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                    Spacer()
                    Button(isLoadingModels ? "Loading\u{2026}" : "Refresh") { refreshModels() }
                        .disabled(isLoadingModels)
                }

                HStack {
                    Text("Transcript limit")
                    Spacer()
                    TextField("Transcript limit", value: $store.settings.maxTranscriptCharactersForAnalysis, format: .number)
                        .labelsHidden()
                        .frame(width: 110)
                    Text("characters")
                        .foregroundStyle(.secondary)
                    if loadedContextTokens != nil {
                        Button("Safe Limit") { applySafeTranscriptLimit() }
                    }
                }
                Slider(value: transcriptLimitBinding, in: 6000...transcriptSliderUpperBound, step: 1000)
                Text(contextSummary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Cache") {
                HStack {
                    Text("Temporary copies")
                    Spacer()
                    Text(storageBytes.map(FileSizeFormatter.storageText) ?? "Measuring\u{2026}")
                        .foregroundStyle(.secondary)
                    Button("Clear") {
                        store.clearCache()
                        Task { storageBytes = await ImportStore.storageUsage() }
                    }
                    .disabled(store.hasActiveProcessing)
                    .help(store.hasActiveProcessing ? "Wait until processing finishes." : "Remove temporary copies that are no longer needed.")
                }
                .task { storageBytes = await ImportStore.storageUsage() }

                Picker("Delete", selection: storagePolicyBinding) {
                    ForEach(ProcessingStoragePolicy.allCases) { policy in
                        Text(policy.label).tag(policy)
                    }
                }
            }
        }
    }

    /// The stored policy is per-workflow, but in practice this is a machine-level
    /// preference, so setting it here writes it to every workflow at once.
    private var storagePolicyBinding: Binding<ProcessingStoragePolicy> {
        Binding {
            store.settings.processingStoragePolicy
        } set: { policy in
            store.settings.processingStoragePolicy = policy
            for index in store.settings.workflows.indices {
                store.settings.workflows[index].processingStoragePolicy = policy
            }
        }
    }

    private func workflowBinding(for id: String) -> Binding<WorkflowPolicy>? {
        guard store.settings.workflows.contains(where: { $0.id == id }) else {
            return nil
        }
        return Binding {
            store.settings.workflows.first { $0.id == id }
                ?? store.settings.policy(for: id)
        } set: { policy in
            guard store.settings.workflows.contains(where: { $0.id == policy.id }) else {
                return
            }
            store.updateWorkflow(policy)
        }
    }

    private var modelSelectionBinding: Binding<String> {
        Binding {
            store.settings.lmStudioModelID ?? ""
        } set: { value in
            store.settings.lmStudioModelID = value.isEmpty ? nil : value
        }
    }

    private var transcriptLimitBinding: Binding<Double> {
        Binding {
            Double(store.settings.maxTranscriptCharactersForAnalysis)
        } set: { value in
            store.settings.maxTranscriptCharactersForAnalysis = Int(value)
        }
    }

    private var contextSummary: String {
        guard let loadedContextTokens else {
            return "Refresh models to read the loaded context window from LM Studio."
        }
        var text = "Loaded context: \(loadedContextTokens.formatted()) tokens"
        if let maxContextTokens {
            text += ", max supported: \(maxContextTokens.formatted()) tokens"
        }
        return text
    }

    private var transcriptSliderUpperBound: Double {
        guard let safeTranscriptCharacterLimit else { return 80000 }
        return Double(max(6000, safeTranscriptCharacterLimit))
    }

    private var safeTranscriptCharacterLimit: Int? {
        guard let loadedContextTokens else { return nil }
        return safeTranscriptCharacterLimit(for: loadedContextTokens)
    }

    private func applySafeTranscriptLimit() {
        if let safeTranscriptCharacterLimit {
            store.settings.maxTranscriptCharactersForAnalysis = safeTranscriptCharacterLimit
        }
    }

    private func safeTranscriptCharacterLimit(for contextTokens: Int) -> Int {
        let reservedTokens = 2_500
        let availableTokens = max(2_000, contextTokens - reservedTokens)
        return max(6_000, availableTokens * 3)
    }

    private func checkMacWhisper() {
        isChecking = true
        macWhisperStatus = "Checking..."
        Task {
            do {
                let service = MacWhisperService(
                    executablePath: store.settings.macWhisperPath,
                    timeoutSeconds: store.settings.transcriptionTimeoutSeconds
                )
                let version = try await service.version()
                await MainActor.run {
                    macWhisperStatus = version.isEmpty ? "MacWhisper responded." : version
                    isChecking = false
                }
            } catch {
                await MainActor.run {
                    macWhisperStatus = (error as? ProcessingFailure)?.details ?? error.localizedDescription
                    isChecking = false
                }
            }
        }
    }

    private func checkFFmpeg() {
        isCheckingFFmpeg = true
        ffmpegStatus = "Checking..."
        let path = store.settings.ffmpegPath
        Task {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: path)
            process.arguments = ["-version"]
            let stdout = Pipe()
            process.standardOutput = stdout
            process.standardError = Pipe()
            do {
                try process.run()
                let data = stdout.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                let output = String(data: data, encoding: .utf8) ?? ""
                let firstLine = output.split(separator: "\n").first.map(String.init) ?? "ffmpeg responded."
                await MainActor.run {
                    ffmpegStatus = process.terminationStatus == 0 ? firstLine : "ffmpeg exited with status \(process.terminationStatus)."
                    isCheckingFFmpeg = false
                }
            } catch {
                await MainActor.run {
                    ffmpegStatus = error.localizedDescription
                    isCheckingFFmpeg = false
                }
            }
        }
    }

    private func refreshModels() {
        guard let url = URL(string: store.settings.lmStudioBaseURL) else {
            lmStudioStatus = "Invalid LM Studio URL."
            return
        }

        isLoadingModels = true
        lmStudioStatus = "Loading models..."
        Task {
            do {
                let requestURL = url.appendingPathComponent("models")
                let (data, _) = try await URLSession.shared.data(from: requestURL)
                let response = try JSONDecoder().decode(SettingsModelsResponse.self, from: data)
                let contextInfo = try? await fetchLoadedContextInfo(baseURL: url, preferredModelID: store.settings.lmStudioModelID)
                await MainActor.run {
                    lmStudioModels = response.data.map(\.id)
                    loadedContextTokens = contextInfo?.loadedContextTokens
                    maxContextTokens = contextInfo?.maxContextTokens
                    if lmStudioModels.isEmpty {
                        // Don't clear the preference here: with no model loaded, this
                        // is exactly the id LMStudioService.modelKeyToLoad() needs to
                        // know which model to load automatically on the next import.
                        loadedContextTokens = nil
                        maxContextTokens = nil
                        lmStudioStatus = "No model is loaded in LM Studio."
                    } else if let selected = store.settings.lmStudioModelID, !lmStudioModels.contains(selected) {
                        store.settings.lmStudioModelID = nil
                        lmStudioStatus = "Selected model is no longer loaded. Using first loaded model."
                    } else {
                        lmStudioStatus = contextInfo == nil ? "\(lmStudioModels.count) loaded model(s)." : "Connected."
                    }
                    if let safeTranscriptCharacterLimit,
                       store.settings.maxTranscriptCharactersForAnalysis > safeTranscriptCharacterLimit {
                        store.settings.maxTranscriptCharactersForAnalysis = safeTranscriptCharacterLimit
                    }
                    isLoadingModels = false
                }
            } catch {
                await MainActor.run {
                    lmStudioModels = []
                    loadedContextTokens = nil
                    maxContextTokens = nil
                    lmStudioStatus = error.localizedDescription
                    isLoadingModels = false
                }
            }
        }
    }

    private func fetchLoadedContextInfo(baseURL: URL, preferredModelID: String?) async throws -> LoadedContextInfo? {
        let nativeBaseURL = lmStudioNativeBaseURL(from: baseURL)
        let requestURL = nativeBaseURL.appendingPathComponent("models")
        let (data, _) = try await URLSession.shared.data(from: requestURL)
        let response = try JSONDecoder().decode(LMStudioNativeModelsResponse.self, from: data)
        let loadedModels = response.models.filter { !$0.loadedInstances.isEmpty }
        let selectedModel = loadedModels.first { model in
            model.key == preferredModelID || model.loadedInstances.contains { $0.id == preferredModelID }
        } ?? loadedModels.first

        guard let selectedModel, let instance = selectedModel.loadedInstances.first else {
            return nil
        }

        return LoadedContextInfo(
            loadedContextTokens: instance.config.contextLength,
            maxContextTokens: selectedModel.maxContextLength
        )
    }

    private func lmStudioNativeBaseURL(from openAIBaseURL: URL) -> URL {
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
}

struct WorkflowPolicyEditor: View {
    @Binding var policy: WorkflowPolicy

    var body: some View {
        Group {
            Section("Source") {
                TextField("Name", text: $policy.name)
                Toggle("Enabled", isOn: $policy.isEnabled)
                Picker("Recordings come from", selection: $policy.sourceBehavior) {
                    ForEach(SourceBehavior.allCases) { behavior in
                        Text(behavior.label).tag(behavior)
                    }
                }
                if policy.sourceBehavior.usesWatchFolder {
                    FolderPathRow(title: "Watch folder", path: $policy.watchFolderPath)
                    Toggle("Include subfolders", isOn: $policy.includeWatchFolderSubfolders)
                }
            }

            Section("Analysis") {
                Toggle("Analyze with LM Studio", isOn: $policy.usesSmartAnalysis)
                    .help("Writes the title, summary and filename slug from what was said. Off is much faster.")
                Toggle("Use a date spoken in the recording", isOn: $policy.useSpokenDateFromTranscript)
                    .help("Copying or syncing a recording often resets its file date. A spoken date, when present, overrides it.")
                    .disabled(!policy.usesSmartAnalysis)
                if policy.transcriptBehavior != .doNotExportTranscript {
                    Picker("Summary in the note", selection: $policy.summaryStyle) {
                        ForEach(SummaryStyle.allCases) { style in
                            Text(style.label).tag(style)
                        }
                    }
                    .disabled(!policy.usesSmartAnalysis)
                }
            }

            Section("Note") {
                Picker("Note", selection: $policy.transcriptBehavior) {
                    ForEach(visibleTranscriptBehaviors) { behavior in
                        Text(behavior.label).tag(behavior)
                    }
                }
                if policy.transcriptBehavior == .appendToMonthlyNote {
                    Picker("Cadence", selection: $policy.notePeriod) {
                        ForEach(NotePeriod.allCases) { period in
                            Text(period.label).tag(period)
                        }
                    }
                }
                if policy.transcriptBehavior != .doNotExportTranscript {
                    FolderPathRow(title: noteFolderTitle, path: $policy.destinationPath)
                    Toggle("Title line in the note", isOn: $policy.noteIncludesTitle)
                    Toggle("Embed audio in note", isOn: $policy.embedAudioInNote)
                    if policy.embedAudioInNote {
                        if policy.audioFileBehavior == .copyToFolder || policy.audioFileBehavior == .moveToFolder {
                            Picker("Embed as", selection: $policy.noteLinkStyle) {
                                ForEach(NoteLinkStyle.allCases) { style in
                                    Text(style.label).tag(style)
                                }
                            }
                        } else {
                            Text("Linked by its file path \u{2014} copy or move the audio below to use an Obsidian wikilink instead.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }

            Section("Audio file") {
                Picker("Audio", selection: $policy.audioFileBehavior) {
                    ForEach(AudioFileBehavior.allCases) { behavior in
                        Text(behavior.label).tag(behavior)
                    }
                }
                if policy.audioFileBehavior == .copyToFolder || policy.audioFileBehavior == .moveToFolder {
                    FolderPathRow(title: "Audio folder", path: $policy.audioDestinationPath)
                }
                Toggle("Normalize (\u{2212}16 LUFS)", isOn: $policy.normalizeAudio)
                    .help("Evens out level so quiet recordings transcribe better. Needs ffmpeg.")
                Toggle("Compress on export", isOn: $policy.compressAudioOnExport)
                Picker("Bitrate", selection: $policy.compressionBitrateKbps) {
                    ForEach(AudioCompressor.bitrateChoicesKbps, id: \.self) { bitrate in
                        Text("\(bitrate) kbps").tag(bitrate)
                    }
                }
                .disabled(!policy.compressAudioOnExport)
                if policy.compressAudioOnExport {
                    Text("Files smaller than the selected bitrate are not altered.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Picker("Channels", selection: $policy.compressionForceMono) {
                    Text("Mono").tag(true)
                    Text("Keep source").tag(false)
                }
                .disabled(!policy.compressAudioOnExport)
            }

            Section("Filenames") {
                TextField("Pattern", text: $policy.filenamePattern)
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: Space.xs) {
                        Text(FilenamePattern.preview(pattern: policy.filenamePattern, workflowName: policy.name))
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                            .opacity(patternIsUnused || patternNeedsAnalysis ? 0.5 : 1)
                        if patternIsUnused {
                            Text("Not used \u{2014} this workflow doesn't write a separate note or rename audio.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        } else if patternNeedsAnalysis {
                            Text("LM Studio is off, so {title} and {slug} fall back to the plain filename.")
                                .font(.caption)
                                .foregroundStyle(.orange)
                        }
                    }
                    Spacer()
                    PopoverHelp()
                }
            }

            Section("Review") {
                Picker("Review before import", selection: $policy.reviewBehavior) {
                    ForEach(ReviewBehavior.allCases) { behavior in
                        Text(behavior.label).tag(behavior)
                    }
                }
            }
        }
    }

    private var patternNeedsAnalysis: Bool {
        !policy.usesSmartAnalysis && FilenamePattern.requiresAnalysis(pattern: policy.filenamePattern)
    }

    private var patternIsUnused: Bool {
        let noteUsesPattern = policy.transcriptBehavior == .createMarkdownFile || policy.transcriptBehavior == .saveTranscriptOnly
        let audioUsesPattern = policy.audioFileBehavior != .leaveInPlace
        return !noteUsesPattern && !audioUsesPattern
    }

    private var visibleTranscriptBehaviors: [TranscriptBehavior] {
        [.appendToMonthlyNote, .createMarkdownFile, .doNotExportTranscript]
    }

    private var noteFolderTitle: String {
        switch policy.transcriptBehavior {
        case .appendToMonthlyNote: "\(policy.notePeriod.label) note folder"
        case .createMarkdownFile, .saveTranscriptOnly: "Note folder"
        case .doNotExportTranscript: "Note folder"
        }
    }
}

struct FolderPathRow: View {
    var title: String
    @Binding var path: String

    var body: some View {
        HStack {
            Text(title)
                .frame(width: 140, alignment: .leading)
            Text(path.isEmpty ? "No folder selected" : path)
                .foregroundStyle(path.isEmpty ? .secondary : .primary)
                .lineLimit(1)
                .truncationMode(.middle)
            Button("Choose...") {
                chooseFolder()
            }
        }
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.title = title
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url {
            path = url.path
        }
    }
}

struct PopoverHelp: View {
    @State private var showingHelp = false

    var body: some View {
        Button {
            showingHelp.toggle()
        } label: {
            Image(systemName: "questionmark.circle")
        }
        .buttonStyle(.borderless)
        .popover(isPresented: $showingHelp) {
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                Text("Placeholders")
                    .font(.headline)
                ForEach(FilenamePattern.documentedPlaceholders, id: \.token) { placeholder in
                    VStack(alignment: .leading, spacing: 1) {
                        Text(placeholder.token)
                            .font(.caption.monospaced())
                            .textSelection(.enabled)
                        Text(placeholder.explanation)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(16)
            }
            .frame(width: 320, height: 420)
        }
    }
}

private struct SettingsModelsResponse: Decodable {
    struct Model: Decodable { var id: String }
    var data: [Model]
}

private struct LoadedContextInfo {
    var loadedContextTokens: Int
    var maxContextTokens: Int
}
