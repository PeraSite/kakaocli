import ArgumentParser
import Foundation
import KakaoCore

struct ContextCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "context", abstract: "Read the original messages around one local log ID")
    @Option(name: .long) var chatId: Int64
    @Option(name: .long) var logId: Int64
    @Option(name: .long) var msgId: Int64?
    @Option(name: .long) var before = 5
    @Option(name: .long) var after = 5
    @Flag(name: .long) var json = false
    @Option(name: .long) var db: String?
    @Option(name: .long) var key: String?

    func run() throws {
        guard (0...30).contains(before), (0...30).contains(after) else { throw ValidationError("--before/--after must be 0...30") }
        let reader = try openDatabase(dbPath: db, key: key); defer { reader.close() }
        let rows = try reader.context(chatId: chatId, logId: logId, messageId: msgId, before: before, after: after)
        if json { JSONOutput.printArray(rows.map(messageJSON)) }
        else { for message in rows { print("\(formatDate(message.createdAt)) \(message.senderName ?? "Unknown"): \(message.text ?? "[attachment]")") } }
    }
}
