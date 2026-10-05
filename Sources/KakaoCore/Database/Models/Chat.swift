import Foundation

/// A KakaoTalk chat room.
public struct Chat: Sendable {
    public let id: Int64
    public let type: ChatType
    public let displayName: String
    public let memberCount: Int
    public let lastMessageId: Int64?
    public let lastMessageAt: Date?
    public let unreadCount: Int
    public let linkId: Int64
    public let kind: Kind
    public let nameSource: String
    public let messageCount: Int
    public let sentMessageCount: Int

    public enum Kind: String, Sendable, CaseIterable {
        case direct, group, channel, selfChat = "self", unknown
        case openDirect = "open-direct", openGroup = "open-group"

        public static func classify(rawType: Int, linkId: Int64) -> Self {
            if linkId > 0, rawType == 3 { return .openDirect }
            if linkId > 0, rawType == 4 { return .openGroup }
            switch rawType {
            case 0: return .direct
            case 1: return .group
            case 2: return .channel
            case 5: return .selfChat
            default: return .unknown
            }
        }

        public func matches(_ filter: String?) -> Bool {
            guard let filter else { return true }
            if filter == "open" { return self == .openDirect || self == .openGroup }
            if filter == "one-to-one" { return self == .direct || self == .channel || self == .openDirect }
            return rawValue == filter
        }
    }

    public enum ChatType: String, Sendable {
        case direct = "direct"
        case group = "group"
        case openChat = "open"
        case channel, selfChat = "self"
        case unknown = "unknown"
    }
}
