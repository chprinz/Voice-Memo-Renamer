import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var store: ImportStore
    @Environment(\.dismiss) private var dismiss
    @State private var selectedWorkflowID: String = StandardWorkflowID.obsidianJournal
    @State private var macWhisperStatus: String = "Not checked"
    @State private var isChecking = false
    @State private var lmStudioModels: [String] = []
    @State private var lmStudioStatus: String = "Not checked"
    @State private var isLoadingModels = false
    @State private var loadedContextTokens: Int?
    @State private var maxContextTokens: Int?

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
            .padding(.horizontal, 28)
            .padding(.top, 24)
            .padding(.bottom, 10)

            ScrollView {
                Form {
                    generalSection
                    workflowsSection
                    storageSection
                    servicesSection
                }
                .formStyle(.grouped)
                .frame(maxWidth: 860, alignment: .leading)
                .padding(.horizontal, 24)
                .padding(.bottom, 28)
            }
        }
        .background(Color(nsColor: .textBackgroundColor))
        .onAppear {
            selectedWorkflowID = store.settings.defaultWorkflow
            checkMacWhisper()
            refreshModels()
        }
    }

    private var generalSection: some View {
        Section("General") {
            Picker("Default workflow", selection: $store.settings.defaultWorkflow) {
                ForEach(store.settings.workflows.filter(\.isEnabled)) { workflow in
                    Text(workflow.name).tag(workflow.id)
                }
            }
            Toggle("Check watch folders when the app starts", isOn: $store.settings.checkWatchFoldersAtLaunch)
        }
    }

    private var workflowsSection: some View {
        Section("Workflows") {
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

            if let binding = workflowBinding(for: selectedWorkflowID) {
                WorkflowPolicyEditor(policy: binding, isDefault: store.settings.defaultWorkflow == selectedWorkflowID) {
                    store.settings.defaultWorkflow = selectedWorkflowID
                }
            }
        }
    }

    private var storageSection: some View {
        Section("Storage") {
            HStack {
                Text("App Cache")
                Spacer()
                Text(FileSizeFormatter.storageText(bytes: store.appStorageUsage()))
                    .foregroundStyle(.secondary)
            }
            Text("Cache contains only temporary processing copies, never original audio files.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Button("Clear Cache") {
                store.clearCache()
            }
        }
    }

    private var servicesSection: some View {
        Section("Services") {
            TextField("MacWhisper CLI path", text: $store.settings.macWhisperPath)
            HStack {
                Text(macWhisperStatus)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                Spacer()
                Button(isChecking ? "Checking..." : "Check") {
                    checkMacWhisper()
                }
                .disabled(isChecking)
            }

            Divider()

            TextField("LM Studio base URL", text: $store.settings.lmStudioBaseURL)
            Picker("Model", selection: modelSelectionBinding) {
                Text("First loaded model").tag("")
                ForEach(lmStudioModels, id: \.self) { model in
                    Text(model).tag(model)
                }
            }
            HStack {
                Text(lmStudioStatus)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                Spacer()
                Button(isLoadingModels ? "Loading..." : "Refresh Models") {
                    refreshModels()
                }
                .disabled(isLoadingModels)
            }
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Analysis transcript limit")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                    Spacer()
                    if loadedContextTokens != nil {
                        Button("Use Safe Limit") {
                            applySafeTranscriptLimit()
                        }
                        .buttonStyle(.borderless)
                    }
                }
                Text(contextSummary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                HStack {
                    TextField(
                        "Transcript limit",
                        value: $store.settings.maxTranscriptCharactersForAnalysis,
                        format: .number
                    )
                    .frame(width: 180)
                    Text("characters")
                        .foregroundStyle(.secondary)
                }
                Slider(
                    value: transcriptLimitBinding,
                    in: 6000...transcriptSliderUpperBound,
                    step: 1000
                )
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
                        store.settings.lmStudioModelID = nil
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
        let response = try JSONDecoder().decode(SettingsNativeModelsResponse.self, from: data)
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
    var isDefault: Bool
    var makeDefault: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            TextField("Name", text: $policy.name)
            Toggle("Enabled", isOn: $policy.isEnabled)
            Toggle("Default workflow", isOn: defaultBinding)

            Picker("Source behavior", selection: $policy.sourceBehavior) {
                ForEach(SourceBehavior.allCases) { behavior in
                    Text(behavior.label).tag(behavior)
                }
            }
            if policy.sourceBehavior.usesWatchFolder {
                FolderPathRow(title: "Watch folder", path: $policy.watchFolderPath)
            }

            Picker("Transcript", selection: $policy.transcriptBehavior) {
                ForEach(visibleTranscriptBehaviors) { behavior in
                    Text(behavior.label).tag(behavior)
                }
            }
            if policy.transcriptBehavior != .doNotExportTranscript {
                FolderPathRow(title: transcriptFolderTitle, path: $policy.destinationPath)
            }

            Picker("Audio file", selection: $policy.audioFileBehavior) {
                ForEach(AudioFileBehavior.allCases) { behavior in
                    Text(behavior.label).tag(behavior)
                }
            }
            if policy.audioFileBehavior == .copyToFolder || policy.audioFileBehavior == .moveToFolder {
                FolderPathRow(title: "Audio folder", path: $policy.audioDestinationPath)
            }

            TextField("Filename pattern", text: $policy.filenamePattern)
            HStack {
                Text(FilenamePattern.preview(pattern: policy.filenamePattern, workflowName: policy.name))
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                Spacer()
                PopoverHelp()
            }
        }
    }

    private var visibleTranscriptBehaviors: [TranscriptBehavior] {
        [.appendToMonthlyNote, .createMarkdownFile, .doNotExportTranscript]
    }

    private var transcriptFolderTitle: String {
        switch policy.transcriptBehavior {
        case .appendToMonthlyNote:
            return "Monthly note folder"
        case .createMarkdownFile, .saveTranscriptOnly:
            return "Markdown folder"
        case .doNotExportTranscript:
            return "Transcript folder"
        }
    }

    private var defaultBinding: Binding<Bool> {
        Binding {
            isDefault
        } set: { isOn in
            if isOn {
                makeDefault()
            }
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
            VStack(alignment: .leading, spacing: 8) {
                Text("Placeholders")
                    .font(.headline)
                Text(FilenamePattern.placeholders.joined(separator: "\n"))
                    .font(.caption.monospaced())
                    .textSelection(.enabled)
            }
            .padding(16)
            .frame(width: 260)
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

private struct SettingsNativeModelsResponse: Decodable {
    struct Model: Decodable {
        struct LoadedInstance: Decodable {
            struct Config: Decodable {
                var contextLength: Int

                enum CodingKeys: String, CodingKey {
                    case contextLength = "context_length"
                }
            }

            var id: String
            var config: Config
        }

        var key: String
        var loadedInstances: [LoadedInstance]
        var maxContextLength: Int

        enum CodingKeys: String, CodingKey {
            case key
            case loadedInstances = "loaded_instances"
            case maxContextLength = "max_context_length"
        }
    }

    var models: [Model]
}
