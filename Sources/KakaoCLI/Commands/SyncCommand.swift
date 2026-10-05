import ArgumentParser
import Foundation
import KakaoCore

struct SyncCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "sync",
        abstract: "Watch for new messages and output as JSON (for AI agents)"
    )

    @Flag(name: .long, help: "Continuously watch for new messages (NDJSON output)")
    var follow = false

    @Option(name: .long, help: "POST new messages to this webhook URL")
    var webhook: String?

    @Option(name: .long, help: "Poll interval in seconds (default: 2)")
    var interval: Double = 2.0

    @Option(name: .long, help: "Start from this logId (default: latest)")
    var sinceLogId: Int64?

    @Option(name: .long, help: "Path to database file")
    var db: String?

    @Option(name: .long, help: "Database encryption key")
    var key: String?

    func run() throws {
        let (path, secureKey) = try resolveDatabasePath(dbPath: db, key: key)

        if !follow && webhook == nil {
            // One-shot: show current high-water mark
            let reader = DatabaseReader(databasePath: path)
            try reader.open(key: secureKey)
            defer { reader.close() }
            let maxId = try reader.maxLogId()
            print("{\"status\":\"ready\",\"max_log_id\":\(maxId)}")
            return
        }

        let webhookPublisher: WebhookPublisher?
        if let webhookUrl = webhook, let url = URL(string: webhookUrl) {
            webhookPublisher = WebhookPublisher(url: url)
            fputs("Webhook: \(webhookUrl)\n", stderr)
        } else {
            webhookPublisher = nil
        }

        let watcher = DatabaseWatcher(
            databasePath: path,
            key: secureKey,
            pollInterval: interval,
            startFromLogId: sinceLogId
        )

        // Handle Ctrl-C gracefully
        signal(SIGINT) { _ in
            fputs("\nStopping sync...\n", stderr)
            Darwin.exit(0)
        }

        fputs("Watching for new messages (poll every \(interval)s)...\n", stderr)

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]

        watcher.watch(
            onMessages: { messages in
                for msg in messages {
                    // NDJSON: one JSON object per line
                    if let data = try? encoder.encode(msg),
                       let line = String(data: data, encoding: .utf8) {
                        print(line)
                        fflush(stdout)
                    }
                }
                // Also publish to webhook if configured
                if let publisher = webhookPublisher {
                    if !publisher.publish(messages) {
                        fputs("Warning: webhook delivery failed\n", stderr)
                    }
                }
            },
            onError: { error in
                fputs("Error: \(error)\n", stderr)
            }
        )
    }
}

/// Validate the local database and resolve its path and key for the watcher.
func resolveDatabasePath(dbPath: String?, key: String?) throws -> (path: String, key: String?) {
    let reader = try LocalDatabase.open(databasePath: dbPath, key: key)
    defer { reader.close() }
    if let key { return (reader.databasePath, key) }
    if try LocalDatabase.isPlaintext(databasePath: reader.databasePath) { return (reader.databasePath, nil) }
    if let configuration = try LocalDatabaseConfiguration.load() {
        return (reader.databasePath, KeyDerivation.secureKey(userId: configuration.userId, uuid: configuration.uuid))
    }
    return (reader.databasePath, nil)
}
