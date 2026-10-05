import ArgumentParser
import Foundation
import KakaoCore

func validatePage(limit: Int, offset: Int) throws {
    guard (1...1_000_000).contains(limit), offset >= 0 else { throw ValidationError("--limit must be 1...1000000 and --offset must be nonnegative") }
}

func validateKind(_ kind: String?) throws {
    guard let kind else { return }
    guard Chat.Kind.allCases.map(\.rawValue).contains(kind) || ["open", "one-to-one"].contains(kind) else {
        throw ValidationError("--kind: direct, group, channel, open-direct, open-group, open, one-to-one, self, unknown")
    }
}

func validateSender(_ sender: String) throws {
    guard ["any", "me", "others"].contains(sender) else { throw ValidationError("--sender: any, me, others") }
}

func chatJSON(_ chat: Chat) -> [String: Any] {
    var item: [String: Any] = ["id": String(chat.id), "chat_id": String(chat.id), "link_id": String(chat.linkId),
        "type": chat.type.rawValue, "kind": chat.kind.rawValue, "display_name": chat.displayName,
        "name_source": chat.nameSource, "member_count": chat.memberCount, "unread_count": chat.unreadCount,
        "message_count": chat.messageCount, "sent_message_count": chat.sentMessageCount]
    if let date = chat.lastMessageAt { item["last_message_at"] = ISO8601DateFormatter().string(from: date) }
    return item
}

func messageJSON(_ message: Message) -> [String: Any] {
    var item: [String: Any] = ["id": String(message.id), "log_id": String(message.id), "chat_id": String(message.chatId),
        "msg_id": String(message.messageId), "prev_id": String(message.previousId), "sender_id": String(message.senderId),
        "type": message.rawType, "message_kind": String(describing: message.type),
        "timestamp": ISO8601DateFormatter().string(from: message.createdAt), "is_from_me": message.isFromMe]
    let kst = ISO8601DateFormatter(); kst.timeZone = TimeZone(identifier: "Asia/Seoul")
    item["timestamp_kst"] = kst.string(from: message.createdAt)
    if let sender = message.senderName { item["sender"] = sender }
    if let text = message.text { item["text"] = text }
    if let attachment = message.attachment { item["attachment"] = attachment }
    if let supplement = message.supplement { item["supplement"] = supplement }
    return item
}

func printPage(_ rows: [[String: Any]], total: Int, limit: Int, offset: Int, databasePath: String,
               additional: [String: Any] = [:]) throws {
    var item = additional
    item["total"] = total; item["limit"] = limit; item["offset"] = offset; item["rows"] = rows
    item["next_offset"] = offset + rows.count < total ? offset + rows.count : NSNull()
    item["database_path"] = databasePath; item["read_only"] = true
    try JSONOutput.printObject(item)
}
