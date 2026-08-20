import Foundation

/// Finds where a command-line dependency actually lives, since the settings defaults are
/// just a guess (Apple Silicon vs Intel Homebrew alone puts `ffmpeg` in different places).
/// Used by the first-run setup wizard to pre-fill paths instead of leaving a wrong default
/// in place for someone who never opens Settings.
enum DependencyDetector {
    static func detectMacWhisperPath(configured: String) async -> String? {
        await detectExecutablePath(configured: configured, knownPaths: ["/usr/local/bin/mw"], commandName: "mw")
    }

    static func detectFFmpegPath(configured: String) async -> String? {
        await detectExecutablePath(
            configured: configured,
            knownPaths: [
                "/opt/homebrew/bin/ffmpeg", // Apple Silicon Homebrew
                "/usr/local/bin/ffmpeg", // Intel Homebrew
                "/opt/local/bin/ffmpeg" // MacPorts
            ],
            commandName: "ffmpeg"
        )
    }

    private static func detectExecutablePath(configured: String, knownPaths: [String], commandName: String) async -> String? {
        await Task.detached(priority: .userInitiated) {
            if isExecutableFile(configured) { return configured }
            if let known = knownPaths.first(where: isExecutableFile) { return known }
            if let fromShell = lookUpOnPath(commandName), isExecutableFile(fromShell) { return fromShell }
            return nil
        }.value
    }

    private static func isExecutableFile(_ path: String) -> Bool {
        !path.isEmpty && FileManager.default.isExecutableFile(atPath: path)
    }

    /// A login shell so PATH additions from `.zprofile`/`.zshrc` are picked up, not just
    /// the minimal PATH a GUI app is launched with.
    private static func lookUpOnPath(_ commandName: String) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-l", "-c", "command -v \(commandName)"]
        let stdout = Pipe()
        process.standardOutput = stdout
        process.standardError = Pipe()
        guard (try? process.run()) != nil else { return nil }
        let data = stdout.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        let output = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
        return (output?.isEmpty == false) ? output : nil
    }
}
