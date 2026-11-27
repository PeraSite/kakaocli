import Testing
@testable import KakaoCore

private func row(_ id: Int64, type: Int = 0, pin: Int = -1, unread: Bool = false, last: Int64, open: Bool = false, vtype: Int = 0, link: Int64 = 0) -> ChatListRow {
    ChatListRow(chatId: id, type: type, pin: pin, unread: unread, lastUpdatedAt: last, isOpen: open, vtype: vtype, linkId: link)
}

@Test func folderRowsThenPinnedThenRecent() {
    let rows = [row(1, last: 100), row(2, unread: true, last: 50), row(3, pin: 5, last: 10), row(4, type: 10000, last: 1)]
    #expect(ChatListOrder.guess(rows, chatId: 4, splitOpenList: false).guesses == [0])
    #expect(ChatListOrder.guess(rows, chatId: 3, splitOpenList: false).guesses == [1])
    // Unread-first ordering is a UI setting not stored in the DB: both indexes are returned.
    #expect(ChatListOrder.guess(rows, chatId: 2, splitOpenList: false).guesses == [2, 3])
}

@Test func linkGroupedChatsPointAtTheGroupRow() {
    // Two chats from the same hosted one-to-one link show as one row with the newer member's time.
    let rows = [row(1, last: 500), row(9, last: 300, open: true, vtype: 1, link: 77), row(8, last: 900, open: true, vtype: 1, link: 77),
                row(2, last: 400)]
    let g = ChatListOrder.guess(rows, chatId: 9, splitOpenList: false)
    #expect(g.grouped)
    #expect(g.side == "open")
    #expect(g.guesses == [0])  // group row (900) before 1 (500) and 2 (400)
    // The group counts as one row for the others: 2 is third, not fourth.
    #expect(ChatListOrder.guess(rows, chatId: 2, splitOpenList: false).guesses == [2])
    #expect(!ChatListOrder.guess(rows, chatId: 2, splitOpenList: false).grouped)
    #expect(ChatListOrder.guess(rows, chatId: 7, splitOpenList: false).guesses.isEmpty)
}

@Test func separateOpenChatListCountsOnlyThatSide() {
    let rows = [row(1, last: 300, open: true), row(2, last: 200), row(3, last: 100, open: true)]
    let g = ChatListOrder.guess(rows, chatId: 3, splitOpenList: true)
    #expect(g.side == "open")
    #expect(g.guesses == [1])
    #expect(ChatListOrder.guess(rows, chatId: 3, splitOpenList: false).guesses == [2])
}
