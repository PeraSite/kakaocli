import Foundation
import Testing
import CSQLCipher
@testable import KakaoCore

private final class LocalFixture {
    let directory: URL
    let databasePath: String
    let uuid = "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE"
    let userId = 4242
    let key: String

    init() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        key = KeyDerivation.secureKey(userId: userId, uuid: uuid)
        databasePath = directory.appendingPathComponent(KeyDerivation.databaseName(userId: userId, uuid: uuid)).path
        var writer: OpaquePointer?
        guard sqlite3_open(databasePath, &writer) == SQLITE_OK else { throw NSError(domain: "fixture", code: 1) }
        defer { sqlite3_close(writer) }
        func exec(_ sql: String) throws {
            guard sqlite3_exec(writer, sql, nil, nil, nil) == SQLITE_OK else { throw NSError(domain: "fixture", code: 2, userInfo: [NSLocalizedDescriptionKey: String(cString: sqlite3_errmsg(writer))]) }
        }
        try exec("PRAGMA key='\(key)'; PRAGMA cipher_compatibility=3;")
        try exec("""
            CREATE TABLE NTChatContext(userId INTEGER PRIMARY KEY);
            INSERT INTO NTChatContext VALUES(4242);
            CREATE TABLE NTUser(userId INTEGER,linkId INTEGER,displayName TEXT,friendNickName TEXT,nickName TEXT,PRIMARY KEY(userId,linkId));
            INSERT INTO NTUser VALUES(42,0,'ordinary profile',NULL,NULL),(42,99,'open profile',NULL,NULL),(4242,0,'Me',NULL,NULL),(73,0,'Second owner',NULL,NULL);
            CREATE TABLE NTChatRoom(chatId INTEGER PRIMARY KEY,linkId INTEGER,type INTEGER,chatName TEXT,activeMembersCount INTEGER,lastLogId INTEGER,lastUpdatedAt INTEGER,countOfNewMessage INTEGER,directChatMemberUserId INTEGER,displayMemberIds BLOB);
            INSERT INTO NTChatRoom VALUES(10,0,0,NULL,2,9007199254740993,1700000002,0,42,NULL);
            INSERT INTO NTChatRoom VALUES(20,99,3,NULL,2,9007199254740995,1700000003,0,42,NULL);
            INSERT INTO NTChatRoom VALUES(30,100,4,NULL,3,9007199254740996,1700000004,0,0,NULL);
            INSERT INTO NTChatRoom VALUES(40,0,1,NULL,3,9007199254740997,1700000005,0,0,NULL);
            INSERT INTO NTChatRoom VALUES(50,0,2,NULL,2,9007199254740998,1700000006,0,42,NULL);
            INSERT INTO NTChatRoom VALUES(60,0,5,NULL,1,9007199254740999,1700000007,0,4242,NULL);
            INSERT INTO NTChatRoom VALUES(-1,0,10000,NULL,0,0,0,0,0,NULL);
            CREATE TABLE NTChatMeta(chatId INTEGER,type INTEGER,groupNickname TEXT,content TEXT);
            INSERT INTO NTChatMeta VALUES(40,3,'Named group','Named group');
            CREATE TABLE NTOpenLink(linkId INTEGER PRIMARY KEY,linkName TEXT);
            INSERT INTO NTOpenLink VALUES(99,'Owner open chat'),(100,'Open group');
            CREATE TABLE NTChatMessage(chatId INTEGER,logId INTEGER,msgId INTEGER,prevId INTEGER,authorId INTEGER,type INTEGER,sentAt INTEGER,message TEXT,attachment TEXT,supplement TEXT,PRIMARY KEY(chatId,logId,msgId));
            INSERT INTO NTChatMessage VALUES(10,9007199254740992,1,0,42,1,1700000000,'previous','{}','');
            INSERT INTO NTChatMessage VALUES(10,9007199254740993,2,0,4242,1,1700000001,'hello owner','{}','');
            INSERT INTO NTChatMessage VALUES(10,9007199254740993,3,0,42,1,1700000002,'duplicate log, distinct msgId','{}','');
            INSERT INTO NTChatMessage VALUES(20,9007199254740995,4,0,42,26,1700000003,'open owner','{}','');
            INSERT INTO NTChatMessage VALUES(20,9007199254740996,5,0,4242,1,1700000004,'hello owner','{}','');
            INSERT INTO NTChatMessage VALUES(50,9007199254740998,6,0,42,1,1700000006,'owner received only','{}','');
            INSERT INTO NTChatMessage VALUES(60,9007199254740999,7,0,4242,1,1700000007,'owner draft','{}','');
            """)
    }

    func open() throws -> DatabaseReader {
        let reader = DatabaseReader(databasePath: databasePath); try reader.open(key: key); return reader
    }
    deinit { try? FileManager.default.removeItem(at: directory) }
}

@Test func nativeRecoveryHandlesBoundsAndTimeout() {
    let hash = DeviceInfo.sha512Hex("712345")
    #expect(DeviceInfo.recoverUserIdFromSHA512(hexHash: hash, maxId: 712346, timeout: 5, workers: 4) == 712345)
    #expect(DeviceInfo.recoverUserIdFromSHA512(hexHash: hash, maxId: 1000, timeout: 5, workers: 2) == nil)
    #expect(DeviceInfo.recoverUserIdFromSHA512(hexHash: "invalid", maxId: 1000, timeout: 5, workers: 2) == nil)
    #expect(DeviceInfo.recoverUserIdFromSHA512(hexHash: hash, maxId: 1_000_000_000, timeout: 0.001, workers: 2) == nil)
}

@Test func preferencePrefixesAndEmptyMarkers() {
    let active = DeviceInfo.sha512Hex("4242"), empty = DeviceInfo.sha512Hex("0")
    let hashes = DeviceInfo.localAccountHashes(from: [[
        "DENYFILEEXTIONSIONREVISION:\(active)": 2,
        "DESIGNATEDFRIENDSREVISION:\(active)": 4,
        "DESIGNATEDFRIENDSREVISION:\(empty)": 7,
        "DENYFILEEXTIONSIONREVISION:nothex": 5,
    ]])
    #expect(hashes == [active])
}

@Test func encryptedReadNamesOpenProfilesAndPagination() throws {
    let fixture = try LocalFixture(), reader = try fixture.open(); defer { reader.close() }
    #expect(try !LocalDatabase.isPlaintext(databasePath: fixture.databasePath))
    let plainPath = fixture.directory.appendingPathComponent("plaintext.db").path
    var writer: OpaquePointer?
    #expect(sqlite3_open(plainPath, &writer) == SQLITE_OK)
    #expect(sqlite3_exec(writer, "CREATE TABLE example(value INTEGER); INSERT INTO example VALUES(7);", nil, nil, nil) == SQLITE_OK)
    sqlite3_close(writer)
    #expect(try LocalDatabase.isPlaintext(databasePath: plainPath))
    let plain = try LocalDatabase.open(databasePath: plainPath); defer { plain.close() }
    #expect(try plain.rawQuery("SELECT value FROM example")[0][0] as? Int64 == 7)
    #expect(try reader.countChats() == 6)
    let rooms = try reader.localChats()
    #expect(rooms.first(where: { $0.id == 40 })?.displayName == "Named group")
    #expect(rooms.first(where: { $0.id == 20 })?.kind == .openDirect)
    #expect(rooms.first(where: { $0.id == 30 })?.displayName == "Open group")
    #expect(try reader.countChats(kind: "open") == 2)
    #expect(try reader.countChats(contacted: true) == 3)
    let first = try reader.search(query: "owner", limit: 1, offset: 0, sender: "me")
    let second = try reader.search(query: "owner", limit: 1, offset: 1, sender: "me")
    #expect(first[0].id != second[0].id)
    #expect(try reader.countMessages(text: "owner", sender: "me") == 3)
    let open = try reader.messages(chatId: 20, limit: 10)
    #expect(open.first(where: { $0.senderId == 42 })?.senderName == "open profile")
    #expect(open.first(where: { $0.senderId == 42 })?.rawType == 26)
}

@Test func contextRequiresCompositeIdentityAndReadOnlyQueries() throws {
    let fixture = try LocalFixture(), reader = try fixture.open(); defer { reader.close() }
    #expect(throws: (any Error).self) { try reader.context(chatId: 10, logId: 9007199254740993) }
    let messages = try reader.context(chatId: 10, logId: 9007199254740993, messageId: 2, before: 1, after: 1)
    #expect(messages.map(\.messageId) == [1,2,3])
    #expect(throws: (any Error).self) { try reader.rawQuery("UPDATE NTChatMessage SET message='changed'") }
    #expect(throws: (any Error).self) { try reader.rawQuery("ATTACH DATABASE ':memory:' AS other") }
    #expect(throws: (any Error).self) { try reader.rawQuery("PRAGMA query_only=OFF") }
    #expect(throws: (any Error).self) { try reader.rawNamedQuery("SELECT 1; SELECT 2") }
    #expect(throws: (any Error).self) { try reader.rawQuery("SELECT 1; SELECT 2") }
    let rows = try reader.rawNamedQuery("SELECT logId,msgId FROM NTChatMessage WHERE msgId=2")
    #expect(rows[0]["logId"] as? String == "9007199254740993")
}

@Test func candidatesExcludeDraftsUncontactedAndKeepEvidence() throws {
    let fixture = try LocalFixture(), reader = try fixture.open(); defer { reader.close() }
    let rows = try reader.contactCandidates(terms: ["owner"], titleTerms: ["owner"])
    #expect(Set(rows.map { $0.chat.id }) == [10,20])
    let evidence = try reader.candidateEvidence(chatId: 20, terms: ["owner"], limit: 1)
    #expect(evidence[0].isFromMe)
}

@Test func configurationUsesBothPlistsAndStoresNoKey() throws {
    let fixture = try LocalFixture()
    let hash = DeviceInfo.sha512Hex(String(fixture.userId))
    let plist: [String: Any] = ["DENYFILEEXTIONSIONREVISION:\(hash)": 1, "AlertKakaoIDsList": [999,1000]]
    let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .binary, options: 0)
    try data.write(to: fixture.directory.appendingPathComponent("com.kakao.KakaoTalkMac.plist"))
    let config = try LocalDatabase.configure(databasePath: fixture.databasePath, preferencesDirectory: fixture.directory.path,
                                            uuid: fixture.uuid, timeout: 5, maxId: 10000, workers: 2)
    #expect(config.userId == fixture.userId)
    let path = fixture.directory.appendingPathComponent("settings/config.json").path
    try config.save(path: path); try config.save(path: path)
    let loaded = try LocalDatabaseConfiguration.load(path: path)
    #expect(loaded?.userId == fixture.userId)
    let permissions = try FileManager.default.attributesOfItem(atPath: path)[.posixPermissions] as? NSNumber
    #expect(permissions?.intValue == 0o600)
    #expect(!String(data: try Data(contentsOf: URL(fileURLWithPath: path)), encoding: .utf8)!.contains(fixture.key))
}
