import ArgumentParser
import Foundation
import KakaoCore

struct QueryCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "query",
        abstract: "Run a raw SQL query (read-only)"
    )

    @Argument(help: "SQL query to execute")
    var sql: String

    @Option(name: .long, help: "Path to database file")
    var db: String?

    @Option(name: .long, help: "Database encryption key")
    var key: String?
    @Flag(name: .long, help: "Return objects with column names; ID columns are strings")
    var named = false

    func run() throws {
        let reader = try openDatabase(dbPath: db, key: key)
        defer { reader.close() }

        if named { JSONOutput.printArray(try reader.rawNamedQuery(sql)); return }
        let results = try reader.rawQuery(sql)

        let encoder = JSONSerialization.self
        let data = try encoder.data(withJSONObject: results, options: [.prettyPrinted, .sortedKeys])
        if let str = String(data: data, encoding: .utf8) {
            print(str)
        }
    }
}
