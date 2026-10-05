import ArgumentParser
import Foundation
import KakaoCore

struct MessagesCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "messages",
        abstract: "Show recent messages"
    )

    @Option(name: .long, help: "Filter by chat name (substring match)")
    var chat: String?

    @Option(name: .long, help: "Filter by chat ID")
    var chatId: Int64?

    @Option(name: .long, help: "Show messages since (e.g. 1h, 24h, 7d)")
    var since: String?

    @Option(name: .long, help: "Maximum number of messages")
    var limit: Int = 50
    @Option(name: .long, help: "Skip this many matching messages")
    var offset: Int = 0
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
        if chat != nil && chatId != nil { throw ValidationError("Use either --chat or --chat-id") }
        let reader = try openDatabase(dbPath: db, key: key)
        defer { reader.close() }

        // Resolve chat name to ID if needed
        var resolvedChatId = chatId
        if let chatName = chat, resolvedChatId == nil {
            let chats = try reader.localChats()
            let exact = chats.filter { $0.displayName == chatName }
            let matches = exact.isEmpty ? chats.filter { $0.displayName.localizedCaseInsensitiveContains(chatName) } : exact
            guard matches.count == 1, let found = matches.first else {
                throw ValidationError("Chat name matched \(matches.count) rooms; use chats --page and then --chat-id")
            }
            resolvedChatId = found.id
        }

        let sinceDate = since.flatMap { parseDuration($0) }
        if since != nil && sinceDate == nil { throw ValidationError("Invalid --since duration (e.g. 1h, 7d)") }
        let messages = try reader.messages(chatId: resolvedChatId, since: sinceDate, limit: limit, offset: offset, sender: sender)

        if page {
            try printPage(messages.map(messageJSON), total: reader.countMessages(chatId: resolvedChatId, since: sinceDate, sender: sender),
                          limit: limit, offset: offset, databasePath: reader.databasePath)
        } else if json {
            JSONOutput.printArray(messages.map(messageJSON))
        } else {
            if messages.isEmpty {
                print("No messages found.")
                return
            }
            for msg in messages.reversed() {
                let sender = msg.isFromMe ? "Me" : (msg.senderName ?? "Unknown")
                let time = formatDate(msg.createdAt)
                let text = msg.text ?? "[\(msg.type)]"
                print("\(time) \(sender): \(text)")
            }
        }
    }
}

func parseDuration(_ str: String) -> Date? {
    let value: Double
    let unit: Character

    let trimmed = str.trimmingCharacters(in: .whitespaces).lowercased()
    guard let last = trimmed.last, last.isLetter else { return nil }
    guard let num = Double(trimmed.dropLast()), num.isFinite, num > 0 else { return nil }

    value = num
    unit = last

    let seconds: TimeInterval
    switch unit {
    case "s": seconds = value
    case "m": seconds = value * 60
    case "h": seconds = value * 3600
    case "d": seconds = value * 86400
    case "w": seconds = value * 604800
    default: return nil
    }

    return Date().addingTimeInterval(-seconds)
}
