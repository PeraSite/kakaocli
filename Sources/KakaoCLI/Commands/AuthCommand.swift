import ArgumentParser
import Foundation
import KakaoCore

struct AuthCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "auth",
        abstract: "Verify and cache local DB identity; no server login or password needed")
    @Option(name: .long, help: "Encrypted DB file, including a Finder copy") var db: String?
    @Option(name: .long, help: "Local or copied directory containing KakaoTalk plists") var preferencesDir: String?
    @Option(name: .long, help: "Known numeric account ID; optional") var userId: Int?
    @Option(name: .long, help: "Override device UUID") var uuid: String?
    @Option(name: .long, help: "Recovery wall-clock budget in seconds") var recoverTimeout: Double = 120
    @Option(name: .long, help: "Exclusive upper bound for numeric IDs") var maxUserId: UInt64 = 6_000_000_000
    @Option(name: .long, help: "Native recovery threads, 1...64") var workers: Int?
    @Flag(name: .long, help: "Save verified identity and DB path in mode-0600 config; never saves key") var save = false
    @Flag(name: .long, help: "Output JSON") var json = false
    @Flag(name: .long, help: "Show schema names; never outputs key") var verbose = false

    func run() throws {
        guard recoverTimeout.isFinite, recoverTimeout > 0, recoverTimeout <= 86400,
              maxUserId > 0, maxUserId <= 100_000_000_000,
              workers == nil || (1...64).contains(workers!) else {
            throw ValidationError("Invalid --recover-timeout, --max-user-id or --workers")
        }
        let configuration: LocalDatabaseConfiguration
        let hasOverrides = db != nil || preferencesDir != nil || userId != nil || uuid != nil
        if !hasOverrides, let cached = try LocalDatabaseConfiguration.load() {
            configuration = cached
        } else {
            configuration = try LocalDatabase.configure(databasePath: db, preferencesDirectory: preferencesDir,
                userId: userId, uuid: uuid, timeout: recoverTimeout, maxId: maxUserId, workers: workers) { message in
                FileHandle.standardError.write(Data((message + "\n").utf8))
            }
        }
        let reader = DatabaseReader(databasePath: configuration.databasePath); defer { reader.close() }
        try reader.open(key: KeyDerivation.secureKey(userId: configuration.userId, uuid: configuration.uuid))
        guard try reader.myUserId() == Int64(configuration.userId) else {
            throw ValidationError("Local identity does not match NTChatContext")
        }
        let tables = try reader.schema()
        if save { try configuration.save() }
        let item: [String: Any] = ["verified": true, "database_path": reader.databasePath,
            "config_saved": save, "config_path": LocalDatabaseConfiguration.defaultPath,
            "read_only": true, "tables": tables.count, "rooms": try reader.countChats(),
            "messages": try reader.countMessages(), "key_persisted": false]
        if json { try JSONOutput.printObject(item) }
        else {
            print("Local database verified (read-only): \(reader.databasePath)")
            print("Rooms: \(item["rooms"]!) · messages: \(item["messages"]!)")
            if save { print("Private identity cache saved: \(LocalDatabaseConfiguration.defaultPath)") }
            if verbose { for table in tables { print("  \(table.name)") } }
        }
    }
}
