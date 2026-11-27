import ArgumentParser
import Foundation
import KakaoCore

/// Send a text message through the KakaoTalk app (Accessibility only, never LOCO) and confirm it in the local DB.
struct SendCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "send",
        abstract: "Send a message through the KakaoTalk app UI and confirm it in the local DB (no LOCO)",
        discussion: """
        Needs Full Disk Access (to resolve the chat and confirm delivery) and Accessibility (to type and press send)
        for this executable. Check with `kakaocli permissions`.

          kakaocli send "Chat name" "Hello"             # name: exact, else a unique substring
          kakaocli send --chat-id 1234567890 "Hello"
          kakaocli send --me "note to self"
          echo "Hello" | kakaocli send "Chat name" -     # message from stdin

        Exit codes: 0 sent and confirmed (or dry run ok), 1 not sent, 2 chat not resolved, 3 pressed send but not confirmed.
        """
    )

    @Argument(help: "Chat name (exact, else unique substring) or chat ID. Omit with --chat-id or --me")
    var chat: String?

    @Argument(help: "Message text, or - to read stdin")
    var message: String?

    @Option(name: .customLong("chat-id"), help: "Chat ID (from `kakaocli chats`)")
    var chatId: Int64?

    @Option(name: .customLong("file"), help: "Read the message from a file")
    var file: String?

    @Flag(name: [.customLong("me")], help: "Send to your own chat (나와의 채팅)")
    var selfChat = false

    @Flag(name: .long, help: "Open the chat, put the text in and clear it again; do not send")
    var dryRun = false

    @Flag(name: .long, help: "Do not wait for the message to appear in the local DB")
    var noVerify = false

    @Flag(name: .long, help: "Print one JSON object")
    var json = false

    @Option(name: .long, help: "Path to database file")
    var db: String?

    @Option(name: .long, help: "Database encryption key")
    var key: String?

    mutating func run() throws {
        // With --chat-id/--me the only positional argument is the message.
        if (chatId != nil || selfChat), message == nil { message = chat; chat = nil }
        var text = message ?? ""
        if let file { text = try String(contentsOfFile: file, encoding: .utf8) }
        if text == "-" { text = String(data: FileHandle.standardInput.readDataToEndOfFile(), encoding: .utf8) ?? "" }
        while text.hasSuffix("\n") { text.removeLast() }
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return finish(["ok": false, "step": "EMPTY_MESSAGE"], 1) }

        let reader = try openDatabase(dbPath: db, key: key)
        defer { reader.close() }
        let all = try reader.chats(limit: 1_000_000)
        let target: Chat
        switch resolve(all) {
        case .success(let c): target = c
        case .failure(let r): return finish(r.result, 2)
        }

        // Main-window order and the one-to-one peer, both from NTChatRoom.
        let rows = try reader.rawNamedQuery("""
            SELECT chatId, coalesce(type,0) AS t, coalesce(pin,-1) AS pin, coalesce(countOfNewMessage,0)>0 AS unread,
            coalesce(lastUpdatedAt,0) AS last, coalesce(linkId,0)>0 AS open, coalesce(vtype,0) AS vtype,
            coalesce(directChatMemberUserId,0) AS peerId, coalesce(linkId,0) AS linkId FROM NTChatRoom
            """)
        let split = (try? reader.rawNamedQuery("SELECT boolValue AS v FROM NTSetting WHERE key='openchatlist_issperated'"))?
            .first.flatMap { int($0["v"]) } ?? 0
        let list = rows.map { r in
            ChatListRow(chatId: Int64(string(r["chatId"])) ?? 0, type: Int(int(r["t"]) ?? 0), pin: Int(int(r["pin"]) ?? -1),
                        unread: (int(r["unread"]) ?? 0) != 0, lastUpdatedAt: int(r["last"]) ?? 0,
                        isOpen: (int(r["open"]) ?? 0) != 0, vtype: Int(int(r["vtype"]) ?? 0),
                        linkId: Int64(string(r["linkId"])) ?? 0)
        }
        let place = ChatListOrder.guess(list, chatId: target.id, splitOpenList: split != 0)
        let me = rows.first { string($0["chatId"]) == String(target.id) }
        // Chats that came in through a one-to-one open chat link you host share one list row named after the link.
        var group: String?
        if place.grouped {
            let link = string(me?["linkId"])
            let name = (try? reader.rawNamedQuery("SELECT coalesce(linkName,'') AS n FROM NTOpenLink WHERE linkId=\(Int64(link) ?? 0)"))?
                .first.map { string($0["n"]) } ?? ""
            guard !name.isEmpty else { return finish(["ok": false, "step": "GROUP_NAME_UNKNOWN", "chat": target.displayName], 1) }
            group = name
        }
        let peer = target.kind == .direct ? Int64(string(me?["peerId"])).flatMap { $0 > 0 ? $0 : nil } : nil

        let myId = try reader.myUserId()
        let before = try reader.rawNamedQuery("SELECT coalesce(max(logId),0) AS m FROM NTChatMessage WHERE chatId=\(target.id)")
            .first.flatMap { Int64(string($0["m"])) } ?? 0

        var res = FastSender.send(FastSendRequest(chatId: target.id, title: target.displayName, text: text, dryRun: dryRun,
                                                  side: place.side, guesses: place.guesses, peerUserId: peer, group: group))
        res["chat"] = target.displayName
        res["chat_id"] = String(target.id)
        if dryRun { return finish(res, (res["ok"] as? Bool) == true ? 0 : 1) }
        guard (res["pressed"] as? Bool) == true else { return finish(res, 1) }
        if noVerify { return finish(res, (res["ok"] as? Bool) == true ? 0 : 3) }

        // Confirm in the local DB: a new message from me in this chat with exactly this text.
        let want = norm(text)
        let deadline = Date().addingTimeInterval(8)
        while Date() < deadline {
            let mine = try reader.rawNamedQuery("""
                SELECT logId, coalesce(message,'') AS message FROM NTChatMessage
                WHERE chatId=\(target.id) AND authorId=\(myId) AND logId>\(before) ORDER BY logId DESC LIMIT 5
                """)
            if let hit = mine.first(where: { norm(string($0["message"])) == want }) {
                res["ok"] = true; res["verified"] = true; res["log_id"] = string(hit["logId"])
                return finish(res, 0)
            }
            Thread.sleep(forTimeInterval: 0.2)
        }
        res["ok"] = false; res["verified"] = false
        res["error"] = "Send was pressed but the message is not in the local DB yet. Check KakaoTalk before retrying."
        return finish(res, 3)
    }

    private struct Unresolved: Error { let result: [String: Any] }

    private func resolve(_ all: [Chat]) -> Result<Chat, Unresolved> {
        var hits: [Chat]
        if selfChat { hits = all.filter { $0.kind == .selfChat } }
        else if let chatId { hits = all.filter { $0.id == chatId } }
        else if let q = chat, let id = Int64(q), all.contains(where: { $0.id == id }) { hits = all.filter { $0.id == id } }
        else if let q = chat?.precomposedStringWithCanonicalMapping, !q.isEmpty {
            let exact = all.filter { $0.displayName.precomposedStringWithCanonicalMapping == q }
            hits = exact.isEmpty ? all.filter { $0.displayName.precomposedStringWithCanonicalMapping.contains(q) } : exact
        } else { hits = [] }
        if hits.count == 1 { return .success(hits[0]) }
        return .failure(Unresolved(result: [
            "ok": false, "step": hits.isEmpty ? "CHAT_NOT_FOUND" : "CHAT_AMBIGUOUS",
            "candidates": hits.prefix(10).map { ["chat_id": String($0.id), "name": $0.displayName, "kind": $0.kind.rawValue] },
        ]))
    }

    private func finish(_ res: [String: Any], _ code: Int32) {
        if json {
            try? JSONOutput.printObject(res)
        } else if (res["ok"] as? Bool) == true {
            print(dryRun ? "DRY RUN OK: \(res["chat"] ?? "")" : "Sent to '\(res["chat"] ?? "")' (\(res["how"] ?? ""), \(res["ms_end"] ?? "?") ms)")
        } else {
            FileHandle.standardError.write(Data("Not sent: \(res["step"] ?? res["error"] ?? "unknown") \(res["candidates"].map { "\($0)" } ?? "")\n".utf8))
        }
        if code != 0 { Foundation.exit(code) }
    }
}

private func string(_ v: Any?) -> String {
    switch v { case let s as String: return s; case let n as Int64: return String(n); case let n as Int: return String(n); default: return "" }
}
private func int(_ v: Any?) -> Int64? {
    switch v { case let n as Int64: return n; case let n as Int: return Int64(n); case let s as String: return Int64(s); default: return nil }
}
private func norm(_ s: String) -> String {
    s.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
}
