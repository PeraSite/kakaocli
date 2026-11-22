import ArgumentParser
import Foundation
import KakaoCore

/// Report (and optionally request) the two macOS permissions kakaocli needs.
struct PermissionsCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "permissions",
        abstract: "Check Full Disk Access (read the local DB) and Accessibility (send) for this executable",
        discussion: """
        macOS grants permissions to the "responsible" process. Run from Terminal, the checks report
        Terminal's permissions, not kakaocli's. To give the permissions to kakaocli alone, run it from launchd
        (see README: "Permissions") and add this executable in System Settings → Privacy & Security →
        Full Disk Access and → Accessibility. --prompt shows the macOS Accessibility request.
        """
    )

    @Flag(name: .long, help: "Ask macOS for Accessibility (shows the system prompt)")
    var prompt = false

    @Flag(name: .long, help: "Print JSON")
    var json = false

    func run() throws {
        var diskOK = false, diskError: String?
        do { let r = try LocalDatabase.open(); r.close(); diskOK = true } catch { diskError = "\(error)" }
        let axOK = FastSender.isTrusted(prompt: prompt)
        let exe = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath().path
        let item: [String: Any] = ["executable": exe, "full_disk_access": diskOK, "accessibility": axOK,
                                   "database_error": diskError ?? NSNull()]
        if json { try JSONOutput.printObject(item); return }
        print("Executable:        \(exe)")
        print("Read local DB:     \(diskOK ? "ok" : "no — \(diskError ?? "")")")
        print("Accessibility:     \(axOK ? "ok" : "no — System Settings → Privacy & Security → Accessibility → add this executable")")
    }
}
