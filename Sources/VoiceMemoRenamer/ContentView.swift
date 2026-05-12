import SwiftUI
import UniformTypeIdentifiers

enum NavigationSection: String, CaseIterable, Identifiable {
    case toReview
    case imported
    case attention
    case settings

    var id: String { rawValue }

    var label: String {
        switch self {
        case .toReview: "To Review"
        case .imported: "Imported"
        case .attention: "Attention"
        case .settings: "Settings"
        }
    }

    var icon: String {
        switch self {
        case .toReview: "tray.full"
        case .imported: "checkmark.circle"
        case .attention: "exclamationmark.triangle"
        case .settings: "gearshape"
        }
    }
}

struct ContentView: View {
    @EnvironmentObject private var store: ImportStore
    @State private var selection: NavigationSection = .toReview
    @State private var selectedItemID: ImportItem.ID?

    var body: some View {
        HStack(spacing: 0) {
            SidebarView(selection: $selection, count: count(for:))
                .frame(width: 210)

            Divider()

            mainContent
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .onChange(of: selection) { _ in
            syncSelection()
        }
        .onAppear {
            syncSelection()
        }
        .onChange(of: store.items.map(\.id)) { _ in
            syncSelection()
        }
    }

    @ViewBuilder
    private var mainContent: some View {
        if selection == .settings {
            SettingsView()
        } else {
            if let selectedItemID, let item = store.item(id: selectedItemID) {
                HSplitView {
                    ImportListView(
                        title: selection.label,
                        showsImportHeader: selection == .toReview,
                        emptyMessage: emptyMessage,
                        items: filteredItems,
                        selectedItemID: $selectedItemID
                    )
                    .frame(minWidth: 360, idealWidth: 430, maxWidth: 520)

                    ImportDetailView(item: item)
                        .frame(minWidth: 520)
                }
            } else {
                ImportListView(
                    title: selection.label,
                    showsImportHeader: selection == .toReview,
                    emptyMessage: emptyMessage,
                    items: filteredItems,
                    selectedItemID: $selectedItemID
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    private var emptyMessage: String {
        switch selection {
        case .toReview:
            "Drop or choose an audio file to begin."
        case .imported:
            "Imported memos will appear here."
        case .attention:
            "Items that need action will appear here."
        case .settings:
            ""
        }
    }

    private var filteredItems: [ImportItem] {
        items(for: selection)
    }

    private func items(for section: NavigationSection) -> [ImportItem] {
        switch section {
        case .toReview:
            store.items.filter { [.new, .queued, .transcribing, .transcribed, .analyzing, .readyForReview, .importing].contains($0.status) }
        case .imported:
            store.items.filter { $0.status == .imported }
        case .attention:
            store.items.filter { $0.status == .needsAttention || $0.status == .failed }
        case .settings:
            []
        }
    }

    private func count(for section: NavigationSection) -> Int {
        switch section {
        case .toReview:
            store.items.filter { $0.status == .readyForReview }.count
        case .imported:
            store.items.filter { $0.status == .imported }.count
        case .attention:
            store.items.filter { $0.status == .needsAttention || $0.status == .failed }.count
        case .settings:
            0
        }
    }

    private func syncSelection() {
        let ids = Set(filteredItems.map(\.id))
        if let selectedItemID, ids.contains(selectedItemID) {
            return
        }
        selectedItemID = filteredItems.first?.id
    }
}

struct SidebarView: View {
    @Binding var selection: NavigationSection
    var count: (NavigationSection) -> Int

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Voice Memo Renamer")
                .font(.headline)
                .padding(.horizontal, 14)
                .padding(.top, 16)

            VStack(spacing: 4) {
                ForEach(NavigationSection.allCases) { section in
                    Button {
                        selection = section
                    } label: {
                        SidebarRow(
                            section: section,
                            count: count(section),
                            isSelected: selection == section
                        )
                    }
                    .buttonStyle(SidebarButtonStyle(isSelected: selection == section))
                }
            }
            .padding(.horizontal, 8)

            Spacer()
        }
        .background(Color(nsColor: .controlBackgroundColor))
    }
}

struct SidebarRow: View {
    var section: NavigationSection
    var count: Int
    var isSelected: Bool

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: section.icon)
                .font(.system(size: 15, weight: .medium))
                .frame(width: 20)
                .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)

            Text(section.label)
                .font(.subheadline.weight(isSelected ? .semibold : .regular))
                .lineLimit(1)

            Spacer(minLength: 8)

            if count > 0 {
                Text("\(count)")
                    .font(.caption.weight(.semibold))
                    .monospacedDigit()
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .background(Color.secondary.opacity(0.16))
                    .clipShape(Capsule())
            }
        }
        .contentShape(Rectangle())
    }
}

struct SidebarButtonStyle: ButtonStyle {
    var isSelected: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .foregroundStyle(isSelected ? Color.primary : Color.secondary)
            .background(isSelected ? Color.accentColor.opacity(0.16) : Color.clear)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .opacity(configuration.isPressed ? 0.7 : 1)
    }
}

struct ImportListView: View {
    @EnvironmentObject private var store: ImportStore
    @State private var isTargeted = false
    var title: String
    var showsImportHeader: Bool
    var emptyMessage: String
    var items: [ImportItem]
    @Binding var selectedItemID: ImportItem.ID?

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Text(title)
                        .font(.title2.weight(.semibold))
                    Spacer()
                }

                if showsImportHeader {
                    DropHeader(isTargeted: isTargeted) {
                        chooseAudioFiles()
                    }
                }
            }
            .padding(18)

            if items.isEmpty {
                EmptyListState(
                    message: emptyMessage,
                    showsImportIcon: showsImportHeader
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(items, selection: $selectedItemID) { item in
                    ImportRow(item: item)
                        .tag(item.id)
                }
                .listStyle(.inset)
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .if(showsImportHeader) { view in
            view.onDrop(of: supportedTypes, isTargeted: $isTargeted) { providers in
                handleDrop(providers)
            }
        }
    }

    private var supportedTypes: [UTType] {
        [.fileURL, .audio, .mpeg4Audio, .mp3, .wav, .aiff, .mpeg4Movie, .quickTimeMovie]
    }

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        for provider in providers {
            importDroppedProvider(provider)
        }
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
        panel.allowedContentTypes = [.audio, .mpeg4Audio, .mp3, .wav]

        if panel.runModal() == .OK {
            Task { @MainActor in
                for url in panel.urls {
                    if let imported = await store.addItem(from: url) {
                        selectedItemID = imported.id
                        ImportProcessor(store: store).process(imported.id)
                    }
                }
            }
        }
    }
}

struct EmptyListState: View {
    var message: String
    var showsImportIcon: Bool

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: showsImportIcon ? "waveform.badge.plus" : "tray")
                .font(.system(size: 36, weight: .regular))
                .foregroundStyle(Color.secondary)

            Text(message)
                .font(.headline)
                .foregroundStyle(.primary)
                .multilineTextAlignment(.center)
        }
        .padding(32)
    }
}

struct DropHeader: View {
    var isTargeted: Bool
    var chooseFiles: () -> Void

    var body: some View {
        ViewThatFits(in: .horizontal) {
            horizontalLayout
            verticalLayout
        }
        .padding(14)
        .background(isTargeted ? Color.accentColor.opacity(0.12) : Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private var horizontalLayout: some View {
        HStack(spacing: 14) {
            dropText
            Spacer(minLength: 20)
            chooseButton
                .frame(minWidth: 150)
        }
    }

    private var verticalLayout: some View {
        VStack(alignment: .leading, spacing: 12) {
            dropText
            chooseButton
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var dropText: some View {
        HStack(spacing: 10) {
            Image(systemName: "waveform.badge.plus")
                .font(.title3)
                .foregroundStyle(.secondary)
                .frame(width: 24)

            VStack(alignment: .leading, spacing: 3) {
                Text("Drop audio files")
                    .font(.headline)
                    .lineLimit(1)
                Text("Processing starts automatically.")
                    .foregroundStyle(.secondary)
                    .font(.subheadline)
                    .lineLimit(1)
            }
        }
    }

    private var chooseButton: some View {
        Button {
            chooseFiles()
        } label: {
            Label("Choose Audio", systemImage: "plus")
                .labelStyle(.titleAndIcon)
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.regular)
    }
}

struct ImportRow: View {
    var item: ImportItem

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(item.displayTitle)
                    .font(.headline)
                    .lineLimit(1)
                HStack(spacing: 8) {
                    Text(DateFormatter.itemDate.string(from: item.recordingDate))
                    Text(item.workflow.label)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            Spacer()

            StatusPill(status: item.status)
        }
        .padding(.vertical, 6)
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

struct EmptyDetailView: View {
    var message = "No memo selected"

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "waveform")
                .font(.largeTitle)
                .foregroundStyle(.secondary)
            Text(message)
                .font(.headline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

extension View {
    @ViewBuilder
    func `if`<Content: View>(_ condition: Bool, transform: (Self) -> Content) -> some View {
        if condition {
            transform(self)
        } else {
            self
        }
    }
}
