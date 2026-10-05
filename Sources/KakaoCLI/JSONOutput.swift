import Foundation

/// Shared JSON encoding for CLI output.
enum JSONOutput {
    private static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        e.dateEncodingStrategy = .iso8601
        return e
    }()

    static func print<T: Encodable>(_ value: T) throws {
        let data = try encoder.encode(value)
        Swift.print(String(data: data, encoding: .utf8)!)
    }

    static func printArray(_ items: [[String: Any]]) {
        guard let data = try? JSONSerialization.data(
            withJSONObject: items,
            options: [.prettyPrinted, .sortedKeys]
        ) else { return }
        Swift.print(String(data: data, encoding: .utf8)!)
    }

    static func printObject(_ item: [String: Any]) throws {
        let data = try JSONSerialization.data(withJSONObject: item, options: [.prettyPrinted, .sortedKeys])
        Swift.print(String(data: data, encoding: .utf8)!)
    }
}
