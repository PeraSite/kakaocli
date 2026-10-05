import ArgumentParser
import Foundation
import KakaoCore

struct ChatsCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "chats",
        abstract: "List all chats"
    )

    @Option(name: .long, help: "Maximum number of chats to show")
    var limit: Int = 50
    @Option(name: .long, help: "Skip this many rows")
    var offset: Int = 0
    @Option(name: .long, help: "Filter room kind (open, open-direct, open-group, channel, direct, group, self)")
    var kind: String?
    @Flag(name: .long, help: "Only rooms with messages authored by you")
    var contacted = false
    @Flag(name: .long, help: "JSON page with total and next_offset")
    var page = false

    @Flag(name: .long, help: "Output as JSON")
    var json = false

    @Option(name: .long, help: "Path to database file (auto-detected if not set)")
    var db: String?

    @Option(name: .long, help: "Database encryption key (auto-derived if not set)")
    var key: String?

    func run() throws {
        try validatePage(limit: limit, offset: offset); try validateKind(kind)
        let reader = try openDatabase(dbPath: db, key: key)
        defer { reader.close() }

        let chats = try reader.chats(limit: limit, offset: offset, kind: kind, contacted: contacted)

        if page {
            try printPage(chats.map(chatJSON), total: reader.countChats(kind: kind, contacted: contacted), limit: limit,
                          offset: offset, databasePath: reader.databasePath)
        } else if json {
            JSONOutput.printArray(chats.map(chatJSON))
        } else {
            if chats.isEmpty {
                print("No chats found.")
                return
            }
            for chat in chats {
                let unread = chat.unreadCount > 0 ? " (\(chat.unreadCount) unread)" : ""
                let time = chat.lastMessageAt.map { formatDate($0) } ?? ""
                print("[\(chat.id)] \(chat.displayName)\(unread) \(time)")
            }
        }
    }
}

func openDatabase(dbPath: String?, key: String?, userId userIdOverride: Int? = nil) throws -> DatabaseReader {
    try LocalDatabase.open(databasePath: dbPath, key: key, userId: userIdOverride)
}

func formatDate(_ date: Date) -> String {
    let formatter = DateFormatter()
    let calendar = Calendar.current
    if calendar.isDateInToday(date) {
        formatter.dateFormat = "HH:mm"
    } else if calendar.isDateInYesterday(date) {
        return "yesterday"
    } else {
        formatter.dateFormat = "MM/dd"
    }
    return formatter.string(from: date)
}
