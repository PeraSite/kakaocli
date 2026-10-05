import Foundation

public struct ContactCandidate: Sendable {
    public let chat: Chat
    public let myMatches: Int
    public let otherMatches: Int
    public let firstContactAt: Date?
    public let lastContactAt: Date?
    public let titleMatches: [String]
    public var evidence: [Message]
}

extension DatabaseReader {
    private func firstName(_ values: String?...) -> String? {
        values.compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }.first { !$0.isEmpty }
    }

    public func localChats() throws -> [Chat] {
        let own = try myUserId()
        let userRows = try query("SELECT userId,linkId,displayName,friendNickName,nickName FROM NTUser", bind: []) { row in
            (row.int64(0), row.int64(1), self.firstName(row.string(2), row.string(3), row.string(4)))
        }
        var userNames: [String: String] = [:]
        for (id, link, name) in userRows { if let name { userNames["\(id):\(link)"] = name } }
        let sql = """
            SELECT r.chatId,r.linkId,r.type,r.chatName,r.activeMembersCount,r.lastLogId,r.lastUpdatedAt,
                   r.countOfNewMessage,r.directChatMemberUserId,r.displayMemberIds,
                   m.groupNickname,m.content,l.linkName,coalesce(s.n,0),coalesce(s.sent,0)
            FROM NTChatRoom r
            LEFT JOIN NTChatMeta m ON m.chatId=r.chatId AND m.type=3
            LEFT JOIN NTOpenLink l ON l.linkId=r.linkId
            LEFT JOIN (SELECT chatId,count(*) AS n,sum(authorId=?) AS sent FROM NTChatMessage GROUP BY chatId) s ON s.chatId=r.chatId
            WHERE r.chatId>0 ORDER BY r.lastUpdatedAt DESC,r.chatId DESC
            """
        return try query(sql, bind: [.int64(own)]) { row in
            let link = row.int64(1), direct = row.int64(8)
            let kind = Chat.Kind.classify(rawType: row.int(2), linkId: link)
            let choices: [(String, String?)] = [
                ("chatName", self.firstName(row.string(3))),
                ("NTChatMeta.type3", self.firstName(row.string(10),row.string(11))),
                ("NTOpenLink.linkName", self.firstName(row.string(12))),
                ("NTUser", userNames["\(direct):\(link)"] ?? userNames["\(direct):0"]),
            ]
            var picked = choices.first { $0.1 != nil }
            if picked == nil, kind == .selfChat { picked = ("self", "나와의 채팅") }
            if picked == nil, let data = row.data(9),
               let ids = (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [NSNumber] {
                let names = ids.map(\.int64Value).filter { $0 != own }.compactMap { userNames["\($0):\(link)"] ?? userNames["\($0):0"] }
                if !names.isEmpty { picked = ("displayMemberIds", names.prefix(6).joined(separator: ", ") + (names.count > 6 ? " 외" : "")) }
            }
            let type: Chat.ChatType = kind == .openDirect || kind == .openGroup ? .openChat :
                kind == .channel ? .channel : kind == .selfChat ? .selfChat : kind == .direct ? .direct : kind == .group ? .group : .unknown
            return Chat(id: row.int64(0), type: type, displayName: picked?.1 ?? "(unknown)",
                        memberCount: row.int(4), lastMessageId: row.optionalInt64(5), lastMessageAt: row.optionalKakaoDate(6),
                        unreadCount: row.int(7), linkId: link, kind: kind, nameSource: picked?.0 ?? "unresolved",
                        messageCount: row.int(13), sentMessageCount: row.int(14))
        }
    }

    public func countChats(kind: String? = nil, contacted: Bool = false) throws -> Int {
        try localChats().filter { $0.kind.matches(kind) && (!contacted || $0.sentMessageCount > 0) }.count
    }

    private var messageSelect: String {
        """
        SELECT m.logId,m.chatId,m.authorId,
          coalesce(nullif(u1.displayName,''),nullif(u1.friendNickName,''),nullif(u1.nickName,''),
                   nullif(u0.displayName,''),nullif(u0.friendNickName,''),nullif(u0.nickName,'')),
          m.message,m.type,m.sentAt,m.msgId,m.prevId,m.attachment,m.supplement
        FROM NTChatMessage m
        LEFT JOIN NTChatRoom r ON r.chatId=m.chatId AND r.chatId>0
        LEFT JOIN NTUser u1 ON u1.userId=m.authorId AND u1.linkId=coalesce(r.linkId,0)
        LEFT JOIN NTUser u0 ON u0.userId=m.authorId AND u0.linkId=0
        """
    }

    private func message(_ row: Row, own: Int64) -> Message {
        Message(id: row.int64(0), chatId: row.int64(1), senderId: row.int64(2), senderName: row.string(3),
                text: row.string(4), type: .init(rawValue: row.int(5)), createdAt: row.kakaoDate(6),
                isFromMe: row.int64(2) == own, messageId: row.int64(7), previousId: row.int64(8), rawType: row.int(5),
                attachment: row.string(9), supplement: row.string(10))
    }

    private func messageFilters(chatId: Int64?, since: Date?, text: String?, sender: String) throws -> (String, [SQLValue]) {
        var conditions: [String] = [], values: [SQLValue] = []
        if let chatId { conditions.append("m.chatId=?"); values.append(.int64(chatId)) }
        if let since { conditions.append("m.sentAt>=?"); values.append(.double(since.timeIntervalSince1970)) }
        if let text { conditions.append("instr(lower(coalesce(m.message,'')),lower(?))>0"); values.append(.string(text)) }
        if sender != "any" { conditions.append(sender == "me" ? "m.authorId=?" : "m.authorId!=?"); values.append(.int64(try myUserId())) }
        return (conditions.isEmpty ? "" : " WHERE " + conditions.joined(separator: " AND "), values)
    }

    func localMessages(chatId: Int64? = nil, since: Date? = nil, text: String? = nil,
                       limit: Int = 50, offset: Int = 0, sender: String = "any") throws -> [Message] {
        let (whereSQL, values) = try messageFilters(chatId: chatId, since: since, text: text, sender: sender)
        let own = try myUserId()
        return try query(messageSelect + whereSQL + " ORDER BY m.sentAt DESC,m.logId DESC,m.msgId DESC LIMIT ? OFFSET ?",
                         bind: values + [.int(limit), .int(offset)]) { self.message($0, own: own) }
    }

    public func countMessages(chatId: Int64? = nil, since: Date? = nil, text: String? = nil, sender: String = "any") throws -> Int {
        let (whereSQL, values) = try messageFilters(chatId: chatId, since: since, text: text, sender: sender)
        return try query("SELECT count(*) FROM NTChatMessage m" + whereSQL, bind: values) { $0.int(0) }.first ?? 0
    }

    public func context(chatId: Int64, logId: Int64, messageId: Int64? = nil, before: Int = 5, after: Int = 5) throws -> [Message] {
        var values: [SQLValue] = [.int64(chatId), .int64(logId)]
        let condition = messageId == nil ? "" : " AND msgId=?"
        if let messageId { values.append(.int64(messageId)) }
        let points = try query("SELECT sentAt,logId,msgId FROM NTChatMessage WHERE chatId=? AND logId=?" + condition, bind: values) {
            [$0.int64(0), $0.int64(1), $0.int64(2)]
        }
        guard points.count == 1, let point = points.first else {
            throw KakaoError.sqlError("Expected one target message, found \(points.count); supply --msg-id if ambiguous")
        }
        let own = try myUserId()
        let common: [SQLValue] = [.int64(chatId)] + point.map { .int64($0) }
        let prefix = messageSelect + " WHERE m.chatId=? AND (m.sentAt,m.logId,m.msgId)"
        let earlier = try query(prefix + "<(?,?,?) ORDER BY m.sentAt DESC,m.logId DESC,m.msgId DESC LIMIT ?", bind: common + [.int(before)]) { self.message($0, own: own) }
        let later = try query(prefix + ">=(?,?,?) ORDER BY m.sentAt,m.logId,m.msgId LIMIT ?", bind: common + [.int(after + 1)]) { self.message($0, own: own) }
        return Array(earlier.reversed()) + later
    }

    public func contactCandidates(terms: [String], titleTerms: [String], kind: String? = nil,
                                  includeUncontacted: Bool = false) throws -> [ContactCandidate] {
        guard !terms.isEmpty else { return [] }
        let own = try myUserId()
        let expression = "(" + terms.map { _ in "instr(lower(coalesce(message,'')),lower(?))>0" }.joined(separator: " OR ") + ")"
        let sql = """
            SELECT chatId,sum(CASE WHEN authorId=? AND \(expression) THEN 1 ELSE 0 END),
                   sum(CASE WHEN authorId!=? AND \(expression) THEN 1 ELSE 0 END),
                   min(CASE WHEN authorId=? THEN sentAt END),max(CASE WHEN authorId=? THEN sentAt END)
            FROM NTChatMessage GROUP BY chatId
            """
        let values: [SQLValue] = [.int64(own)] + terms.map { .string($0) } + [.int64(own)] + terms.map { .string($0) } + [.int64(own), .int64(own)]
        let rows = try query(sql, bind: values) { ($0.int64(0),$0.int(1),$0.int(2),$0.optionalKakaoDate(3),$0.optionalKakaoDate(4)) }
        var matches: [Int64: (Int, Int, Date?, Date?)] = [:]
        for row in rows { matches[row.0] = (row.1,row.2,row.3,row.4) }
        let titleWords = titleTerms.isEmpty ? terms : titleTerms
        return try localChats().compactMap { chat in
            guard chat.kind != .selfChat, chat.kind.matches(kind),
                  includeUncontacted || chat.sentMessageCount > 0, let match = matches[chat.id] else { return nil }
            let titles = titleWords.filter { chat.displayName.localizedCaseInsensitiveContains($0) }
            guard !titles.isEmpty || match.0 > 0 || match.1 > 0 else { return nil }
            return ContactCandidate(chat: chat, myMatches: match.0, otherMatches: match.1,
                                    firstContactAt: match.2, lastContactAt: match.3, titleMatches: titles, evidence: [])
        }.sorted {
            if $0.lastContactAt != $1.lastContactAt { return ($0.lastContactAt ?? .distantPast) > ($1.lastContactAt ?? .distantPast) }
            return $0.chat.id > $1.chat.id
        }
    }

    public func candidateEvidence(chatId: Int64, terms: [String], limit: Int = 1) throws -> [Message] {
        let own = try myUserId()
        let expression = "(" + terms.map { _ in "instr(lower(coalesce(m.message,'')),lower(?))>0" }.joined(separator: " OR ") + ")"
        let sql = messageSelect + " WHERE m.chatId=? ORDER BY CASE WHEN m.authorId=? AND \(expression) THEN 0 WHEN \(expression) THEN 1 ELSE 2 END,m.sentAt DESC,m.logId DESC,m.msgId DESC LIMIT ?"
        let values: [SQLValue] = [.int64(chatId), .int64(own)] + terms.map { .string($0) } + terms.map { .string($0) } + [.int(limit)]
        return try query(sql, bind: values) { self.message($0, own: own) }
    }
}
