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

    init() {
        ensureDirectories()
        loadSettings()
        loadItems()
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
        let managedURL = uniqueManagedAudioURL(for: sourceURL, recordingDate: recordingDate)

        do {
            try FileManager.default.copyItem(at: sourceURL, to: managedURL)
            var item = ImportItem(
                originalFilename: sourceURL.lastPathComponent,
                originalPath: sourceURL.path,
                managedAudioPath: managedURL.path,
                recordingDate: recordingDate,
                recordingDateIsCertain: certain,
                durationSeconds: duration,
                workflow: settings.defaultWorkflow,
                status: .queued
            )
            item.fileOperations.append(FileOperationRecord(
                kind: "copy",
                sourcePath: sourceURL.path,
                destinationPath: managedURL.path,
                occurredAt: Date()
            ))
            items.insert(item, at: 0)
            return item
        } catch {
            var item = ImportItem(
                originalFilename: sourceURL.lastPathComponent,
                originalPath: sourceURL.path,
                recordingDate: recordingDate,
                recordingDateIsCertain: certain,
                durationSeconds: duration,
                workflow: settings.defaultWorkflow,
                status: .needsAttention
            )
            item.error = ProcessingError(
                message: "Could not copy the audio file.",
                technicalDetails: error.localizedDescription,
                occurredAt: Date()
            )
            items.insert(item, at: 0)
            return item
        }
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

    private func ensureDirectories() {
        try? FileManager.default.createDirectory(at: AppPaths.applicationSupport, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: AppPaths.managedAudioDirectory, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: AppPaths.dropImportDirectory, withIntermediateDirectories: true)
    }

    private func uniqueManagedAudioURL(for sourceURL: URL, recordingDate: Date) -> URL {
        let ext = sourceURL.pathExtension.isEmpty ? "m4a" : sourceURL.pathExtension
        let base = "\(DateFormatter.filenameDate.string(from: recordingDate))_\(sourceURL.deletingPathExtension().lastPathComponent.slugSafe)"
        var candidate = AppPaths.managedAudioDirectory.appendingPathComponent(base).appendingPathExtension(ext)
        var counter = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = AppPaths.managedAudioDirectory.appendingPathComponent("\(base)-\(counter)").appendingPathExtension(ext)
            counter += 1
        }
        return candidate
    }

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
