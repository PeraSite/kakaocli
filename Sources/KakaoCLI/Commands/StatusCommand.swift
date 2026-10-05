import ArgumentParser
import Foundation
import KakaoCore

struct StatusCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "status",
        abstract: "Report local DB source, identity cache and record coverage")
    @Flag(name: .long) var json = false
    @Option(name: .long) var db: String?
    @Option(name: .long) var key: String?

    func run() throws {
        let reader = try openDatabase(dbPath: db, key: key); defer { reader.close() }
        let rooms = try reader.localChats()
        let coverage = try reader.rawNamedQuery("SELECT count(*) AS messages,min(sentAt) AS first_message_epoch,max(sentAt) AS last_message_epoch FROM NTChatMessage").first ?? [:]
        let source = URL(fileURLWithPath: reader.databasePath).resolvingSymlinksInPath().path
        var item = coverage
        item["database_path"] = reader.databasePath
        item["source_mode"] = source.hasPrefix(DeviceInfo.containerPath + "/") ? "live-local-db" : "local-copy"
        item["read_only"] = true
        item["identity_cached"] = (try LocalDatabaseConfiguration.load()) != nil
        item["key_persisted"] = false
        item["rooms"] = rooms.count
        item["by_kind"] = Chat.Kind.allCases.map { kind -> [String: Any] in
            let matching = rooms.filter { $0.kind == kind }
            return ["kind": kind.rawValue, "rooms": matching.count,
                    "messages": matching.reduce(0) { $0 + $1.messageCount }]
        }
        if json { try JSONOutput.printObject(item) }
        else { print("Local DB: \(reader.databasePath)\nSource: \(item["source_mode"]!)\nRooms: \(rooms.count) · messages: \(coverage["messages"] ?? 0)") }
    }
}
