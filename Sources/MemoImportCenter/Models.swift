import Foundation

enum ImportStatus: String, Codable, CaseIterable, Identifiable {
    case new
    case queued
    case transcribing
    case transcribed
    case analyzing
    case readyForReview
    case importing
    case imported
    case failed
    case needsAttention

    var id: String { rawValue }

    var label: String {
        switch self {
        case .new: "New"
        case .queued: "Queued"
        case .transcribing: "Transcribing"
        case .transcribed: "Transcribed"
        case .analyzing: "Analyzing"
        case .readyForReview: "To Review"
        case .importing: "Importing"
        case .imported: "Imported"
        case .failed: "Failed"
        case .needsAttention: "Attention"
        }
    }
}

enum WorkflowID: String, Codable, CaseIterable, Identifiable {
    case obsidianJournal
    case obsidianInbox
    case projectFolder
    case fieldRecordingLibrary
    case renameInPlace

    var id: String { rawValue }

    var label: String {
        switch self {
        case .obsidianJournal: "Obsidian Journal"
        case .obsidianInbox: "Obsidian Inbox"
        case .projectFolder: "Project Folder"
        case .fieldRecordingLibrary: "Field Recording Library"
        case .renameInPlace: "Rename in Place"
        }
    }
}

struct AnalysisMetadata: Codable, Equatable {
    var title: String
    var slug: String
    var shortSlug: String
    var summary: String
    var themes: [String]
    var mood: String?
    var suggestedWorkflow: WorkflowID?
}

struct ProcessingError: Codable, Equatable {
    var message: String
    var technicalDetails: String
    var occurredAt: Date
}

struct FileOperationRecord: Codable, Identifiable, Equatable {
    var id = UUID()
    var kind: String
    var sourcePath: String
    var destinationPath: String
    var occurredAt: Date
}

struct ImportItem: Codable, Identifiable, Equatable {
    var id = UUID()
    var createdAt = Date()
    var updatedAt = Date()
    var originalFilename: String
    var originalPath: String
    var managedAudioPath: String?
    var recordingDate: Date
    var recordingDateIsCertain: Bool
    var durationSeconds: Double?
    var transcript: String?
    var analysis: AnalysisMetadata?
    var workflow: WorkflowID = .obsidianJournal
    var status: ImportStatus = .new
    var retryCount = 0
    var importedAt: Date?
    var exportedMarkdownPath: String?
    var error: ProcessingError?
    var fileOperations: [FileOperationRecord] = []

    var displayTitle: String {
        if let title = analysis?.title, !title.isEmpty {
            return title
        }
        return (originalFilename as NSString).deletingPathExtension
    }

    var primaryActionTitle: String? {
        switch status {
        case .readyForReview:
            return "Import to Journal"
        case .failed, .needsAttention:
            return "Try Again"
        case .imported:
            return "Show in Finder"
        default:
            return nil
        }
    }
}

struct AppSettings: Codable, Equatable {
    var macWhisperPath = "/usr/local/bin/mw"
    var lmStudioBaseURL = "http://localhost:1234/v1"
    var vaultRootPath = "\(NSHomeDirectory())/Library/Mobile Documents/iCloud~md~obsidian/Documents/Notes"
    var voiceInboxRelativePath = "📮INBOX/📻 VOICE INBOX"
    var journalAudioRelativePath = "🖋️ Journal/Audio"
    var monthlyNotesRelativePath = "🖋️ Journal"
    var defaultWorkflow: WorkflowID = .obsidianJournal
    var maxTranscriptCharactersForAnalysis = 24000
    var transcriptionTimeoutSeconds = 900
    var retryLimit = 2
}
