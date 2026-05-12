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
    private var watchFolderTask: Task<Void, Never>?
    private var isScanningWatchFolders = false

    init() {
        ensureDirectories()
        loadSettings()
        loadItems()
        recoverInterruptedItems()
        migrateLegacyWorkflowReferences()
        backfillAudioFingerprints()
        startWatchFolderMonitoring()
    }

    func addItem(from sourceURL: URL) async -> ImportItem? {
        guard sourceURL.isFileURL else { return nil }
        let didAccessSecurityScopedResource = sourceURL.startAccessingSecurityScopedResource()
        defer {
            if didAccessSecurityScopedResource {
                sourceURL.stopAccessingSecurityScopedResource()
            }
        }
        guard AudioFileAccess.isSupportedAudioURL(sourceURL) else { return nil }
        if isKnownImport(sourceURL: sourceURL, fingerprint: nil) {
            return nil
        }

        var managedAudioURL: URL?
        var importError: ProcessingError?
        do {
            managedAudioURL = try AudioFileAccess.createManagedCopy(from: sourceURL)
        } catch {
            let failure = error as? ProcessingFailure
            importError = ProcessingError(
                message: failure?.message ?? "Could not prepare audio for import.",
                technicalDetails: failure?.details ?? error.localizedDescription,
                occurredAt: Date()
            )
        }

        let metadataURL = managedAudioURL ?? sourceURL
        let fingerprint = managedAudioURL.flatMap { try? AudioFingerprint.sha256(for: $0) }
        if isKnownImport(sourceURL: sourceURL, fingerprint: fingerprint) {
            if let managedAudioURL {
                try? FileManager.default.removeItem(at: managedAudioURL)
            }
            return nil
        }
        let (recordingDate, certain) = AudioInspector.recordingDate(for: metadataURL)
        let duration = await AudioInspector.duration(for: metadataURL)

        var item = ImportItem(
            originalFilename: sourceURL.lastPathComponent,
            originalPath: sourceURL.path,
            sourceFilename: sourceURL.lastPathComponent,
            sourcePath: sourceURL.path,
            audioFingerprint: fingerprint,
            managedAudioPath: managedAudioURL?.path,
            recordingDate: recordingDate,
            recordingDateIsCertain: certain,
            durationSeconds: duration,
            workflow: workflowForSource(sourceURL),
            status: importError == nil ? .queued : .needsAttention
        )
        if let managedAudioURL {
            item.fileOperations.append(FileOperationRecord(
                kind: "managed_processing_copy",
                sourcePath: sourceURL.path,
                destinationPath: managedAudioURL.path,
                occurredAt: Date()
            ))
        }
        item.error = importError
        items.insert(item, at: 0)
        return item
    }

    func update(_ item: ImportItem) {
        guard let index = items.firstIndex(where: { $0.id == item.id }) else { return }
        var updated = item
        updated.updatedAt = Date()
        items[index] = updated
        rememberImportedFingerprint(for: updated)
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
        guard !isScanningWatchFolders else { return }
        isScanningWatchFolders = true
        defer { isScanningWatchFolders = false }

        let policies = settings.workflows.filter(\.usesWatchFolder)
        guard !policies.isEmpty else { return }
        for policy in policies {
            let folder = URL(fileURLWithPath: NSString(string: policy.watchFolderPath).expandingTildeInPath)
            var options: FileManager.DirectoryEnumerationOptions = [.skipsHiddenFiles]
            if !policy.includeWatchFolderSubfolders {
                options.insert(.skipsSubdirectoryDescendants)
            }
            guard let enumerator = FileManager.default.enumerator(
                at: folder,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: options
            ) else { continue }
            let urls = enumerator.compactMap { $0 as? URL }
            for url in urls {
                guard AudioFileAccess.isSupportedAudioURL(url) else { continue }
                if let existing = existingItem(forSourceURL: url) {
                    if let prepared = await prepareUnavailableItem(existing, from: url, workflowID: policy.id) {
                        ImportProcessor(store: self).process(prepared.id)
                    }
                    continue
                }
                if var imported = await addItem(from: url) {
                    imported.workflow = policy.id
                    update(imported)
                    if imported.status == .queued {
                        ImportProcessor(store: self).process(imported.id)
                    }
                }
            }
        }
    }

    private func existingItem(forSourceURL sourceURL: URL) -> ImportItem? {
        items.first { item in
            item.originalPath == sourceURL.path || item.sourcePath == sourceURL.path
        }
    }

    private func prepareUnavailableItem(_ item: ImportItem, from sourceURL: URL, workflowID: String) async -> ImportItem? {
        guard item.status == .needsAttention, item.managedAudioPath == nil else { return nil }
        let managedAudioURL: URL
        do {
            managedAudioURL = try AudioFileAccess.createManagedCopy(from: sourceURL)
        } catch {
            let failure = error as? ProcessingFailure
            var updated = item
            updated.workflow = workflowID
            updated.error = ProcessingError(
                message: failure?.message ?? "Could not prepare audio for import.",
                technicalDetails: failure?.details ?? error.localizedDescription,
                occurredAt: Date()
            )
            update(updated)
            return nil
        }

        var updated = item
        updated.workflow = workflowID
        updated.managedAudioPath = managedAudioURL.path
        updated.audioFingerprint = try? AudioFingerprint.sha256(for: managedAudioURL)
        updated.durationSeconds = await AudioInspector.duration(for: managedAudioURL)
        updated.status = .queued
        updated.error = nil
        updated.fileOperations.append(FileOperationRecord(
            kind: "managed_processing_copy",
            sourcePath: sourceURL.path,
            destinationPath: managedAudioURL.path,
            occurredAt: Date()
        ))
        update(updated)
        return updated
    }

    private func isKnownImport(sourceURL: URL, fingerprint: String?) -> Bool {
        let knownFingerprint = fingerprint.map { settings.importedAudioFingerprints.contains($0) } ?? false
        return items.contains { item in
            item.originalPath == sourceURL.path
                || item.sourcePath == sourceURL.path
                || (fingerprint != nil && item.audioFingerprint == fingerprint)
        } || knownFingerprint
    }

    private func rememberImportedFingerprint(for item: ImportItem) {
        guard item.status == .imported, let fingerprint = item.audioFingerprint else { return }
        guard !settings.importedAudioFingerprints.contains(fingerprint) else { return }
        settings.importedAudioFingerprints.append(fingerprint)
        if settings.importedAudioFingerprints.count > 5_000 {
            settings.importedAudioFingerprints.removeFirst(settings.importedAudioFingerprints.count - 5_000)
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
        clearItems { $0.status == .imported }
    }

    func clearItems(where shouldClear: (ImportItem) -> Bool) {
        let clearedItems = items.filter(shouldClear)
        for item in clearedItems {
            processingTasks[item.id]?.cancel()
            processingTasks[item.id] = nil
            if let managedAudioPath = item.managedAudioPath {
                try? FileManager.default.removeItem(at: URL(fileURLWithPath: managedAudioPath))
            }
        }
        items.removeAll(where: shouldClear)
    }

    var hasActiveProcessing: Bool {
        items.contains { Self.activeStatuses.contains($0.status) }
    }

    private var shouldScanWatchFoldersAtLaunch: Bool {
        settings.checkWatchFoldersAtLaunch || settings.workflows.contains(where: \.usesWatchFolder)
    }

    private func startWatchFolderMonitoring() {
        guard watchFolderTask == nil else { return }
        watchFolderTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                if self.shouldScanWatchFoldersAtLaunch {
                    await self.scanWatchFolders()
                }
                try? await Task.sleep(nanoseconds: 20_000_000_000)
            }
        }
    }

    func appStorageUsage() -> Int64 {
        directorySize(AppPaths.processingCacheDirectory)
            + directorySize(AppPaths.managedAudioDirectory)
            + directorySize(AppPaths.dropImportDirectory)
    }

    func clearCache() {
        removeContents(of: AppPaths.processingCacheDirectory)
        removeContents(of: AppPaths.dropImportDirectory)
        for item in items where item.status == .imported {
            guard let path = item.managedAudioPath else { continue }
            try? FileManager.default.removeItem(at: URL(fileURLWithPath: path))
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
            isSource(sourceURL, inWatchFolderFor: policy)
        }?.id ?? settings.defaultWorkflow
    }

    private func isSource(_ sourceURL: URL, inWatchFolderFor policy: WorkflowPolicy) -> Bool {
        guard policy.usesWatchFolder else { return false }
        let folderPath = NSString(string: policy.watchFolderPath).expandingTildeInPath
        let standardizedFolderPath = URL(fileURLWithPath: folderPath).standardizedFileURL.path
        let standardizedSourceURL = sourceURL.standardizedFileURL
        let sourcePath = standardizedSourceURL.path

        if policy.includeWatchFolderSubfolders {
            return sourcePath == standardizedFolderPath
                || sourcePath.hasPrefix(standardizedFolderPath + "/")
        }
        return standardizedSourceURL.deletingLastPathComponent().path == standardizedFolderPath
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

    private func backfillAudioFingerprints() {
        var didChange = false
        for index in items.indices {
            if items[index].sourceFilename == nil {
                items[index].sourceFilename = items[index].originalFilename
                didChange = true
            }
            if items[index].sourcePath == nil {
                items[index].sourcePath = items[index].originalPath
                didChange = true
            }
            if items[index].audioFingerprint == nil,
               let url = existingAudioURL(for: items[index]),
               let fingerprint = try? AudioFingerprint.sha256(for: url) {
                items[index].audioFingerprint = fingerprint
                didChange = true
            }
            if items[index].status == .imported {
                rememberImportedFingerprint(for: items[index])
            }
        }
        if didChange {
            saveItems()
        }
    }

    private func recoverInterruptedItems() {
        var didChange = false
        for index in items.indices where Self.activeStatuses.contains(items[index].status) {
            let interruptedStatus = items[index].status
            items[index].status = .needsAttention
            items[index].error = ProcessingError(
                message: "Processing was interrupted.",
                technicalDetails: "The app closed or crashed while this item was \(interruptedStatus.label.lowercased()). Start it again when MacWhisper and LM Studio are ready.",
                occurredAt: Date()
            )
            didChange = true
        }
        if didChange {
            saveItems()
        }
    }

    private func existingAudioURL(for item: ImportItem) -> URL? {
        let paths = [item.originalPath, item.sourcePath, item.managedAudioPath].compactMap { $0 }
        for path in paths {
            if FileManager.default.fileExists(atPath: path) {
                return URL(fileURLWithPath: path)
            }
        }
        return nil
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
