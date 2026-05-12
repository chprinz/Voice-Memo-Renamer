import Foundation
import SwiftUI

@MainActor
final class ImportStore: ObservableObject {
    @Published var items: [ImportItem] = [] {
        didSet { saveItems() }
    }

    @Published var settings = AppSettings() {
        didSet { saveSettings() }
    }

    private var processingTasks: [ImportItem.ID: Task<Void, Never>] = [:]

    init() {
        ensureDirectories()
        loadSettings()
        loadItems()
        migrateLegacyWorkflowReferences()
        if settings.checkWatchFoldersAtLaunch {
            Task { await scanWatchFolders() }
        }
    }

    func addItem(from sourceURL: URL) async -> ImportItem? {
        guard sourceURL.isFileURL else { return nil }
        let didAccessSecurityScopedResource = sourceURL.startAccessingSecurityScopedResource()
        defer {
            if didAccessSecurityScopedResource {
                sourceURL.stopAccessingSecurityScopedResource()
            }
        }
        let (recordingDate, certain) = AudioInspector.recordingDate(for: sourceURL)
        let duration = await AudioInspector.duration(for: sourceURL)

        let item = ImportItem(
            originalFilename: sourceURL.lastPathComponent,
            originalPath: sourceURL.path,
            managedAudioPath: nil,
            recordingDate: recordingDate,
            recordingDateIsCertain: certain,
            durationSeconds: duration,
            workflow: workflowForSource(sourceURL),
            status: .queued
        )
        items.insert(item, at: 0)
        return item
    }

    func update(_ item: ImportItem) {
        guard let index = items.firstIndex(where: { $0.id == item.id }) else { return }
        var updated = item
        updated.updatedAt = Date()
        items[index] = updated
    }

    func item(id: ImportItem.ID) -> ImportItem? {
        items.first(where: { $0.id == id })
    }

    func workflowPolicy(for workflow: String) -> WorkflowPolicy {
        settings.policy(for: workflow)
    }

    func setDefaultWorkflow(_ workflow: String) {
        settings.defaultWorkflow = workflow
    }

    func updateWorkflow(_ policy: WorkflowPolicy) {
        var policy = policy
        policy.id = WorkflowPolicy.canonicalID(policy.id)
        if let index = settings.workflows.firstIndex(where: { $0.id == policy.id }) {
            settings.workflows[index] = policy
        } else {
            settings.workflows.append(policy)
        }
        if policy.isEnabled, policy.id == settings.defaultWorkflow {
            settings.processingStoragePolicy = policy.processingStoragePolicy
        }
    }

    func addWorkflow() -> WorkflowPolicy {
        var workflow = WorkflowPolicy(
            id: "workflow-\(UUID().uuidString)",
            name: "New Workflow",
            isEnabled: true,
            sourceBehavior: .manualOnly,
            watchFolderPath: "",
            destination: .projectFolder,
            destinationPath: "",
            audioDestinationPath: "",
            transcriptBehavior: .createMarkdownFile,
            audioFileBehavior: .leaveInPlace,
            reviewBehavior: .requireReview,
            filenamePattern: WorkflowPolicy.defaultFilenamePattern,
            processingStoragePolicy: .deleteAfterSuccessfulExport
        )
        var suffix = 2
        while settings.workflows.contains(where: { $0.name == workflow.name }) {
            workflow.name = "New Workflow \(suffix)"
            suffix += 1
        }
        settings.workflows.append(workflow)
        return workflow
    }

    func deleteWorkflow(id: String) {
        guard settings.workflows.count > 1 else { return }
        settings.workflows.removeAll { $0.id == id }
        if settings.defaultWorkflow == id {
            settings.defaultWorkflow = settings.workflows.first?.id ?? StandardWorkflowID.obsidianJournal
        }
        for index in items.indices where items[index].workflow == id {
            items[index].workflow = settings.defaultWorkflow
        }
    }

    func scanWatchFolders() async {
        let policies = settings.workflows.filter(\.usesWatchFolder)
        guard !policies.isEmpty else { return }
        for policy in policies {
            let folder = URL(fileURLWithPath: NSString(string: policy.watchFolderPath).expandingTildeInPath)
            guard let enumerator = FileManager.default.enumerator(
                at: folder,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles]
            ) else { continue }
            let urls = enumerator.compactMap { $0 as? URL }
            for url in urls {
                guard Self.supportedAudioExtensions.contains(url.pathExtension.lowercased()) else { continue }
                guard !items.contains(where: { $0.originalPath == url.path }) else { continue }
                if var imported = await addItem(from: url) {
                    imported.workflow = policy.id
                    imported.status = .new
                    update(imported)
                }
            }
        }
    }

    func registerProcessingTask(_ task: Task<Void, Never>, for id: ImportItem.ID) {
        processingTasks[id]?.cancel()
        processingTasks[id] = task
    }

    func finishProcessingTask(for id: ImportItem.ID) {
        processingTasks[id] = nil
    }

    func cancelProcessing(_ id: ImportItem.ID) {
        processingTasks[id]?.cancel()
        processingTasks[id] = nil
        guard var item = item(id: id), Self.activeStatuses.contains(item.status) else { return }
        item.status = .needsAttention
        item.error = ProcessingError(
            message: "Processing cancelled.",
            technicalDetails: "Cancelled by the user before the workflow finished.",
            occurredAt: Date()
        )
        update(item)
    }

    func cancelActiveProcessing() {
        for id in items.filter({ Self.activeStatuses.contains($0.status) }).map(\.id) {
            cancelProcessing(id)
        }
    }

    func clearCompletedItems() {
        items.removeAll { $0.status == .imported }
    }

    var hasActiveProcessing: Bool {
        items.contains { Self.activeStatuses.contains($0.status) }
    }

    func appStorageUsage() -> Int64 {
        directorySize(AppPaths.processingCacheDirectory)
            + directorySize(AppPaths.managedAudioDirectory)
            + directorySize(AppPaths.dropImportDirectory)
    }

    func clearCache() {
        removeContents(of: AppPaths.processingCacheDirectory)
        removeContents(of: AppPaths.managedAudioDirectory)
        removeContents(of: AppPaths.dropImportDirectory)
        for item in items where item.status == .imported {
            guard let path = item.managedAudioPath else { continue }
            var updated = item
            updated.managedAudioPath = nil
            updated.fileOperations.append(FileOperationRecord(
                kind: "clear_cache",
                sourcePath: path,
                destinationPath: "",
                occurredAt: Date()
            ))
            update(updated)
        }
    }

    private func ensureDirectories() {
        try? FileManager.default.createDirectory(at: AppPaths.applicationSupport, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: AppPaths.processingCacheDirectory, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: AppPaths.managedAudioDirectory, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: AppPaths.dropImportDirectory, withIntermediateDirectories: true)
    }

    private func workflowForSource(_ sourceURL: URL) -> String {
        settings.workflows.first { policy in
            policy.usesWatchFolder && sourceURL.path.hasPrefix(NSString(string: policy.watchFolderPath).expandingTildeInPath)
        }?.id ?? settings.defaultWorkflow
    }

    private func migrateLegacyWorkflowReferences() {
        var didChange = false
        let migratedDefault = WorkflowPolicy.canonicalID(settings.defaultWorkflow)
        if settings.defaultWorkflow != migratedDefault || !settings.workflows.contains(where: { $0.id == migratedDefault }) {
            settings.defaultWorkflow = settings.workflows.contains(where: { $0.id == migratedDefault })
                ? migratedDefault
                : StandardWorkflowID.obsidianJournal
            didChange = true
        }

        for index in items.indices {
            let migratedID = WorkflowPolicy.canonicalID(items[index].workflow)
            if items[index].workflow != migratedID || !settings.workflows.contains(where: { $0.id == migratedID }) {
                items[index].workflow = settings.workflows.contains(where: { $0.id == migratedID })
                    ? migratedID
                    : settings.defaultWorkflow
                didChange = true
            }
        }

        if didChange {
            saveSettings()
            saveItems()
        }
    }

    private func directorySize(_ url: URL) -> Int64 {
        guard let enumerator = FileManager.default.enumerator(
            at: url,
            includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else { return 0 }
        var total: Int64 = 0
        for case let fileURL as URL in enumerator {
            let values = try? fileURL.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            if values?.isRegularFile == true {
                total += Int64(values?.fileSize ?? 0)
            }
        }
        return total
    }

    private func removeContents(of directory: URL) {
        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        ) else { return }
        for url in contents {
            try? FileManager.default.removeItem(at: url)
        }
    }

    private static let supportedAudioExtensions = Set(["m4a", "mp3", "wav", "aiff", "aif", "caf", "mp4", "mov"])
    private static let activeStatuses: Set<ImportStatus> = [.queued, .transcribing, .transcribed, .analyzing, .importing]

    private func loadItems() {
        guard let data = try? Data(contentsOf: AppPaths.storeURL) else { return }
        items = (try? JSONDecoder.appDecoder.decode([ImportItem].self, from: data)) ?? []
    }

    private func saveItems() {
        ensureDirectories()
        guard let data = try? JSONEncoder.appEncoder.encode(items) else { return }
        try? data.write(to: AppPaths.storeURL, options: [.atomic])
    }

    private func loadSettings() {
        guard let data = try? Data(contentsOf: AppPaths.settingsURL),
              let decoded = try? JSONDecoder.appDecoder.decode(AppSettings.self, from: data) else { return }
        settings = decoded
    }

    private func saveSettings() {
        ensureDirectories()
        guard let data = try? JSONEncoder.appEncoder.encode(settings) else { return }
        try? data.write(to: AppPaths.settingsURL, options: [.atomic])
    }
}

extension JSONEncoder {
    static var appEncoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }
}

extension JSONDecoder {
    static var appDecoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
