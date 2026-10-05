import Foundation

/// A KakaoTalk message.
public struct Message: Sendable {
    public let id: Int64
    public let chatId: Int64
    public let senderId: Int64
    public let senderName: String?
    public let text: String?
    public let type: MessageType
    public let createdAt: Date
    public let isFromMe: Bool
    public let messageId: Int64
    public let previousId: Int64
    public let rawType: Int
    public let attachment: String?
    public let supplement: String?

    public enum MessageType: Int, Sendable {
        case text = 1
        case photo = 2
        case video = 3
        case voice = 4
        case sticker = 5
        case file = 6
        case location = 7
        case system = 0
        case unknown = -1

        public init(rawValue: Int) {
            switch rawValue {
            case 1: self = .text
            case 2: self = .photo
            case 3: self = .video
            case 4: self = .voice
            case 5: self = .sticker
            case 6: self = .file
            case 7: self = .location
            case 0: self = .system
            default: self = .unknown
            }
        }
    }
}
