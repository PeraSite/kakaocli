import ArgumentParser
import Foundation
import KakaoCore

struct SearchCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "search",
        abstract: "Search messages"
    )

    @Argument(help: "Search query")
    var query: String

    @Option(name: .long, help: "Maximum results")
    var limit: Int = 20
    @Option(name: .long, help: "Skip this many matching messages")
    var offset = 0
    @Option(name: .long, help: "Filter one chat ID")
    var chatId: Int64?
    @Option(name: .long, help: "Sender: any, me, others")
    var sender = "any"
    @Flag(name: .long, help: "JSON page with total and next_offset")
    var page = false

    @Flag(name: .long, help: "Output as JSON")
    var json = false

    @Option(name: .long, help: "Path to database file")
    var db: String?

    @Option(name: .long, help: "Database encryption key")
    var key: String?

    func run() throws {
        try validatePage(limit: limit, offset: offset); try validateSender(sender)
        guard !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw ValidationError("Search text cannot be empty") }
        let reader = try openDatabase(dbPath: db, key: key)
        defer { reader.close() }

        let results = try reader.search(query: query, limit: limit, offset: offset, chatId: chatId, sender: sender)

        if page {
            try printPage(results.map(messageJSON), total: reader.countMessages(chatId: chatId, text: query, sender: sender),
                          limit: limit, offset: offset, databasePath: reader.databasePath)
        } else if json {
            JSONOutput.printArray(results.map(messageJSON))
        } else {
            if results.isEmpty {
                print("No messages matching '\(query)'.")
                return
            }
            print("Found \(results.count) message(s):")
            print()
            for msg in results {
                let sender = msg.isFromMe ? "Me" : (msg.senderName ?? "Unknown")
                let time = formatDate(msg.createdAt)
                let text = msg.text ?? ""
                print("\(time) \(sender): \(text)")
            }
        }
    }
}
