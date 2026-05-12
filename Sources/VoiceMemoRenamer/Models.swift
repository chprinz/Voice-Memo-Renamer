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

enum StandardWorkflowID {
    static let obsidianJournal = "obsidianJournal"
    static let obsidianInbox = "obsidianInbox"
    static let transcriptOnly = "transcriptOnly"
    static let renameInPlace = "renameInPlace"
}

enum SourceBehavior: String, Codable, CaseIterable, Identifiable {
    case manualOnly
    case watchFolder
    case manualAndWatchFolder

    var id: String { rawValue }

    var label: String {
        switch self {
        case .manualOnly: "Manual only"
        case .watchFolder: "Watch folder"
        case .manualAndWatchFolder: "Manual + Watch folder"
        }
    }

    var usesWatchFolder: Bool {
        self == .watchFolder || self == .manualAndWatchFolder
    }
}

enum WorkflowDestination: String, Codable, CaseIterable, Identifiable {
    case obsidianJournal
    case obsidianInbox
    case projectFolder
    case sameFolder
    case archiveFolder

    var id: String { rawValue }

    var label: String {
        switch self {
        case .obsidianJournal: "Obsidian Journal"
        case .obsidianInbox: "Obsidian Inbox"
        case .projectFolder: "Custom Folder"
        case .sameFolder: "Same Folder"
        case .archiveFolder: "Archive Folder"
        }
    }
}

enum TranscriptBehavior: String, Codable, CaseIterable, Identifiable {
    case appendToMonthlyNote
    case createMarkdownFile
    case saveTranscriptOnly
    case doNotExportTranscript

    var id: String { rawValue }

    var label: String {
        switch self {
        case .appendToMonthlyNote: "Append to monthly note"
        case .createMarkdownFile: "Create markdown file"
        case .saveTranscriptOnly: "Save transcript only"
        case .doNotExportTranscript: "Do not export transcript"
        }
    }
}

enum AudioBehavior: String, Codable, CaseIterable, Identifiable {
    case copyAudioToDestination
    case moveAudioToDestination
    case doNotExportAudio
    case linkExistingAudio

    var id: String { rawValue }

    var label: String {
        switch self {
        case .copyAudioToDestination: "Copy audio to destination"
        case .moveAudioToDestination: "Move audio to destination"
        case .doNotExportAudio: "Do not export audio"
        case .linkExistingAudio: "Link existing audio where possible"
        }
    }
}

enum OriginalBehavior: String, Codable, CaseIterable, Identifiable {
    case keepOriginal
    case archiveOriginal
    case renameOriginalInPlace
    case neverDeleteAutomatically

    var id: String { rawValue }

    var label: String {
        switch self {
        case .keepOriginal: "Keep original"
        case .archiveOriginal: "Archive original"
        case .renameOriginalInPlace: "Rename original in place"
        case .neverDeleteAutomatically: "Never delete automatically"
        }
    }
}

enum ReviewBehavior: String, Codable, CaseIterable, Identifiable {
    case autoExportWhenReady
    case requireReview
    case requireReviewWhenUncertain

    var id: String { rawValue }

    var label: String {
        switch self {
        case .autoExportWhenReady: "Auto-export when ready"
        case .requireReview: "Require review"
        case .requireReviewWhenUncertain: "Require review only when date/title/path is uncertain"
        }
    }
}

enum ProcessingStoragePolicy: String, Codable, CaseIterable, Identifiable {
    case deleteAfterSuccessfulExport
    case keepForSevenDays
    case keepUntilManuallyCleared
    case keepPermanently

    var id: String { rawValue }

    var label: String {
        switch self {
        case .deleteAfterSuccessfulExport: "Delete processing copy after successful export"
        case .keepForSevenDays: "Keep processing copy for 7 days"
        case .keepUntilManuallyCleared: "Keep until manually cleared"
        case .keepPermanently: "Keep permanently"
        }
    }
}

struct WorkflowPolicy: Codable, Identifiable, Equatable {
    var id: String
    var name: String
    var isEnabled: Bool
    var sourceBehavior: SourceBehavior
    var watchFolderPath: String
    var destination: WorkflowDestination
    var destinationPath: String
    var audioDestinationPath: String
    var transcriptBehavior: TranscriptBehavior
    var audioBehavior: AudioBehavior
    var originalBehavior: OriginalBehavior
    var reviewBehavior: ReviewBehavior
    var filenamePattern: String
    var processingStoragePolicy: ProcessingStoragePolicy

    var usesWatchFolder: Bool {
        isEnabled && sourceBehavior.usesWatchFolder && !watchFolderPath.isEmpty
    }
}

struct AnalysisMetadata: Codable, Equatable {
    var title: String
    var slug: String
    var shortSlug: String
    var summary: String
    var themes: [String]
    var mood: String?
    var suggestedWorkflow: String?
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
    var workflow: String = StandardWorkflowID.obsidianJournal
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
        case .new:
            return "Start"
        case .readyForReview:
            return "Approve"
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
    var lmStudioModelID: String?
    var vaultRootPath = "\(NSHomeDirectory())/Library/Mobile Documents/iCloud~md~obsidian/Documents/Notes"
    var voiceInboxRelativePath = "📮INBOX/📻 VOICE INBOX"
    var journalAudioRelativePath = "🖋️ Journal/Audio"
    var monthlyNotesRelativePath = "🖋️ Journal"
    var defaultWorkflow: String = StandardWorkflowID.obsidianJournal
    var workflows: [WorkflowPolicy] = WorkflowPolicy.defaults
    var maxTranscriptCharactersForAnalysis = 24000
    var transcriptionTimeoutSeconds = 900
    var retryLimit = 2
    var processingStoragePolicy: ProcessingStoragePolicy = .deleteAfterSuccessfulExport
    var checkWatchFoldersAtLaunch = false
    var jprWatchFolderPath = "\(NSHomeDirectory())/Library/Mobile Documents/iCloud~com~openplanetsoftware~just-press-record/Documents"
    var archiveRelativePath = "📦 Archive/Voice Memos"

    enum CodingKeys: String, CodingKey {
        case macWhisperPath
        case lmStudioBaseURL
        case lmStudioModelID
        case vaultRootPath
        case voiceInboxRelativePath
        case journalAudioRelativePath
        case monthlyNotesRelativePath
        case defaultWorkflow
        case workflows
        case maxTranscriptCharactersForAnalysis
        case transcriptionTimeoutSeconds
        case retryLimit
        case processingStoragePolicy
        case checkWatchFoldersAtLaunch
        case jprWatchFolderPath
        case archiveRelativePath
    }

    init() {}

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        macWhisperPath = try container.decodeIfPresent(String.self, forKey: .macWhisperPath) ?? macWhisperPath
        lmStudioBaseURL = try container.decodeIfPresent(String.self, forKey: .lmStudioBaseURL) ?? lmStudioBaseURL
        lmStudioModelID = try container.decodeIfPresent(String.self, forKey: .lmStudioModelID)
        vaultRootPath = try container.decodeIfPresent(String.self, forKey: .vaultRootPath) ?? vaultRootPath
        voiceInboxRelativePath = try container.decodeIfPresent(String.self, forKey: .voiceInboxRelativePath) ?? voiceInboxRelativePath
        journalAudioRelativePath = try container.decodeIfPresent(String.self, forKey: .journalAudioRelativePath) ?? journalAudioRelativePath
        monthlyNotesRelativePath = try container.decodeIfPresent(String.self, forKey: .monthlyNotesRelativePath) ?? monthlyNotesRelativePath
        defaultWorkflow = WorkflowPolicy.canonicalID(
            try container.decodeIfPresent(String.self, forKey: .defaultWorkflow) ?? defaultWorkflow
        )
        workflows = try container.decodeIfPresent([WorkflowPolicy].self, forKey: .workflows) ?? WorkflowPolicy.defaults
        workflows = workflows.map { policy in
            var migrated = policy
            migrated.id = WorkflowPolicy.canonicalID(policy.id)
            migrated.name = WorkflowPolicy.canonicalName(for: migrated.id, currentName: migrated.name)
            return migrated
        }
        maxTranscriptCharactersForAnalysis = try container.decodeIfPresent(Int.self, forKey: .maxTranscriptCharactersForAnalysis) ?? maxTranscriptCharactersForAnalysis
        transcriptionTimeoutSeconds = try container.decodeIfPresent(Int.self, forKey: .transcriptionTimeoutSeconds) ?? transcriptionTimeoutSeconds
        retryLimit = try container.decodeIfPresent(Int.self, forKey: .retryLimit) ?? retryLimit
        processingStoragePolicy = try container.decodeIfPresent(ProcessingStoragePolicy.self, forKey: .processingStoragePolicy) ?? processingStoragePolicy
        checkWatchFoldersAtLaunch = try container.decodeIfPresent(Bool.self, forKey: .checkWatchFoldersAtLaunch) ?? false
        jprWatchFolderPath = try container.decodeIfPresent(String.self, forKey: .jprWatchFolderPath) ?? jprWatchFolderPath
        archiveRelativePath = try container.decodeIfPresent(String.self, forKey: .archiveRelativePath) ?? archiveRelativePath
        WorkflowPolicy.defaults.forEach { fallback in
            if !workflows.contains(where: { $0.id == fallback.id }) {
                workflows.append(fallback)
            }
        }
        if !workflows.contains(where: { $0.id == defaultWorkflow }) {
            defaultWorkflow = StandardWorkflowID.obsidianJournal
        }
    }

    func policy(for workflow: String) -> WorkflowPolicy {
        let canonicalID = WorkflowPolicy.canonicalID(workflow)
        if let policy = workflows.first(where: { $0.id == canonicalID }) {
            return policy
        }
        if let policy = WorkflowPolicy.defaults.first(where: { $0.id == canonicalID }) {
            return policy
        }
        return workflows.first ?? WorkflowPolicy.defaults[0]
    }
}

extension WorkflowPolicy {
    static let defaultFilenamePattern = "{yyyy}-{MM}-{dd}_{HH}-{mm}_{shortSlug}"

    static func canonicalID(_ id: String) -> String {
        switch id {
        case "projectFolder":
            return StandardWorkflowID.transcriptOnly
        case "fieldRecordingLibrary":
            return StandardWorkflowID.obsidianInbox
        default:
            return id
        }
    }

    static func canonicalName(for id: String, currentName: String) -> String {
        switch id {
        case StandardWorkflowID.obsidianJournal:
            return "Obsidian Journal"
        case StandardWorkflowID.obsidianInbox:
            return "Obsidian Inbox"
        case StandardWorkflowID.transcriptOnly:
            return "Transcript Only"
        case StandardWorkflowID.renameInPlace:
            return "Rename in Place"
        default:
            return currentName
        }
    }

    static let defaults: [WorkflowPolicy] = [
        WorkflowPolicy(
            id: StandardWorkflowID.obsidianJournal,
            name: "Obsidian Journal",
            isEnabled: true,
            sourceBehavior: .manualOnly,
            watchFolderPath: "\(NSHomeDirectory())/Library/Mobile Documents/iCloud~com~openplanetsoftware~just-press-record/Documents",
            destination: .obsidianJournal,
            destinationPath: "🖋️ Journal",
            audioDestinationPath: "🖋️ Journal/Audio",
            transcriptBehavior: .appendToMonthlyNote,
            audioBehavior: .copyAudioToDestination,
            originalBehavior: .keepOriginal,
            reviewBehavior: .requireReview,
            filenamePattern: defaultFilenamePattern,
            processingStoragePolicy: .deleteAfterSuccessfulExport
        ),
        WorkflowPolicy(
            id: StandardWorkflowID.obsidianInbox,
            name: "Obsidian Inbox",
            isEnabled: true,
            sourceBehavior: .manualOnly,
            watchFolderPath: "",
            destination: .obsidianInbox,
            destinationPath: "📮INBOX/📻 VOICE INBOX",
            audioDestinationPath: "",
            transcriptBehavior: .createMarkdownFile,
            audioBehavior: .doNotExportAudio,
            originalBehavior: .keepOriginal,
            reviewBehavior: .requireReview,
            filenamePattern: "{date}_{time}_{source}_{slug}",
            processingStoragePolicy: .deleteAfterSuccessfulExport
        ),
        WorkflowPolicy(
            id: StandardWorkflowID.transcriptOnly,
            name: "Transcript Only",
            isEnabled: true,
            sourceBehavior: .manualOnly,
            watchFolderPath: "",
            destination: .projectFolder,
            destinationPath: "",
            audioDestinationPath: "",
            transcriptBehavior: .createMarkdownFile,
            audioBehavior: .doNotExportAudio,
            originalBehavior: .keepOriginal,
            reviewBehavior: .requireReview,
            filenamePattern: defaultFilenamePattern,
            processingStoragePolicy: .deleteAfterSuccessfulExport
        ),
        WorkflowPolicy(
            id: StandardWorkflowID.renameInPlace,
            name: "Rename in Place",
            isEnabled: true,
            sourceBehavior: .manualOnly,
            watchFolderPath: "",
            destination: .sameFolder,
            destinationPath: "",
            audioDestinationPath: "",
            transcriptBehavior: .doNotExportTranscript,
            audioBehavior: .linkExistingAudio,
            originalBehavior: .renameOriginalInPlace,
            reviewBehavior: .requireReview,
            filenamePattern: defaultFilenamePattern,
            processingStoragePolicy: .keepUntilManuallyCleared
        )
    ]
}
