import SwiftUI

struct ImportDetailView: View {
    @EnvironmentObject private var store: ImportStore
    @State private var selectedTab = "summary"
    @State private var showDetails = false
    var item: ImportItem

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(24)

            Divider()

            Picker("", selection: $selectedTab) {
                Text("Summary").tag("summary")
                Text("Transcript").tag("transcript")
            }
            .pickerStyle(.segmented)
            .padding([.horizontal, .top], 24)

            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    if selectedTab == "summary" {
                        summarySection
                    } else {
                        transcriptSection
                    }

                    DisclosureGroup("Technical details", isExpanded: $showDetails) {
                        technicalDetails
                            .padding(.top, 8)
                    }
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                }
                .padding(24)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 18) {
            VStack(alignment: .leading, spacing: 8) {
                Text(item.displayTitle)
                    .font(.system(size: 28, weight: .semibold))
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)

                HStack(spacing: 10) {
                    Text(DateFormatter.itemDate.string(from: item.recordingDate))
                    if let duration = item.durationSeconds {
                        Text(durationText(duration))
                    }
                    Text(item.originalFilename)
                }
                .font(.subheadline)
                .foregroundStyle(.secondary)
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 10) {
                StatusPill(status: item.status)
                primaryAction
            }
        }
    }

    @ViewBuilder
    private var primaryAction: some View {
        if let title = item.primaryActionTitle {
            Button {
                handlePrimaryAction()
            } label: {
                Label(title, systemImage: primaryActionIcon)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
        }
    }

    private var primaryActionIcon: String {
        switch item.status {
        case .readyForReview: "square.and.arrow.down"
        case .needsAttention, .failed: "arrow.clockwise"
        case .imported: "folder"
        default: "arrow.right"
        }
    }

    private var summarySection: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Summary")
                    .font(.headline)
                Text(item.analysis?.summary ?? placeholderText)
                    .font(.body)
                    .foregroundStyle(item.analysis == nil ? .secondary : .primary)
                    .textSelection(.enabled)
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("Destination")
                    .font(.headline)
                Picker("Destination", selection: workflowBinding) {
                    ForEach(WorkflowID.allCases) { workflow in
                        Text(workflow.label).tag(workflow)
                    }
                }
                .labelsHidden()
                .frame(maxWidth: 260)
            }

            if !item.recordingDateIsCertain {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Recording date")
                        .font(.headline)
                    DatePicker("Recording date", selection: recordingDateBinding)
                        .labelsHidden()
                        .frame(maxWidth: 260)
                    Text("Estimated from file metadata. Adjust it before importing if needed.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            if let themes = item.analysis?.themes, !themes.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Themes")
                        .font(.headline)
                    FlowLayout(items: themes)
                }
            }

            if let error = item.error {
                AttentionBox(error: error, item: item, showDetails: $showDetails)
            }
        }
    }

    private var transcriptSection: some View {
        Text(item.transcript ?? "Transcript will appear here after MacWhisper finishes.")
            .font(.body.monospaced())
            .foregroundStyle(item.transcript == nil ? .secondary : .primary)
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var technicalDetails: some View {
        VStack(alignment: .leading, spacing: 8) {
            DetailLine(label: "Original", value: item.originalPath)
            DetailLine(label: "Managed audio", value: item.managedAudioPath ?? "Not copied")
            DetailLine(label: "Slug", value: item.analysis?.slug ?? "Not analyzed")
            DetailLine(label: "Short slug", value: item.analysis?.shortSlug ?? "Not analyzed")
            DetailLine(label: "Recording date", value: item.recordingDateIsCertain ? "Certain" : "Estimated")
            if let exported = item.exportedMarkdownPath {
                DetailLine(label: "Monthly note", value: exported)
            }
            if let error = item.error {
                DetailLine(label: "Last error", value: error.technicalDetails)
            }
        }
    }

    private var workflowBinding: Binding<WorkflowID> {
        Binding {
            item.workflow
        } set: { workflow in
            var updated = item
            updated.workflow = workflow
            store.update(updated)
        }
    }

    private var recordingDateBinding: Binding<Date> {
        Binding {
            item.recordingDate
        } set: { date in
            var updated = item
            updated.recordingDate = date
            updated.recordingDateIsCertain = true
            store.update(updated)
        }
    }

    private var placeholderText: String {
        switch item.status {
        case .queued, .transcribing, .analyzing:
            "Processing is running."
        case .needsAttention, .failed:
            item.error?.message ?? "This memo needs attention."
        default:
            "No summary yet."
        }
    }

    private func handlePrimaryAction() {
        switch item.status {
        case .readyForReview:
            ImportProcessor(store: store).export(item.id)
        case .needsAttention, .failed:
            ImportProcessor(store: store).process(item.id)
        case .imported:
            Finder.reveal(item.exportedMarkdownPath ?? item.managedAudioPath)
        default:
            break
        }
    }

    private func durationText(_ duration: Double) -> String {
        let total = Int(duration.rounded())
        return "\(total / 60)m \(total % 60)s"
    }
}

struct AttentionBox: View {
    var error: ProcessingError
    var item: ImportItem
    @Binding var showDetails: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(error.message)
                .font(.headline)
            HStack {
                Button("Open in Finder") {
                    Finder.reveal(item.managedAudioPath ?? item.originalPath)
                }
                Button("Show technical details") {
                    showDetails = true
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.red.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}

struct DetailLine: View {
    var label: String
    var value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.caption.monospaced())
                .textSelection(.enabled)
        }
    }
}

struct FlowLayout: View {
    var items: [String]

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 96), spacing: 8)], alignment: .leading, spacing: 8) {
            ForEach(items, id: \.self) { item in
                Text(item)
                    .font(.caption)
                    .lineLimit(1)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .background(Color(nsColor: .controlBackgroundColor))
                    .clipShape(Capsule())
            }
        }
    }
}
