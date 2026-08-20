import SwiftUI

enum SetupStep: Int, CaseIterable {
    case welcome
    case transcription
    case analysis
    case extras
    case done
}

/// Shown instead of `ContentView` on a fresh install (see `ImportStore.needsSetup`), so a
/// first-time download never has to discover Settings → Services on its own to learn that
/// MacWhisper, ffmpeg, or LM Studio need attention.
struct SetupWizardView: View {
    @EnvironmentObject private var store: ImportStore
    @State private var step: SetupStep = .welcome
    @State private var movingForward = true
    @State private var macWhisperState: ConnectivityState = .unknown
    @State private var lmStudioState: ConnectivityState = .unknown
    @State private var ffmpegState: ConnectivityState = .unknown

    var body: some View {
        VStack(spacing: 0) {
            if showsChrome {
                header
            }
            stepContent
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            if showsChrome {
                footer
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var stepContent: some View {
        ZStack {
            Group {
                switch step {
                case .welcome:
                    SetupWelcomeStepView(onContinue: { go(to: .transcription) })
                case .transcription:
                    SetupTranscriptionStepView(state: $macWhisperState)
                case .analysis:
                    SetupAnalysisStepView(state: $lmStudioState)
                case .extras:
                    SetupExtrasStepView(state: $ffmpegState)
                case .done:
                    SetupCompleteStepView(
                        macWhisperState: macWhisperState,
                        lmStudioState: lmStudioState,
                        ffmpegState: ffmpegState,
                        onFinish: { store.markSetupComplete() }
                    )
                }
            }
            .id(step)
            .transition(stepTransition)
        }
    }

    private var stepTransition: AnyTransition {
        .asymmetric(
            insertion: .move(edge: movingForward ? .trailing : .leading).combined(with: .opacity),
            removal: .move(edge: movingForward ? .leading : .trailing).combined(with: .opacity)
        )
    }

    private var showsChrome: Bool {
        step != .welcome && step != .done
    }

    private var header: some View {
        HStack {
            SetupProgressDots(total: 3, currentIndex: progressIndex)
            Spacer()
            Button("Skip for now") { go(to: .done) }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .font(.callout)
        }
        .padding(.horizontal, Space.xxl)
        .padding(.top, Space.xl)
        .padding(.bottom, Space.m)
    }

    private var footer: some View {
        HStack {
            Button("Back") { goBack() }
                .buttonStyle(.bordered)
                .controlSize(.large)
            Spacer()
            VStack(alignment: .trailing, spacing: Space.xs) {
                if showsWarningHint {
                    Text("You can fix this later in Settings.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Button("Continue") { advance() }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
            }
        }
        .padding(.horizontal, Space.xxl)
        .padding(.bottom, Space.xxl)
        .padding(.top, Space.l)
    }

    private var progressIndex: Int {
        switch step {
        case .transcription: 0
        case .analysis: 1
        case .extras: 2
        default: 0
        }
    }

    private var showsWarningHint: Bool {
        switch step {
        case .transcription: macWhisperState.detail != nil
        case .analysis: lmStudioState.detail != nil && !lmStudioState.isAvailable
        default: false
        }
    }

    private func advance() {
        switch step {
        case .welcome: go(to: .transcription)
        case .transcription: go(to: .analysis)
        case .analysis: go(to: .extras)
        case .extras: go(to: .done)
        case .done: store.markSetupComplete()
        }
    }

    private func goBack() {
        switch step {
        case .transcription: go(to: .welcome)
        case .analysis: go(to: .transcription)
        case .extras: go(to: .analysis)
        default: break
        }
    }

    private func go(to newStep: SetupStep) {
        movingForward = newStep.rawValue >= step.rawValue
        withAnimation(.easeInOut(duration: 0.3)) {
            step = newStep
        }
    }
}

// MARK: - Welcome

private struct SetupWelcomeStepView: View {
    var onContinue: () -> Void

    var body: some View {
        VStack(spacing: Space.xxl) {
            Spacer()
            ZStack {
                Circle()
                    .fill(
                        RadialGradient(
                            colors: [Color.accentColor.opacity(0.35), .clear],
                            center: .center,
                            startRadius: 0,
                            endRadius: 150
                        )
                    )
                    .frame(width: 260, height: 260)
                Image(systemName: "waveform")
                    .font(.system(size: 60, weight: .light))
                    .foregroundStyle(Color.accentColor)
            }

            VStack(spacing: Space.s) {
                Text("Welcome to Voice Memo Renamer")
                    .font(.largeTitle.weight(.semibold))
                    .multilineTextAlignment(.center)
                Text("Record a thought, and this app transcribes it, writes a title and summary, and files it into your Obsidian journal.")
                    .font(.title3)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 460)
            }

            pipelineRow

            Spacer()

            VStack(spacing: Space.s) {
                Button("Get Started") { onContinue() }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                Text("Takes about a minute to check your setup.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(Space.xxl)
    }

    private var pipelineRow: some View {
        HStack(spacing: Space.m) {
            pipelineStep("mic.fill", "Record")
            chevron
            pipelineStep("waveform", "Transcribe")
            chevron
            pipelineStep("sparkles", "Analyze")
            chevron
            pipelineStep("tray.and.arrow.down.fill", "Import")
        }
        .foregroundStyle(.secondary)
    }

    private var chevron: some View {
        Image(systemName: "chevron.right")
            .font(.caption2)
            .foregroundStyle(.tertiary)
    }

    private func pipelineStep(_ icon: String, _ label: String) -> some View {
        VStack(spacing: 4) {
            Image(systemName: icon)
                .font(.body)
            Text(label)
                .font(.caption)
        }
    }
}

// MARK: - Transcription (MacWhisper)

private struct SetupTranscriptionStepView: View {
    @EnvironmentObject private var store: ImportStore
    @Binding var state: ConnectivityState

    var body: some View {
        SetupStepScaffold(
            icon: "waveform",
            title: "Transcription",
            subtitle: "MacWhisper turns each recording into text. Install MacWhisper and enable its command-line tool in its own settings if this isn't found."
        ) {
            SetupServiceCard(
                icon: "waveform",
                title: "MacWhisper CLI",
                state: state,
                value: $store.settings.macWhisperPath,
                valueLabel: "Path",
                pathHint: "Usually /usr/local/bin/mw, once its CLI is enabled in MacWhisper's own settings.",
                onLocate: locate,
                onCheck: { Task { await check() } },
                actions: [("Get MacWhisper", openMacWhisperPage)]
            )
        }
        .task { await autoDetectAndCheck() }
    }

    @MainActor
    private func autoDetectAndCheck() async {
        state = .checking
        if let detected = await DependencyDetector.detectMacWhisperPath(configured: store.settings.macWhisperPath),
           detected != store.settings.macWhisperPath {
            store.settings.macWhisperPath = detected
        }
        await check()
    }

    @MainActor
    private func check() async {
        state = .checking
        do {
            let service = MacWhisperService(
                executablePath: store.settings.macWhisperPath,
                timeoutSeconds: store.settings.transcriptionTimeoutSeconds
            )
            _ = try await service.version()
            state = .ok
        } catch {
            state = .unavailable((error as? ProcessingFailure)?.message ?? error.localizedDescription)
        }
    }

    private func locate() {
        let panel = NSOpenPanel()
        panel.title = "Locate MacWhisper CLI"
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = URL(fileURLWithPath: "/usr/local/bin")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        store.settings.macWhisperPath = url.path
        Task { await check() }
    }

    private func openMacWhisperPage() {
        guard let url = URL(string: "https://goodsnooze.gumroad.com/l/macwhisper") else { return }
        NSWorkspace.shared.open(url)
    }
}

// MARK: - Analysis (LM Studio)

private struct SetupAnalysisStepView: View {
    @EnvironmentObject private var store: ImportStore
    @Binding var state: ConnectivityState

    var body: some View {
        SetupStepScaffold(
            icon: "sparkles",
            title: "Analysis",
            subtitle: "LM Studio runs a local model that writes the title, summary, and filename for each recording. Download at least one model in LM Studio — it loads automatically when needed."
        ) {
            SetupServiceCard(
                icon: "sparkles",
                title: "LM Studio",
                state: state,
                value: $store.settings.lmStudioBaseURL,
                valueLabel: "Server address",
                pathHint: "Default address once LM Studio's local server is started: http://localhost:1234/v1.",
                onLocate: nil,
                onCheck: { Task { await check() } },
                actions: [("Open LM Studio", openLMStudio), ("Get LM Studio", openLMStudioPage)]
            )
        }
        .task { await check() }
    }

    @MainActor
    private func check() async {
        state = .checking
        guard let baseURL = URL(string: store.settings.lmStudioBaseURL), baseURL.scheme != nil, baseURL.host != nil else {
            state = .unavailable("This isn't a valid address.")
            return
        }
        do {
            // The native endpoint reports loaded_instances, which is the same signal
            // analysis itself relies on (LMStudioService.loadedModel()) — the
            // OpenAI-compatible /v1/models endpoint can't tell loaded from merely downloaded.
            let requestURL = nativeBaseURL(from: baseURL).appendingPathComponent("models")
            var request = URLRequest(url: requestURL)
            request.cachePolicy = .reloadIgnoringLocalCacheData
            request.timeoutInterval = 4
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
                state = .unavailable("LM Studio answered, but not with a model list.")
                return
            }
            let decoded = try? JSONDecoder().decode(LMStudioNativeModelsResponse.self, from: data)
            let models = decoded?.models ?? []
            if models.contains(where: { !$0.loadedInstances.isEmpty }) {
                state = .ok
            } else if !models.isEmpty {
                state = .idle("LM Studio is running, but no model is loaded yet.")
            } else {
                state = .unavailable("LM Studio is running, but has no downloaded models.")
            }
        } catch {
            state = .unavailable("Can't reach LM Studio. Install it, download a model, and start its local server.")
        }
    }

    private func nativeBaseURL(from openAIBaseURL: URL) -> URL {
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

    private func openLMStudio() {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = ["-a", "LM Studio"]
        try? process.run()
    }

    private func openLMStudioPage() {
        guard let url = URL(string: "https://lmstudio.ai") else { return }
        NSWorkspace.shared.open(url)
    }
}

// MARK: - Optional extras (ffmpeg + Obsidian vault)

private struct SetupExtrasStepView: View {
    @EnvironmentObject private var store: ImportStore
    @Binding var state: ConnectivityState

    var body: some View {
        SetupStepScaffold(
            icon: "slider.horizontal.3",
            title: "Optional extras",
            subtitle: "Both of these are optional — the app works fine without them."
        ) {
            VStack(spacing: Space.l) {
                SetupServiceCard(
                    icon: "waveform.path",
                    title: "ffmpeg",
                    subtitle: "Only needed if you turn on loudness normalization under Settings → Audio.",
                    state: state,
                    value: $store.settings.ffmpegPath,
                    valueLabel: "Path",
                    pathHint: "Usually /opt/homebrew/bin/ffmpeg (Apple Silicon Homebrew) or /usr/local/bin/ffmpeg (Intel Homebrew).",
                    onLocate: locate,
                    onCheck: { Task { await check() } },
                    actions: [("Get Homebrew", openHomebrewPage)]
                )
                vaultCard
            }
        }
        .task { await autoDetectAndCheck() }
    }

    private var vaultCard: some View {
        VStack(alignment: .leading, spacing: Space.m) {
            HStack(spacing: Space.s) {
                Image(systemName: "folder")
                    .font(.title3)
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 22)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Obsidian vault").font(.headline)
                    Text("Where journal notes and imported audio end up. Change this any time in Settings.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            FolderPathRow(title: "Vault", path: $store.settings.vaultRootPath)
        }
        .padding(Space.l)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color(nsColor: .separatorColor)))
    }

    @MainActor
    private func autoDetectAndCheck() async {
        state = .checking
        if let detected = await DependencyDetector.detectFFmpegPath(configured: store.settings.ffmpegPath),
           detected != store.settings.ffmpegPath {
            store.settings.ffmpegPath = detected
        }
        await check()
    }

    @MainActor
    private func check() async {
        state = .checking
        let process = Process()
        process.executableURL = URL(fileURLWithPath: store.settings.ffmpegPath)
        process.arguments = ["-version"]
        let stdout = Pipe()
        process.standardOutput = stdout
        process.standardError = Pipe()
        do {
            try process.run()
        } catch {
            state = .unavailable("Not found at this path. Install with Homebrew: brew install ffmpeg")
            return
        }
        process.waitUntilExit()
        state = process.terminationStatus == 0
            ? .ok
            : .unavailable("ffmpeg exited with status \(process.terminationStatus).")
    }

    private func locate() {
        let panel = NSOpenPanel()
        panel.title = "Locate ffmpeg"
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = URL(fileURLWithPath: "/opt/homebrew/bin")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        store.settings.ffmpegPath = url.path
        Task { await check() }
    }

    private func openHomebrewPage() {
        guard let url = URL(string: "https://brew.sh") else { return }
        NSWorkspace.shared.open(url)
    }
}

// MARK: - Done

private struct SetupCompleteStepView: View {
    var macWhisperState: ConnectivityState
    var lmStudioState: ConnectivityState
    var ffmpegState: ConnectivityState
    var onFinish: () -> Void

    var body: some View {
        VStack(spacing: Space.xxl) {
            Spacer()
            Image(systemName: "checkmark.seal.fill")
                .font(.system(size: 52, weight: .light))
                .foregroundStyle(Color.accentColor)
            Text("You're set up")
                .font(.largeTitle.weight(.semibold))

            VStack(spacing: Space.m) {
                summaryRow(icon: "waveform", label: "MacWhisper", state: macWhisperState)
                summaryRow(icon: "sparkles", label: "LM Studio", state: lmStudioState)
                summaryRow(icon: "waveform.path", label: "ffmpeg (optional)", state: ffmpegState)
            }
            .padding(Space.l)
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color(nsColor: .separatorColor)))
            .frame(maxWidth: 380)

            Text("Anything not connected yet can be fixed later in Settings → Services.")
                .font(.caption)
                .foregroundStyle(.secondary)

            Spacer()
            Button("Open Voice Memo Renamer") { onFinish() }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
            Spacer()
        }
        .padding(Space.xxl)
    }

    private func summaryRow(icon: String, label: String, state: ConnectivityState) -> some View {
        HStack(spacing: Space.m) {
            Image(systemName: icon)
                .frame(width: 20)
                .foregroundStyle(.secondary)
            Text(label)
            Spacer()
            Image(systemName: statusIcon(state))
                .foregroundStyle(state.color)
            Text(statusText(state))
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 90, alignment: .trailing)
        }
        .frame(maxWidth: .infinity)
    }

    private func statusText(_ state: ConnectivityState) -> String {
        switch state {
        case .ok: "Ready"
        case .idle: "Ready soon"
        case .unavailable: "Needs attention"
        case .checking, .unknown: "Not checked"
        }
    }

    private func statusIcon(_ state: ConnectivityState) -> String {
        switch state {
        case .ok: "checkmark.circle.fill"
        case .idle: "checkmark.circle"
        case .unavailable: "exclamationmark.triangle.fill"
        case .checking, .unknown: "circle.dashed"
        }
    }
}

// MARK: - Shared pieces

private struct SetupStepScaffold<Content: View>: View {
    var icon: String
    var title: String
    var subtitle: String
    @ViewBuilder var content: Content

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Space.xl) {
                VStack(alignment: .leading, spacing: Space.s) {
                    Label(title, systemImage: icon)
                        .font(.title.weight(.semibold))
                    Text(subtitle)
                        .font(.body)
                        .foregroundStyle(.secondary)
                }
                content
            }
            .frame(maxWidth: 520, alignment: .leading)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, Space.xxl)
            .padding(.vertical, Space.xl)
        }
    }
}

private struct SetupServiceCard: View {
    var icon: String
    var title: String
    var subtitle: String?
    var state: ConnectivityState
    @Binding var value: String
    var valueLabel: String
    var pathHint: String?
    var onLocate: (() -> Void)?
    var onCheck: () -> Void
    var actions: [(label: String, action: () -> Void)]

    init(
        icon: String,
        title: String,
        subtitle: String? = nil,
        state: ConnectivityState,
        value: Binding<String>,
        valueLabel: String,
        pathHint: String? = nil,
        onLocate: (() -> Void)? = nil,
        onCheck: @escaping () -> Void,
        actions: [(label: String, action: () -> Void)] = []
    ) {
        self.icon = icon
        self.title = title
        self.subtitle = subtitle
        self.state = state
        self._value = value
        self.valueLabel = valueLabel
        self.pathHint = pathHint
        self.onLocate = onLocate
        self.onCheck = onCheck
        self.actions = actions
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Space.m) {
            HStack(alignment: .top, spacing: Space.s) {
                Image(systemName: icon)
                    .font(.title3)
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 22)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.headline)
                    if let subtitle {
                        Text(subtitle)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
                statusPill
            }

            HStack(spacing: Space.s) {
                Text(valueLabel)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(width: 90, alignment: .leading)
                TextField(valueLabel, text: $value)
                    .textFieldStyle(.roundedBorder)
                if let onLocate {
                    Button("Locate\u{2026}", action: onLocate)
                }
            }

            if let pathHint {
                Text(pathHint)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }

            if let detail = state.detail {
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }

            HStack(spacing: Space.s) {
                Button("Check Again", action: onCheck)
                    .controlSize(.small)
                ForEach(actions.indices, id: \.self) { index in
                    Button(actions[index].label, action: actions[index].action)
                        .controlSize(.small)
                }
                Spacer()
            }
        }
        .padding(Space.l)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color(nsColor: .separatorColor)))
        .shadow(color: .black.opacity(0.06), radius: 8, y: 3)
    }

    private var statusPill: some View {
        HStack(spacing: 5) {
            statusIconView
            Text(state.summary)
                .font(.caption.weight(.medium))
        }
        .padding(.horizontal, Space.s)
        .padding(.vertical, 4)
        .background(state.color.opacity(0.15), in: Capsule())
        .foregroundStyle(state.color)
        .animation(.easeInOut(duration: 0.25), value: state.summary)
    }

    private var statusIconView: some View {
        Group {
            if case .checking = state {
                ProgressView().controlSize(.mini)
            } else {
                Image(systemName: state.isAvailable ? "checkmark.circle.fill" : (isUnknown ? "circle" : "exclamationmark.triangle.fill"))
            }
        }
        .frame(width: 12, height: 12)
    }

    private var isUnknown: Bool {
        if case .unknown = state { return true }
        return false
    }
}

private struct SetupProgressDots: View {
    var total: Int
    var currentIndex: Int

    var body: some View {
        HStack(spacing: Space.s) {
            ForEach(0..<total, id: \.self) { index in
                Circle()
                    .fill(index == currentIndex ? Color.accentColor : Color(nsColor: .separatorColor))
                    .frame(width: index == currentIndex ? 8 : 6, height: index == currentIndex ? 8 : 6)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: currentIndex)
    }
}
