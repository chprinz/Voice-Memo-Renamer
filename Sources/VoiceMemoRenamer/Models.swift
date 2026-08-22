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
        case .readyForReview: "Review"
        case .importing: "Importing"
        case .imported: "Imported"
        case .failed: "Failed"
        case .needsAttention: "Needs attention"
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

enum WorkflowDestination: String, Codable {
    case obsidianJournal
    case obsidianInbox
    case projectFolder
    case sameFolder
    case archiveFolder
}

enum TranscriptBehavior: String, Codable, CaseIterable, Identifiable {
    case appendToMonthlyNote
    case createMarkdownFile
    case saveTranscriptOnly
    case doNotExportTranscript

    var id: String { rawValue }

    var label: String {
        switch self {
        case .appendToMonthlyNote: "Append to periodic note"
        case .createMarkdownFile: "Create separate note"
        case .saveTranscriptOnly: "Save transcript only"
        case .doNotExportTranscript: "Write no note"
        }
    }
}

enum NotePeriod: String, Codable, CaseIterable, Identifiable {
    case daily
    case weekly
    case monthly

    var id: String { rawValue }

    var label: String {
        switch self {
        case .daily: "Daily"
        case .weekly: "Weekly"
        case .monthly: "Monthly"
        }
    }

    var dateFormatter: DateFormatter {
        switch self {
        case .daily: .compactDate
        case .weekly: .weeklyNote
        case .monthly: .monthlyNote
        }
    }
}

enum NoteLinkStyle: String, Codable, CaseIterable, Identifiable {
    case wikilink
    case markdown

    var id: String { rawValue }

    var label: String {
        switch self {
        case .wikilink: "Obsidian wikilink"
        case .markdown: "Standard audio tag"
        }
    }

    func audioEmbed(_ filename: String) -> String {
        switch self {
        case .wikilink: "![[\(filename)]]"
        case .markdown: "<audio controls src=\"\(filename)\"></audio>"
        }
    }

    /// For audio that was never copied into the note's folder (Leave in place /
    /// Rename in place): a wikilink can't be trusted to resolve, since Obsidian
    /// finds it by searching the whole vault by filename, and the file may not
    /// even be inside the vault. The absolute path always works instead.
    static func remoteAudioEmbed(absolutePath: String) -> String {
        let url = URL(fileURLWithPath: absolutePath)
        return "<audio controls src=\"\(url.absoluteString)\"></audio>"
    }
}

enum AudioFileBehavior: String, Codable, CaseIterable, Identifiable {
    case leaveInPlace
    case copyToFolder
    case moveToFolder
    case renameInPlace

    var id: String { rawValue }

    var label: String {
        switch self {
        case .leaveInPlace: "Leave where it is"
        case .copyToFolder: "Copy to folder"
        case .moveToFolder: "Move to folder"
        case .renameInPlace: "Rename in place"
        }
    }
}

private enum LegacyAudioBehavior: String, Codable {
    case copyAudioToDestination
    case moveAudioToDestination
    case doNotExportAudio
    case linkExistingAudio
}

private enum LegacyOriginalBehavior: String, Codable {
    case keepOriginal
    case archiveOriginal
    case renameOriginalInPlace
    case neverDeleteAutomatically
}

enum ReviewBehavior: String, Codable, CaseIterable, Identifiable {
    case autoExportWhenReady
    case requireReview
    case requireReviewWhenUncertain

    var id: String { rawValue }

    var label: String {
        switch self {
        case .autoExportWhenReady: "Import automatically"
        case .requireReview: "Always review first"
        case .requireReviewWhenUncertain: "Review only when something is uncertain"
        }
    }
}

enum SummaryStyle: String, Codable, CaseIterable, Identifiable {
    case sentence
    case bullets
    case none

    var id: String { rawValue }

    var label: String {
        switch self {
        case .sentence: "One sentence"
        case .bullets: "Bullet points"
        case .none: "No summary"
        }
    }
}

enum RecordingDateSource: String, Codable {
    case fileMetadata
    case transcript
    case manual

    var label: String {
        switch self {
        case .fileMetadata: "From file metadata"
        case .transcript: "Spoken in the recording"
        case .manual: "Set by you"
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
        case .deleteAfterSuccessfulExport: "Until the recording is imported"
        case .keepForSevenDays: "For 7 days"
        case .keepUntilManuallyCleared: "Until I clear them"
        case .keepPermanently: "Keep everything"
        }
    }
}

struct WorkflowPolicy: Codable, Identifiable, Equatable {
    var id: String
    var name: String
    var isEnabled: Bool
    var sourceBehavior: SourceBehavior
    var watchFolderPath: String
    var includeWatchFolderSubfolders: Bool
    var destination: WorkflowDestination
    var destinationPath: String
    var audioDestinationPath: String
    var transcriptBehavior: TranscriptBehavior
    var audioFileBehavior: AudioFileBehavior
    var reviewBehavior: ReviewBehavior
    var filenamePattern: String
    var processingStoragePolicy: ProcessingStoragePolicy
    var usesSmartAnalysis: Bool
    var summaryStyle: SummaryStyle
    var noteIncludesTitle: Bool
    var useSpokenDateFromTranscript: Bool
    var notePeriod: NotePeriod
    var noteLinkStyle: NoteLinkStyle
    var embedAudioInNote: Bool
    var normalizeAudio: Bool
    var compressAudioOnExport: Bool
    var compressionBitrateKbps: Int
    var compressionForceMono: Bool

    var usesWatchFolder: Bool {
        isEnabled && sourceBehavior.usesWatchFolder && !watchFolderPath.isEmpty
    }

    enum CodingKeys: String, CodingKey {
        case id
        case name
        case isEnabled
        case sourceBehavior
        case watchFolderPath
        case includeWatchFolderSubfolders
        case destination
        case destinationPath
        case audioDestinationPath
        case transcriptBehavior
        case audioFileBehavior
        case audioBehavior
        case originalBehavior
        case reviewBehavior
        case filenamePattern
        case processingStoragePolicy
        case usesSmartAnalysis
        case summaryStyle
        case noteIncludesTitle
        case useSpokenDateFromTranscript
        case notePeriod
        case noteLinkStyle
        case embedAudioInNote
        case normalizeAudio
        case compressAudioOnExport
        case compressionBitrateKbps
        case compressionForceMono
    }

    init(
        id: String,
        name: String,
        isEnabled: Bool,
        sourceBehavior: SourceBehavior,
        watchFolderPath: String,
        includeWatchFolderSubfolders: Bool = false,
        destination: WorkflowDestination,
        destinationPath: String,
        audioDestinationPath: String,
        transcriptBehavior: TranscriptBehavior,
        audioFileBehavior: AudioFileBehavior,
        reviewBehavior: ReviewBehavior,
        filenamePattern: String,
        processingStoragePolicy: ProcessingStoragePolicy,
        usesSmartAnalysis: Bool = true,
        summaryStyle: SummaryStyle = .sentence,
        noteIncludesTitle: Bool = true,
        useSpokenDateFromTranscript: Bool = true,
        notePeriod: NotePeriod = .monthly,
        noteLinkStyle: NoteLinkStyle = .wikilink,
        embedAudioInNote: Bool = true,
        normalizeAudio: Bool = false,
        compressAudioOnExport: Bool = false,
        compressionBitrateKbps: Int = 96,
        compressionForceMono: Bool = true
    ) {
        self.id = id
        self.name = name
        self.isEnabled = isEnabled
        self.sourceBehavior = sourceBehavior
        self.watchFolderPath = watchFolderPath
        self.includeWatchFolderSubfolders = includeWatchFolderSubfolders
        self.destination = destination
        self.destinationPath = destinationPath
        self.audioDestinationPath = audioDestinationPath
        self.transcriptBehavior = transcriptBehavior
        self.audioFileBehavior = audioFileBehavior
        self.reviewBehavior = reviewBehavior
        self.filenamePattern = filenamePattern
        self.processingStoragePolicy = processingStoragePolicy
        self.usesSmartAnalysis = usesSmartAnalysis
        self.summaryStyle = summaryStyle
        self.noteIncludesTitle = noteIncludesTitle
        self.useSpokenDateFromTranscript = useSpokenDateFromTranscript
        self.notePeriod = notePeriod
        self.noteLinkStyle = noteLinkStyle
        self.embedAudioInNote = embedAudioInNote
        self.normalizeAudio = normalizeAudio
        self.compressAudioOnExport = compressAudioOnExport
        self.compressionBitrateKbps = compressionBitrateKbps
        self.compressionForceMono = compressionForceMono
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        isEnabled = try container.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? true
        sourceBehavior = try container.decodeIfPresent(SourceBehavior.self, forKey: .sourceBehavior) ?? .manualOnly
        watchFolderPath = try container.decodeIfPresent(String.self, forKey: .watchFolderPath) ?? ""
        includeWatchFolderSubfolders = try container.decodeIfPresent(Bool.self, forKey: .includeWatchFolderSubfolders) ?? true
        destination = try container.decodeIfPresent(WorkflowDestination.self, forKey: .destination) ?? .projectFolder
        destinationPath = try container.decodeIfPresent(String.self, forKey: .destinationPath) ?? ""
        audioDestinationPath = try container.decodeIfPresent(String.self, forKey: .audioDestinationPath) ?? ""
        transcriptBehavior = try container.decodeIfPresent(TranscriptBehavior.self, forKey: .transcriptBehavior) ?? .createMarkdownFile
        reviewBehavior = try container.decodeIfPresent(ReviewBehavior.self, forKey: .reviewBehavior) ?? .requireReview
        filenamePattern = try container.decodeIfPresent(String.self, forKey: .filenamePattern) ?? WorkflowPolicy.defaultFilenamePattern
        processingStoragePolicy = try container.decodeIfPresent(ProcessingStoragePolicy.self, forKey: .processingStoragePolicy) ?? .deleteAfterSuccessfulExport
        usesSmartAnalysis = try container.decodeIfPresent(Bool.self, forKey: .usesSmartAnalysis) ?? true
        summaryStyle = try container.decodeIfPresent(SummaryStyle.self, forKey: .summaryStyle) ?? .sentence
        noteIncludesTitle = try container.decodeIfPresent(Bool.self, forKey: .noteIncludesTitle) ?? true
        useSpokenDateFromTranscript = try container.decodeIfPresent(Bool.self, forKey: .useSpokenDateFromTranscript) ?? true
        notePeriod = try container.decodeIfPresent(NotePeriod.self, forKey: .notePeriod) ?? .monthly
        noteLinkStyle = try container.decodeIfPresent(NoteLinkStyle.self, forKey: .noteLinkStyle) ?? .wikilink
        embedAudioInNote = try container.decodeIfPresent(Bool.self, forKey: .embedAudioInNote) ?? true
        normalizeAudio = try container.decodeIfPresent(Bool.self, forKey: .normalizeAudio) ?? false
        compressAudioOnExport = try container.decodeIfPresent(Bool.self, forKey: .compressAudioOnExport) ?? false
        compressionBitrateKbps = try container.decodeIfPresent(Int.self, forKey: .compressionBitrateKbps) ?? 96
        compressionForceMono = try container.decodeIfPresent(Bool.self, forKey: .compressionForceMono) ?? true

        if let behavior = try container.decodeIfPresent(AudioFileBehavior.self, forKey: .audioFileBehavior) {
            audioFileBehavior = behavior
        } else {
            let legacyAudio = try container.decodeIfPresent(LegacyAudioBehavior.self, forKey: .audioBehavior) ?? .doNotExportAudio
            let legacyOriginal = try container.decodeIfPresent(LegacyOriginalBehavior.self, forKey: .originalBehavior) ?? .keepOriginal
            audioFileBehavior = Self.migratedAudioFileBehavior(audioBehavior: legacyAudio, originalBehavior: legacyOriginal)
        }
        if destinationPath.isEmpty {
            destinationPath = Self.migratedDestinationPath(for: destination)
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encode(isEnabled, forKey: .isEnabled)
        try container.encode(sourceBehavior, forKey: .sourceBehavior)
        try container.encode(watchFolderPath, forKey: .watchFolderPath)
        try container.encode(includeWatchFolderSubfolders, forKey: .includeWatchFolderSubfolders)
        try container.encode(destination, forKey: .destination)
        try container.encode(destinationPath, forKey: .destinationPath)
        try container.encode(audioDestinationPath, forKey: .audioDestinationPath)
        try container.encode(transcriptBehavior, forKey: .transcriptBehavior)
        try container.encode(audioFileBehavior, forKey: .audioFileBehavior)
        try container.encode(reviewBehavior, forKey: .reviewBehavior)
        try container.encode(filenamePattern, forKey: .filenamePattern)
        try container.encode(processingStoragePolicy, forKey: .processingStoragePolicy)
        try container.encode(usesSmartAnalysis, forKey: .usesSmartAnalysis)
        try container.encode(summaryStyle, forKey: .summaryStyle)
        try container.encode(noteIncludesTitle, forKey: .noteIncludesTitle)
        try container.encode(useSpokenDateFromTranscript, forKey: .useSpokenDateFromTranscript)
        try container.encode(notePeriod, forKey: .notePeriod)
        try container.encode(noteLinkStyle, forKey: .noteLinkStyle)
        try container.encode(embedAudioInNote, forKey: .embedAudioInNote)
        try container.encode(normalizeAudio, forKey: .normalizeAudio)
        try container.encode(compressAudioOnExport, forKey: .compressAudioOnExport)
        try container.encode(compressionBitrateKbps, forKey: .compressionBitrateKbps)
        try container.encode(compressionForceMono, forKey: .compressionForceMono)
    }

    private static func migratedAudioFileBehavior(
        audioBehavior: LegacyAudioBehavior,
        originalBehavior: LegacyOriginalBehavior
    ) -> AudioFileBehavior {
        if originalBehavior == .renameOriginalInPlace {
            return .renameInPlace
        }
        switch audioBehavior {
        case .copyAudioToDestination:
            return .copyToFolder
        case .moveAudioToDestination:
            return .moveToFolder
        case .doNotExportAudio, .linkExistingAudio:
            return .leaveInPlace
        }
    }

    private static func migratedDestinationPath(for destination: WorkflowDestination) -> String {
        switch destination {
        case .obsidianJournal:
            return "🖋️ Journal"
        case .obsidianInbox:
            return "📮INBOX/📻 VOICE INBOX"
        case .archiveFolder:
            return "📦 Archive/Voice Memos"
        case .projectFolder, .sameFolder:
            return ""
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
    var suggestedWorkflow: String?
    /// Short bullet points, used when a workflow renders its summary as a list.
    var summaryPoints: [String]? = nil
    /// Date and time the speaker states at the start or end of the recording, if any.
    var spokenDate: Date? = nil
}

// Decoded leniently so history written by older versions keeps loading.
extension AnalysisMetadata {
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            title: try container.decodeIfPresent(String.self, forKey: .title) ?? "",
            slug: try container.decodeIfPresent(String.self, forKey: .slug) ?? "",
            shortSlug: try container.decodeIfPresent(String.self, forKey: .shortSlug) ?? "",
            summary: try container.decodeIfPresent(String.self, forKey: .summary) ?? "",
            themes: try container.decodeIfPresent([String].self, forKey: .themes) ?? [],
            mood: try container.decodeIfPresent(String.self, forKey: .mood),
            suggestedWorkflow: try container.decodeIfPresent(String.self, forKey: .suggestedWorkflow),
            summaryPoints: try container.decodeIfPresent([String].self, forKey: .summaryPoints),
            spokenDate: try container.decodeIfPresent(Date.self, forKey: .spokenDate)
        )
    }
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
    var sourceFilename: String?
    var sourcePath: String?
    var audioFingerprint: String?
    var managedAudioPath: String?
    /// Loudness-normalized copy in the processing cache. Created before transcription
    /// and reused for the exported audio, so normalization only ever runs once.
    var normalizedAudioPath: String?
    var recordingDate: Date
    var recordingDateIsCertain: Bool
    var recordingDateSource: RecordingDateSource = .fileMetadata
    var durationSeconds: Double?
    var transcript: String?
    var analysis: AnalysisMetadata?
    var workflow: String = StandardWorkflowID.obsidianJournal
    /// True once the workflow was picked deliberately (import picker, watch folder, or review).
    /// Automatic routing never overwrites a deliberate choice.
    var workflowIsUserAssigned: Bool = false
    var status: ImportStatus = .new
    var retryCount = 0
    var importedAt: Date?
    var exportedMarkdownPath: String?
    var error: ProcessingError?
    var fileOperations: [FileOperationRecord] = []
    /// Set once the user edits the filename directly during review. When present,
    /// this replaces the workflow's generated filename outright instead of feeding
    /// into the pattern.
    var filenameOverride: String?


    var displayTitle: String {
        if let title = analysis?.title, !title.isEmpty {
            return title
        }
        return (originalFilename as NSString).deletingPathExtension
    }

    /// The path the exported audio landed at, if this workflow exported audio at
    /// all. Matched against the exact operation kinds the exporter writes, so an
    /// internal copy is never mistaken for a real export.
    var exportedAudioPath: String? {
        let exportKinds: Set<String> = [
            "move", "copy",
            "normalize_move", "normalize_copy",
            "compress_move", "compress_copy",
            "normalize_compress_move", "normalize_compress_copy"
        ]
        return fileOperations.last { exportKinds.contains($0.kind) }?.destinationPath
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
            // Already filed. Reaching the files it produced is the Files tab's job,
            // so the header keeps one meaning: the step that is still outstanding.
            return nil
        default:
            return nil
        }
    }
}

// Decoded leniently so history written by older versions keeps loading.
extension ImportItem {
    init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
            createdAt = try container.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
            updatedAt = try container.decodeIfPresent(Date.self, forKey: .updatedAt) ?? createdAt
            originalFilename = try container.decodeIfPresent(String.self, forKey: .originalFilename) ?? ""
            originalPath = try container.decodeIfPresent(String.self, forKey: .originalPath) ?? ""
            sourceFilename = try container.decodeIfPresent(String.self, forKey: .sourceFilename)
            sourcePath = try container.decodeIfPresent(String.self, forKey: .sourcePath)
            audioFingerprint = try container.decodeIfPresent(String.self, forKey: .audioFingerprint)
            managedAudioPath = try container.decodeIfPresent(String.self, forKey: .managedAudioPath)
        normalizedAudioPath = try container.decodeIfPresent(String.self, forKey: .normalizedAudioPath)
            recordingDate = try container.decodeIfPresent(Date.self, forKey: .recordingDate) ?? createdAt
            recordingDateIsCertain = try container.decodeIfPresent(Bool.self, forKey: .recordingDateIsCertain) ?? false
            recordingDateSource = try container.decodeIfPresent(RecordingDateSource.self, forKey: .recordingDateSource) ?? .fileMetadata
            durationSeconds = try container.decodeIfPresent(Double.self, forKey: .durationSeconds)
            transcript = try container.decodeIfPresent(String.self, forKey: .transcript)
            analysis = try container.decodeIfPresent(AnalysisMetadata.self, forKey: .analysis)
            workflow = try container.decodeIfPresent(String.self, forKey: .workflow) ?? StandardWorkflowID.obsidianJournal
            workflowIsUserAssigned = try container.decodeIfPresent(Bool.self, forKey: .workflowIsUserAssigned) ?? false
            status = try container.decodeIfPresent(ImportStatus.self, forKey: .status) ?? .new
            retryCount = try container.decodeIfPresent(Int.self, forKey: .retryCount) ?? 0
            importedAt = try container.decodeIfPresent(Date.self, forKey: .importedAt)
            exportedMarkdownPath = try container.decodeIfPresent(String.self, forKey: .exportedMarkdownPath)
            error = try container.decodeIfPresent(ProcessingError.self, forKey: .error)
            fileOperations = try container.decodeIfPresent([FileOperationRecord].self, forKey: .fileOperations) ?? []
            filenameOverride = try container.decodeIfPresent(String.self, forKey: .filenameOverride)
        }
}

struct AppSettings: Codable, Equatable {
    var macWhisperPath = "/usr/local/bin/mw"
    var ffmpegPath = "/opt/homebrew/bin/ffmpeg"
    var lmStudioBaseURL = "http://localhost:1234/v1"
    var lmStudioModelID: String?
    /// Fresh-install default: deliberately blank. Every fresh-install workflow's
    /// destinationPath/audioDestinationPath is blank too, so nothing gets written
    /// anywhere presumptuous until the user actively picks a folder — at which point
    /// the folder picker always stores an absolute path anyway, making this moot.
    /// Existing users are unaffected — `init(from:)` below falls back to the old
    /// Obsidian iCloud path instead, if their settings.json is somehow missing this key.
    var vaultRootPath = ""
    var defaultWorkflow: String = StandardWorkflowID.obsidianJournal
    var workflows: [WorkflowPolicy] = WorkflowPolicy.freshInstallDefaults
    var maxTranscriptCharactersForAnalysis = 24000
    var transcriptionTimeoutSeconds = 900
    var retryLimit = 2
    var processingStoragePolicy: ProcessingStoragePolicy = .deleteAfterSuccessfulExport
    var checkWatchFoldersAtLaunch = false
    var jprWatchFolderPath = "\(NSHomeDirectory())/Library/Mobile Documents/iCloud~com~openplanetsoftware~just-press-record/Documents"
    var archiveRelativePath = "📦 Archive/Voice Memos"
    var importedAudioFingerprints: [String] = []

    enum CodingKeys: String, CodingKey {
        case macWhisperPath
        case ffmpegPath
        case lmStudioBaseURL
        case lmStudioModelID
        case vaultRootPath
        case defaultWorkflow
        case workflows
        case maxTranscriptCharactersForAnalysis
        case transcriptionTimeoutSeconds
        case retryLimit
        case processingStoragePolicy
        case checkWatchFoldersAtLaunch
        case jprWatchFolderPath
        case archiveRelativePath
        case importedAudioFingerprints
    }

    /// No longer stored; kept only to migrate old settings files into the
    /// per-workflow setting of the same name.
    private enum LegacyCodingKeys: String, CodingKey {
        case useSpokenDateFromTranscript
        case compressAudioOnExport
        case normalizeAudio = "normalizeAudioOnExport"
        case compressionBitrateKbps
        case compressionForceMono
        case usesObsidian
    }

    init() {}

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        macWhisperPath = try container.decodeIfPresent(String.self, forKey: .macWhisperPath) ?? macWhisperPath
        ffmpegPath = try container.decodeIfPresent(String.self, forKey: .ffmpegPath) ?? ffmpegPath
        lmStudioBaseURL = try container.decodeIfPresent(String.self, forKey: .lmStudioBaseURL) ?? lmStudioBaseURL
        lmStudioModelID = try container.decodeIfPresent(String.self, forKey: .lmStudioModelID)
        vaultRootPath = try container.decodeIfPresent(String.self, forKey: .vaultRootPath)
            ?? "\(NSHomeDirectory())/Library/Mobile Documents/iCloud~md~obsidian/Documents/Notes"
        defaultWorkflow = WorkflowPolicy.canonicalID(
            try container.decodeIfPresent(String.self, forKey: .defaultWorkflow) ?? defaultWorkflow
        )
        workflows = try container.decodeIfPresent([WorkflowPolicy].self, forKey: .workflows) ?? WorkflowPolicy.defaults
        workflows = workflows.map { policy in
            var migrated = policy
            migrated.id = WorkflowPolicy.canonicalID(policy.id)
            if migrated.id != policy.id {
                migrated.name = WorkflowPolicy.canonicalName(for: migrated.id, currentName: migrated.name)
            }
            return migrated
        }
        maxTranscriptCharactersForAnalysis = try container.decodeIfPresent(Int.self, forKey: .maxTranscriptCharactersForAnalysis) ?? maxTranscriptCharactersForAnalysis
        transcriptionTimeoutSeconds = try container.decodeIfPresent(Int.self, forKey: .transcriptionTimeoutSeconds) ?? transcriptionTimeoutSeconds
        retryLimit = try container.decodeIfPresent(Int.self, forKey: .retryLimit) ?? retryLimit
        processingStoragePolicy = try container.decodeIfPresent(ProcessingStoragePolicy.self, forKey: .processingStoragePolicy) ?? processingStoragePolicy
        checkWatchFoldersAtLaunch = try container.decodeIfPresent(Bool.self, forKey: .checkWatchFoldersAtLaunch) ?? false
        jprWatchFolderPath = try container.decodeIfPresent(String.self, forKey: .jprWatchFolderPath) ?? jprWatchFolderPath
        archiveRelativePath = try container.decodeIfPresent(String.self, forKey: .archiveRelativePath) ?? archiveRelativePath
        importedAudioFingerprints = try container.decodeIfPresent([String].self, forKey: .importedAudioFingerprints) ?? []
        WorkflowPolicy.defaults.forEach { fallback in
            if !workflows.contains(where: { $0.id == fallback.id }) {
                workflows.append(fallback)
            }
        }
        let legacyContainer = try decoder.container(keyedBy: LegacyCodingKeys.self)
        if let legacyUseSpokenDate = try legacyContainer.decodeIfPresent(Bool.self, forKey: .useSpokenDateFromTranscript) {
            workflows = workflows.map { policy in
                var migrated = policy
                migrated.useSpokenDateFromTranscript = legacyUseSpokenDate
                return migrated
            }
        }
        let legacyNormalizeAudio = try legacyContainer.decodeIfPresent(Bool.self, forKey: .normalizeAudio)
        let legacyCompressAudioOnExport = try legacyContainer.decodeIfPresent(Bool.self, forKey: .compressAudioOnExport)
        let legacyCompressionBitrateKbps = try legacyContainer.decodeIfPresent(Int.self, forKey: .compressionBitrateKbps)
        let legacyCompressionForceMono = try legacyContainer.decodeIfPresent(Bool.self, forKey: .compressionForceMono)
        if legacyNormalizeAudio != nil || legacyCompressAudioOnExport != nil || legacyCompressionBitrateKbps != nil || legacyCompressionForceMono != nil {
            workflows = workflows.map { policy in
                var migrated = policy
                if let legacyNormalizeAudio { migrated.normalizeAudio = legacyNormalizeAudio }
                if let legacyCompressAudioOnExport { migrated.compressAudioOnExport = legacyCompressAudioOnExport }
                if let legacyCompressionBitrateKbps { migrated.compressionBitrateKbps = legacyCompressionBitrateKbps }
                if let legacyCompressionForceMono { migrated.compressionForceMono = legacyCompressionForceMono }
                return migrated
            }
        }
        if let legacyUsesObsidian = try legacyContainer.decodeIfPresent(Bool.self, forKey: .usesObsidian) {
            workflows = workflows.map { policy in
                var migrated = policy
                migrated.noteLinkStyle = legacyUsesObsidian ? .wikilink : .markdown
                return migrated
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
            return "Journal"
        case StandardWorkflowID.obsidianInbox:
            return "Transcribe Only"
        case StandardWorkflowID.transcriptOnly:
            return "Transcript Only"
        case StandardWorkflowID.renameInPlace:
            return "Rename Audio Only"
        default:
            return currentName
        }
    }

    static let defaults: [WorkflowPolicy] = [
        WorkflowPolicy(
            id: StandardWorkflowID.obsidianJournal,
            name: "Journal",
            isEnabled: true,
            sourceBehavior: .manualOnly,
            watchFolderPath: "",
            destination: .obsidianJournal,
            destinationPath: "",
            audioDestinationPath: "",
            transcriptBehavior: .appendToMonthlyNote,
            audioFileBehavior: .copyToFolder,
            reviewBehavior: .requireReview,
            filenamePattern: defaultFilenamePattern,
            processingStoragePolicy: .deleteAfterSuccessfulExport
        ),
        WorkflowPolicy(
            id: StandardWorkflowID.obsidianInbox,
            name: "Transcribe Only",
            isEnabled: true,
            sourceBehavior: .manualOnly,
            watchFolderPath: "",
            destination: .obsidianInbox,
            destinationPath: "",
            audioDestinationPath: "",
            transcriptBehavior: .createMarkdownFile,
            audioFileBehavior: .leaveInPlace,
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
            audioFileBehavior: .leaveInPlace,
            reviewBehavior: .requireReview,
            filenamePattern: defaultFilenamePattern,
            processingStoragePolicy: .deleteAfterSuccessfulExport
        ),
        WorkflowPolicy(
            id: StandardWorkflowID.renameInPlace,
            name: "Rename Audio Only",
            isEnabled: true,
            sourceBehavior: .manualOnly,
            watchFolderPath: "",
            destination: .sameFolder,
            destinationPath: "",
            audioDestinationPath: "",
            transcriptBehavior: .doNotExportTranscript,
            audioFileBehavior: .renameInPlace,
            reviewBehavior: .requireReview,
            filenamePattern: defaultFilenamePattern,
            processingStoragePolicy: .deleteAfterSuccessfulExport
        )
    ]

    /// Starting workflow set for a brand-new install (no settings.json yet).
    /// Fewer, less Obsidian-branded presets than `defaults`, which stays the
    /// full backfill list so upgrading users never lose a configured workflow.
    static let freshInstallDefaults: [WorkflowPolicy] = [
        defaults[0], // Journal
        defaults[1], // Transcribe Only
        defaults[3]  // Rename Audio Only
    ]
}
