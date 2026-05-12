import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var store: ImportStore
    @State private var macWhisperStatus: String = "Not checked"
    @State private var isChecking = false

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
                        Stepper("Analysis transcript limit: \(store.settings.maxTranscriptCharactersForAnalysis) characters", value: $store.settings.maxTranscriptCharactersForAnalysis, in: 6000...80000, step: 2000)
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
}
