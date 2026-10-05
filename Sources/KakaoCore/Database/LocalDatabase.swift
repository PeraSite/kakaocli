import Foundation

/// Only local identifiers are cached. The derived passphrase is never persisted.
public struct LocalDatabaseConfiguration: Codable, Sendable {
    public let databasePath: String
    public let userId: Int
    public let uuid: String
    public let preferencesDirectory: String?

    public init(databasePath: String, userId: Int, uuid: String, preferencesDirectory: String? = nil) {
        self.databasePath = databasePath; self.userId = userId; self.uuid = uuid
        self.preferencesDirectory = preferencesDirectory
    }

    public static var defaultPath: String {
        ProcessInfo.processInfo.environment["KAKAOCLI_CONFIG"] ??
            FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".kakaocli/config.json").path
    }

    public static func load(path: String = defaultPath) throws -> Self? {
        guard FileManager.default.fileExists(atPath: path) else { return nil }
        let value = try JSONDecoder().decode(Self.self, from: Data(contentsOf: URL(fileURLWithPath: path)))
        guard value.userId > 0, !value.uuid.isEmpty, !value.databasePath.isEmpty else {
            throw KakaoError.databaseOpenFailed("Invalid local configuration; run kakaocli auth --save again")
        }
        return value
    }

    public func save(path: String = Self.defaultPath) throws {
        let url = URL(fileURLWithPath: path)
        let directory = url.deletingLastPathComponent()
        let fm = FileManager.default
        if !fm.fileExists(atPath: directory.path) {
            try fm.createDirectory(at: directory, withIntermediateDirectories: true,
                                   attributes: [.posixPermissions: 0o700])
        }
        let data = try JSONEncoder().encode(self)
        let temporary = directory.appendingPathComponent(".config-\(UUID().uuidString).tmp")
        guard fm.createFile(atPath: temporary.path, contents: data, attributes: [.posixPermissions: 0o600]) else {
            throw KakaoError.databaseOpenFailed("Cannot create private local configuration")
        }
        defer { try? fm.removeItem(at: temporary) }
        if fm.fileExists(atPath: path) {
            _ = try fm.replaceItemAt(url, withItemAt: temporary)
        } else { try fm.moveItem(at: temporary, to: url) }
        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path)
    }
}

public enum LocalDatabase {
    public static func isPlaintext(databasePath: String) throws -> Bool {
        let handle = try FileHandle(forReadingFrom: URL(fileURLWithPath: databasePath))
        defer { try? handle.close() }
        return try handle.read(upToCount: 16) == Data("SQLite format 3\0".utf8)
    }

    public static func discover(in directory: String = DeviceInfo.containerPath) throws -> [String] {
        let entries = try FileManager.default.contentsOfDirectory(atPath: directory)
        return entries.sorted().compactMap { file in
            let name = file.hasSuffix(".db") ? String(file.dropLast(3)) : file
            guard name.count == 78, name.allSatisfy({ $0.isHexDigit }) else { return nil }
            return URL(fileURLWithPath: directory).appendingPathComponent(file).path
        }
    }

    public static func configure(databasePath: String? = nil, preferencesDirectory: String? = nil,
                                 userId: Int? = nil, uuid: String? = nil, timeout: Double = 120,
                                 maxId: UInt64 = 6_000_000_000, workers: Int? = nil,
                                 progress: ((String) -> Void)? = nil) throws -> LocalDatabaseConfiguration {
        let deviceUUID = try uuid ?? DeviceInfo.platformUUID()
        let paths = try databasePath.map { [$0] } ?? discover()
        guard !paths.isEmpty else { throw KakaoError.databaseNotFound(DeviceInfo.containerPath) }
        for path in paths {
            // Surface OS access failures before attempting any expensive recovery.
            let handle = try FileHandle(forReadingFrom: URL(fileURLWithPath: path)); try handle.close()
        }
        func verify(_ id: Int) -> LocalDatabaseConfiguration? {
            guard id > 0 else { return nil }
            let expected = KeyDerivation.databaseName(userId: id, uuid: deviceUUID)
            for path in paths {
                let filename = (path as NSString).lastPathComponent
                guard filename == expected || filename == expected + ".db" || databasePath != nil else { continue }
                let reader = DatabaseReader(databasePath: path)
                defer { reader.close() }
                guard reader.tryOpen(key: KeyDerivation.secureKey(userId: id, uuid: deviceUUID)),
                      (try? reader.myUserId()) == Int64(id) else { continue }
                return .init(databasePath: path, userId: id, uuid: deviceUUID, preferencesDirectory: preferencesDirectory)
            }
            return nil
        }
        if let userId {
            guard let configuration = verify(userId) else {
                throw KakaoError.databaseOpenFailed("Provided user ID did not decrypt this local database")
            }
            return configuration
        }
        let preferences = try DeviceInfo.localPreferences(directory: preferencesDirectory)
        let hashes = DeviceInfo.localAccountHashes(from: preferences)
        for candidate in DeviceInfo.localCandidateUserIds(from: preferences) {
            if !hashes.isEmpty, !hashes.contains(DeviceInfo.sha512Hex(String(candidate))) { continue }
            if let configuration = verify(candidate) { return configuration }
        }
        guard !hashes.isEmpty else {
            throw KakaoError.userIdNotFound(["No active account hash in local preferences. Supply --preferences-dir or --user-id; server login is unnecessary."])
        }
        let started = Date()
        for hash in hashes {
            let remaining = timeout - Date().timeIntervalSince(started)
            guard remaining > 0 else { break }
            progress?("Recovering local account identifier with native parallel SHA-512 search...")
            if let id = DeviceInfo.recoverUserIdFromSHA512(hexHash: hash, maxId: maxId, timeout: remaining, workers: workers),
               let configuration = verify(id) { return configuration }
        }
        throw KakaoError.userIdNotFound(["Local recovery exhausted or timed out. Increase --recover-timeout/--max-user-id, or provide --user-id."])
    }

    public static func open(databasePath: String? = nil, key: String? = nil, userId: Int? = nil) throws -> DatabaseReader {
        if let databasePath, key == nil, try isPlaintext(databasePath: databasePath) {
            let reader = DatabaseReader(databasePath: databasePath); try reader.open(); return reader
        }
        if let key {
            let path = try databasePath ?? LocalDatabaseConfiguration.load()?.databasePath ?? discover().first
            guard let path else { throw KakaoError.databaseNotFound(DeviceInfo.containerPath) }
            let reader = DatabaseReader(databasePath: path); try reader.open(key: key); return reader
        }
        let cached = try LocalDatabaseConfiguration.load()
        if let cached, userId == nil {
            let path = databasePath ?? cached.databasePath
            let reader = DatabaseReader(databasePath: path)
            try reader.open(key: KeyDerivation.secureKey(userId: cached.userId, uuid: cached.uuid))
            guard try reader.myUserId() == Int64(cached.userId) else {
                reader.close(); throw KakaoError.databaseOpenFailed("Cached account does not match this DB; run auth --save")
            }
            return reader
        }
        let configuration = try configure(databasePath: databasePath, userId: userId)
        let reader = DatabaseReader(databasePath: configuration.databasePath)
        try reader.open(key: KeyDerivation.secureKey(userId: configuration.userId, uuid: configuration.uuid))
        try configuration.save()
        return reader
    }
}
