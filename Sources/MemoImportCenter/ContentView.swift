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
        NavigationSplitView {
            List(NavigationSection.allCases, selection: $selection) { section in
                Label(section.label, systemImage: section.icon)
                    .badge(count(for: section))
                    .tag(section)
            }
            .navigationTitle("Memo Import")
            .navigationSplitViewColumnWidth(min: 190, ideal: 210)
        } detail: {
            mainContent
        }
        .onChange(of: selection) { _ in
            selectedItemID = filteredItems.first?.id
        }
        .onAppear {
            selectedItemID = filteredItems.first?.id
        }
    }

    @ViewBuilder
    private var mainContent: some View {
        if selection == .settings {
            SettingsView()
        } else {
            HSplitView {
                ImportListView(
                    title: selection.label,
                    showsImportHeader: selection == .toReview,
                    emptyMessage: emptyMessage,
                    items: filteredItems,
                    selectedItemID: $selectedItemID
                )
                .frame(minWidth: 380, idealWidth: 440, maxWidth: 560)

                if let selectedItemID, let item = store.item(id: selectedItemID) {
                    ImportDetailView(item: item)
                        .frame(minWidth: 520)
                } else {
                    EmptyDetailView(message: emptyMessage)
                        .frame(minWidth: 520)
                }
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
                VStack(spacing: 10) {
                    Image(systemName: "tray")
                        .font(.title)
                        .foregroundStyle(.secondary)
                    Text(emptyMessage)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(items, selection: $selectedItemID) { item in
                    ImportRow(item: item)
                        .tag(item.id)
                }
                .listStyle(.inset)
            }
        }
        .background(Color(nsColor: .textBackgroundColor))
        .if(showsImportHeader) { view in
            view.onDrop(of: supportedTypes, isTargeted: $isTargeted) { providers in
                handleDrop(providers)
            }
        }
    }

    private var supportedTypes: [UTType] {
        [.audio, .mpeg4Audio, .mp3, .wav, .fileURL]
    }

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        for provider in providers {
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                guard let data = item as? Data,
                      let url = URL(dataRepresentation: data, relativeTo: nil) else { return }
                Task { @MainActor in
                    if let imported = await store.addItem(from: url) {
                        selectedItemID = imported.id
                        ImportProcessor(store: store).process(imported.id)
                    }
                }
            }
        }
        return true
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
