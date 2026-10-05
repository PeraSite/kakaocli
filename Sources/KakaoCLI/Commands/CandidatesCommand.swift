import ArgumentParser
import Foundation
import KakaoCore

struct CandidatesCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "candidates", abstract: "Find contacted people/store candidates from names and message evidence")
    @Option(name: .customLong("term"), parsing: .upToNextOption, help: "Message terms (repeatable OR matching)") var terms: [String] = []
    @Option(name: .customLong("title-term"), parsing: .upToNextOption) var titleTerms: [String] = []
    @Option(name: .long) var kind: String?
    @Option(name: .long) var limit = 40
    @Option(name: .long) var offset = 0
    @Option(name: .long, help: "Evidence messages per candidate, 0...5") var evidence = 1
    @Flag(name: .long) var includeUncontacted = false
    @Flag(name: .long) var json = false
    @Flag(name: .long) var page = false
    @Option(name: .long) var db: String?
    @Option(name: .long) var key: String?

    func run() throws {
        try validatePage(limit: limit, offset: offset); try validateKind(kind)
        guard !terms.isEmpty, terms.allSatisfy({ !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }),
              (0...5).contains(evidence) else { throw ValidationError("Supply nonempty --term values and --evidence 0...5") }
        let reader = try openDatabase(dbPath: db, key: key); defer { reader.close() }
        let all = try reader.contactCandidates(terms: terms, titleTerms: titleTerms, kind: kind, includeUncontacted: includeUncontacted)
        let candidates = Array(all.dropFirst(offset).prefix(limit))
        var items: [[String: Any]] = []
        for candidate in candidates {
            var item = chatJSON(candidate.chat)
            item["my_matches"] = candidate.myMatches; item["other_matches"] = candidate.otherMatches
            item["title_matches"] = candidate.titleMatches
            item["review_note"] = candidate.chat.kind == .group || candidate.chat.kind == .openGroup ? "group_member_identity_required" :
                candidate.chat.kind == .channel ? "store_channel_not_verified_person" : "role_requires_context_review"
            if let date = candidate.firstContactAt { item["first_contact_at"] = ISO8601DateFormatter().string(from: date) }
            if let date = candidate.lastContactAt { item["last_contact_at"] = ISO8601DateFormatter().string(from: date) }
            if evidence > 0 {
                item["evidence"] = try reader.candidateEvidence(chatId: candidate.chat.id, terms: terms, limit: evidence).map { message in
                    var row = messageJSON(message)
                    if let text = message.text { row["text"] = String(text.prefix(400)); row["truncated"] = text.count > 400 }
                    row.removeValue(forKey: "attachment"); row.removeValue(forKey: "supplement")
                    return row
                }
            }
            items.append(item)
        }
        if page || json {
            try printPage(items, total: all.count, limit: limit, offset: offset, databasePath: reader.databasePath,
                          additional: ["candidate_list_only": true, "terms": terms])
        } else { for candidate in candidates { print("[\(candidate.chat.id)] \(candidate.chat.displayName) · \(candidate.chat.kind.rawValue) · \(candidate.myMatches) sent matches") } }
    }
}
