import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var store: ImportStore
    @State private var macWhisperStatus: String = "Not checked"
    @State private var isChecking = false
    @State private var lmStudioModels: [String] = []
    @State private var lmStudioStatus: String = "Not checked"
    @State private var isLoadingModels = false
    @State private var loadedContextTokens: Int?
    @State private var maxContextTokens: Int?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Settings")
                .font(.title2.weight(.semibold))
                .padding(.horizontal, 24)
                .padding(.top, 24)
                .padding(.bottom, 12)

            ScrollView {
                Form {
                    Section("Workflow") {
                        Picker("Default workflow", selection: $store.settings.defaultWorkflow) {
                            ForEach(WorkflowID.allCases) { workflow in
                                Text(workflow.label).tag(workflow)
                            }
                        }
                    }

                    Section("MacWhisper") {
                        TextField("CLI path", text: $store.settings.macWhisperPath)
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
                    }

                    Section("LM Studio") {
                        TextField("Base URL", text: $store.settings.lmStudioBaseURL)
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
                            Text("Longer transcripts are trimmed to start, middle, and end before analysis so LM Studio does not receive an oversized prompt.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }

                    Section("Obsidian") {
                        TextField("Vault root", text: $store.settings.vaultRootPath)
                        TextField("Voice Inbox", text: $store.settings.voiceInboxRelativePath)
                        TextField("Journal audio", text: $store.settings.journalAudioRelativePath)
                        TextField("Monthly notes", text: $store.settings.monthlyNotesRelativePath)
                    }
                }
                .formStyle(.grouped)
                .frame(maxWidth: 760, alignment: .leading)
                .padding(.horizontal, 24)
                .padding(.bottom, 24)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color(nsColor: .textBackgroundColor))
        .onAppear {
            refreshModels()
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
