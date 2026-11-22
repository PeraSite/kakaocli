import AppKit
import ApplicationServices
import Foundation

/// Fast KakaoTalk sender that only uses the macOS Accessibility API on the real KakaoTalk app.
///
/// It never talks to Kakao's servers (no LOCO). It does what a person would do:
/// launch KakaoTalk without bringing it forward, open the chat window, put the text into the
/// input box, press send, and close the window it opened. Delivery is confirmed by the caller
/// from the local database (see `SendCommand`).
///
/// Opening a chat, fastest first:
/// 1. The window is already open → use it (never closed afterwards).
/// 2. One-to-one chat with a friend → `kakaotalk://friend?action=chat&user_id=<id>` deep link.
/// 3. Main window chat list → read only the rows near the row index guessed from the local DB
///    ordering, select the row and send Return to the KakaoTalk process only. Falls back to
///    scanning every row and to the row's context menu ("채팅방 열기").
///
/// The list-opening flow and the Korean UI labels follow measurements published in
/// https://github.com/Tygb99/kakaocli-skill (MIT, scripts/kakao-open-ui.js, kakao-send-ui.js),
/// rewritten from JXA to direct AX calls, which are much faster per element.
public struct FastSendRequest: Sendable {
    public var chatId: Int64
    /// Window title of the chat (the chat's display name).
    public var title: String
    public var text: String
    /// Put the text into the box and clear it again without pressing send.
    public var dryRun: Bool
    /// "chat" or "open" when KakaoTalk's "separate open chat list" setting is on.
    public var side: String?
    /// Row index guesses in the main window chat list (from the local DB ordering).
    public var guesses: [Int]
    /// The other member of a one-to-one chat, for the deep link.
    public var peerUserId: Int64?

    public init(chatId: Int64, title: String, text: String, dryRun: Bool = false,
                side: String? = nil, guesses: [Int] = [], peerUserId: Int64? = nil) {
        self.chatId = chatId; self.title = title; self.text = text; self.dryRun = dryRun
        self.side = side; self.guesses = guesses; self.peerUserId = peerUserId
    }
}

public enum FastSender {
    public static let bundleId = "com.kakao.KakaoTalkMac"

    /// Whether this executable has the Accessibility permission. `prompt` shows the macOS request.
    public static func isTrusted(prompt: Bool = false) -> Bool {
        let key = "AXTrustedCheckOptionPrompt"  // kAXTrustedCheckOptionPrompt (a C global, not concurrency-safe in Swift 6)
        return AXIsProcessTrustedWithOptions([key: prompt] as CFDictionary)
    }

    /// Send one message. Returns a JSON-able result:
    /// `ok`, `step`, `pressed` (false = nothing can have been sent), `how`, `sent_by`, `opened_by_us`, `closed`, `ms_*`.
    public static func send(_ req: FastSendRequest) -> [String: Any] {
        let t0 = Date()
        var out: [String: Any] = ["ok": false, "pressed": false, "dry_run": req.dryRun]
        let ms = { Int(Date().timeIntervalSince(t0) * 1000) }
        if req.title.isEmpty || req.text.isEmpty { out["step"] = "BAD_REQUEST"; return out }
        if !isTrusted() { out["step"] = "NO_ACCESSIBILITY"; return out }
        let front = NSWorkspace.shared.frontmostApplication
        guard let app = runningKakao(&out) else { out["ms_end"] = ms(); return out }
        let k = Kakao(app.processIdentifier, t0)
        defer {
            // If KakaoTalk came on top of the app the user was using, give the focus back.
            if let f = front, f.bundleIdentifier != bundleId,
               NSWorkspace.shared.frontmostApplication?.bundleIdentifier == bundleId {
                f.activate()
            }
        }
        guard let (w, opened) = k.openWindow(req, &out) else { out["ms_end"] = ms(); return out }
        out["opened_by_us"] = opened
        let sent = k.type(w, req, &out)
        if !req.dryRun { out["ok"] = sent }
        if opened {
            if sent { pause(0.3) }  // closing right after pressing could cut the send
            out["closed"] = k.close(w)
        }
        out["ms_end"] = ms()
        return out
    }

    /// Launch KakaoTalk without activating it and wait until its accessibility tree answers.
    static func runningKakao(_ out: inout [String: Any]) -> NSRunningApplication? {
        if let a = NSRunningApplication.runningApplications(withBundleIdentifier: bundleId).first { return a }
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleId) else {
            out["step"] = "NO_APP"; return nil
        }
        let cfg = NSWorkspace.OpenConfiguration()
        cfg.activates = false
        let sem = DispatchSemaphore(value: 0)
        NSWorkspace.shared.openApplication(at: url, configuration: cfg) { _, _ in sem.signal() }
        _ = sem.wait(timeout: .now() + 20)
        out["launched"] = true
        var app: NSRunningApplication?
        _ = waitFor(100, 0.2) {
            app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleId).first
            guard let a = app else { return false }
            // The main window can start hidden; a readable menu bar means the app is ready.
            return ax(AXUIElementCreateApplication(a.processIdentifier), kAXMenuBarAttribute) != nil
        }
        pause(0.5)
        if app == nil { out["step"] = "APP_NOT_STARTED" }
        return app
    }
}

// MARK: - AX primitives

func pause(_ s: Double) { Thread.sleep(forTimeInterval: s) }
func nfc(_ s: String) -> String { s.precomposedStringWithCanonicalMapping }
func normBox(_ s: String) -> String { s.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n") }
@discardableResult func waitFor(_ tries: Int, _ step: Double, _ fn: () -> Bool) -> Bool {
    for i in 0..<tries {
        if fn() { return true }
        if i < tries - 1 { pause(step) }
    }
    return false
}
func ax(_ e: AXUIElement, _ a: String) -> AnyObject? {
    var v: AnyObject?
    return AXUIElementCopyAttributeValue(e, a as CFString, &v) == .success ? v : nil
}
private func str(_ e: AXUIElement, _ a: String) -> String { (ax(e, a) as? String) ?? "" }
private func kids(_ e: AXUIElement) -> [AXUIElement] { (ax(e, kAXChildrenAttribute) as? [AXUIElement]) ?? [] }
private func role(_ e: AXUIElement) -> String { str(e, kAXRoleAttribute) }
private func kids(_ e: AXUIElement, _ r: String) -> [AXUIElement] { kids(e).filter { role($0) == r } }
private func title(_ e: AXUIElement) -> String { str(e, kAXTitleAttribute) }
private func desc(_ e: AXUIElement) -> String { str(e, kAXDescriptionAttribute) }
private func value(_ e: AXUIElement) -> String { str(e, kAXValueAttribute) }
@discardableResult private func act(_ e: AXUIElement, _ a: String) -> Bool { AXUIElementPerformAction(e, a as CFString) == .success }
@discardableResult private func setAX(_ e: AXUIElement, _ a: String, _ v: AnyObject) -> Bool {
    AXUIElementSetAttributeValue(e, a as CFString, v) == .success
}
private func flag(_ e: AXUIElement, _ a: String) -> Bool { (ax(e, a) as? Bool) ?? false }
private func posX(_ e: AXUIElement) -> CGFloat {
    guard let v = ax(e, kAXPositionAttribute) else { return 0 }
    var p = CGPoint.zero
    AXValueGetValue(v as! AXValue, .cgPoint, &p)
    return p.x
}
private func postReturn(_ pid: pid_t) {
    for down in [true, false] { CGEvent(keyboardEventSource: nil, virtualKey: 36, keyDown: down)?.postToPid(pid) }
}

// MARK: - KakaoTalk UI

private final class Kakao {
    let app: AXUIElement
    let pid: pid_t
    let t0: Date
    init(_ pid: pid_t, _ t0: Date) {
        self.pid = pid; self.t0 = t0
        app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 3.0)
    }
    func ms() -> Int { Int(Date().timeIntervalSince(t0) * 1000) }
    var windows: [AXUIElement] { (ax(app, kAXWindowsAttribute) as? [AXUIElement]) ?? [] }
    func windows(named t: String) -> [AXUIElement] { windows.filter { nfc(title($0)) == nfc(t) } }

    /// The chat window's input box (description "메시지 입력").
    func inputBox(_ w: AXUIElement) -> AXUIElement? {
        for sa in kids(w, kAXScrollAreaRole) {
            for ta in kids(sa, kAXTextAreaRole) where desc(ta) == "메시지 입력" { return ta }
        }
        return nil
    }
    func sendButton(_ w: AXUIElement) -> AXUIElement? { kids(w, kAXButtonRole).first { title($0) == "전송" } }

    /// Main window on the chats tab (menu "창 → 채팅").
    func mainChatWindow(_ out: inout [String: Any]) -> AXUIElement? {
        guard let bar = ax(app, kAXMenuBarAttribute) else { out["step"] = "NO_MENU_BAR"; return nil }
        guard let win = kids(bar as! AXUIElement).first(where: { title($0) == "창" }), let menu = kids(win).first,
              let item = kids(menu).first(where: { title($0) == "채팅" })
        else { out["step"] = "NO_CHAT_MENU_ITEM"; return nil }
        act(item, kAXPressAction)
        var found: AXUIElement?
        let hasMain = { !self.windows(named: "카카오톡").isEmpty }
        // With the main window closed (or the app hidden), "창 → 채팅" alone shows nothing.
        // "Reopen" — what clicking the Dock icon does — recreates the main window; KakaoTalk can take a few
        // seconds to build it (measured 2026-11-22: absent after 5 s, present on the next run). Still no activation.
        if !waitFor(5, 0.1, hasMain) {
            setAX(app, kAXHiddenAttribute, kCFBooleanFalse)
            NSRunningApplication(processIdentifier: pid)?.unhide()
            if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: FastSender.bundleId) {
                let cfg = NSWorkspace.OpenConfiguration()
                cfg.activates = false
                NSWorkspace.shared.openApplication(at: url, configuration: cfg) { _, _ in }
            }
            out["reopened"] = true
            for _ in 0..<3 where !hasMain() {  // press the menu again while waiting, up to ~12 s
                waitFor(40, 0.1, hasMain)
                act(item, kAXPressAction)
            }
            out["ms_reopen"] = ms()
            if !hasMain() { out["step"] = "NO_MAIN_WINDOW"; return nil }
            act(item, kAXPressAction)  // make sure the visible main window is on the chats tab
        }
        waitFor(30, 0.1) {
            guard let w = self.windows(named: "카카오톡").first else { return false }
            if kids(w, kAXStaticTextRole).contains(where: { value($0) == "채팅" }) { found = w; return true }
            // Some layouts show the tab header as a button; "채팅방 추가" exists only on the chats tab.
            let ds = kids(w, kAXButtonRole).map(desc)
            if ds.contains("채팅") && ds.contains("채팅방 추가") { found = w; return true }
            return false
        }
        if found == nil {
            out["step"] = "NO_CHAT_TAB"
            out["window_titles"] = windows.map { title($0).isEmpty ? "(untitled)" : (title($0) == "카카오톡" ? "카카오톡" : "chat") }
            if let w = windows(named: "카카오톡").first {
                out["main_texts"] = kids(w, kAXStaticTextRole).prefix(6).map(value)
                out["main_buttons"] = kids(w, kAXButtonRole).prefix(12).map { desc($0) + "|" + title($0) }
            }
        }
        return found
    }

    func rowTitle(_ row: AXUIElement) -> String {
        guard let cell = kids(row).first, let t = kids(cell, kAXStaticTextRole).first else { return "" }
        return nfc(value(t))
    }

    /// Visible list side when "separate open chat list" is on ("chat" | "open"), "" when off.
    func listSide(_ main: AXUIElement) -> String {
        guard let tri = kids(main, kAXImageRole).first(where: { desc($0).hasPrefix("common icon triangledown") }),
              let openBtn = kids(main, kAXButtonRole).first(where: { desc($0) == "오픈채팅" })
        else { return "" }
        return posX(tri) > posX(openBtn) ? "open" : "chat"
    }
    func showSide(_ main: AXUIElement, _ s: String) -> Bool {
        guard let b = kids(main, kAXButtonRole).first(where: { desc($0) == (s == "open" ? "오픈채팅" : "채팅") }) else { return false }
        act(b, kAXPressAction)
        return waitFor(20, 0.1) { self.listSide(main) == s }
    }

    /// Find exactly one row titled `want`: rows near the guesses first, then every row.
    func findRow(_ rows: [AXUIElement], _ want: String, _ guesses: [Int], _ out: inout [String: Any]) -> Int? {
        let n = rows.count
        if n == 0 { return nil }
        var cache: [Int: String] = [:]
        func t(_ i: Int) -> String {
            if let v = cache[i] { return v }
            let v = rowTitle(rows[i]); cache[i] = v; return v
        }
        let gs = guesses.map { min(n - 1, max(0, $0)) }
        if !gs.isEmpty {
            var hit: Int?
            outer: for d in 0...20 {
                for g in gs {
                    for i in (d == 0 ? [g] : [g - d, g + d]) where i >= 0 && i < n && t(i) == want { hit = i; break outer }
                }
            }
            if let h = hit {
                // Found by widening: another row with the same name nearby means the index alone cannot decide.
                let twin = !gs.contains(h) && [h - 2, h - 1, h + 1, h + 2].contains { $0 >= 0 && $0 < n && t($0) == want }
                out["near"] = ["guess": gs, "read": cache.count, "row": h, "twin": twin]
                if !twin { return h }
            }
        }
        let all = (0..<n).filter { t($0) == want }
        out["scan"] = ["rows": n, "hits": all.count]
        if all.count > 1 { out["step"] = "AMBIGUOUS" }
        return all.count == 1 ? all[0] : nil
    }

    /// Open the chat window. Returns (window, openedByUs).
    func openWindow(_ req: FastSendRequest, _ out: inout [String: Any]) -> (AXUIElement, Bool)? {
        let same = windows(named: req.title)
        if same.count > 1 { out["step"] = "AMBIGUOUS_WINDOWS"; return nil }
        if let w = same.first { out["how"] = "already_open"; return (w, false) }

        if let uid = req.peerUserId, uid > 0, let url = URL(string: "kakaotalk://friend?action=chat&user_id=\(uid)") {
            let cfg = NSWorkspace.OpenConfiguration()
            cfg.activates = false
            NSWorkspace.shared.open(url, configuration: cfg) { _, _ in }
            var w: AXUIElement?
            waitFor(40, 0.05) { w = self.windows(named: req.title).first; return w != nil }
            out["ms_deeplink"] = ms()
            if let w { out["how"] = "deeplink"; return (w, true) }
            out["deeplink_miss"] = true
        }

        guard let main = mainChatWindow(&out) else { return nil }
        out["ms_tab"] = ms()
        guard let sa = kids(main, kAXScrollAreaRole).first, let list = kids(sa).first else { out["step"] = "NO_LIST"; return nil }
        let was = listSide(main)
        out["list_side"] = was.isEmpty ? "none" : was
        var order: [String] = [""]
        if !was.isEmpty {
            let s = req.side ?? ""
            order = (s == "open" || s == "chat") && s != was ? [s, was] : [was, was == "open" ? "chat" : "open"]
        }
        var restore: String?
        defer { if let r = restore { _ = showSide(main, r) } }
        var row: AXUIElement?
        for s in order {
            if !s.isEmpty && s != listSide(main) {
                if !showSide(main, s) { out["step"] = "LIST_NOT_SWITCHED"; return nil }
                restore = s == was ? nil : was
            }
            let rows = (ax(list, kAXRowsAttribute) as? [AXUIElement]) ?? kids(list, kAXRowRole)
            let useGuess = (s.isEmpty || s == req.side) ? req.guesses : []
            if let i = findRow(rows, nfc(req.title), useGuess, &out) { row = rows[i]; out["row"] = i; break }
            if (out["step"] as? String) == "AMBIGUOUS" { return nil }
        }
        out["ms_find"] = ms()
        guard let row else { out["step"] = "NOT_IN_LIST"; return nil }

        // Path 1: select the row and send Return to KakaoTalk only (no mouse, no clipboard, no activation).
        // A key sent to the process goes to its focused element. If that were a chat input box, a half-typed
        // message could be sent, so Return is sent only when the selected row is this chat alone, the main
        // window is main and the focus is on the list.
        var how = "menu"
        setAX(row, kAXSelectedAttribute, kCFBooleanTrue)
        if waitFor(10, 0.05, { flag(row, kAXSelectedAttribute) }) {
            if !flag(main, kAXMainAttribute) { setAX(main, kAXMainAttribute, kCFBooleanTrue) }
            setAX(list, kAXFocusedAttribute, kCFBooleanTrue)
            let focusedOK = waitFor(10, 0.05) {
                guard let fw = ax(self.app, kAXFocusedWindowAttribute), let fe = ax(self.app, kAXFocusedUIElementAttribute) else { return false }
                return flag(main, kAXMainAttribute) && title(fw as! AXUIElement) == "카카오톡"
                    && ["AXTable", "AXOutline", "AXRow", "AXCell"].contains(role(fe as! AXUIElement))
            }
            let selected = ((ax(list, kAXSelectedRowsAttribute) as? [AXUIElement]) ?? []).map(rowTitle)
            if focusedOK && selected == [nfc(req.title)] {
                postReturn(pid); how = "return"
            } else {
                out["return_skipped"] = focusedOK ? "SELECT_CHANGED" : "FOCUS_NOT_CONFIRMED"
            }
        } else {
            out["return_skipped"] = "SELECT_NOT_CONFIRMED"
        }
        if how == "menu" {
            // Path 2: the row's context menu "채팅방 열기", only if the row still shows this chat.
            guard rowTitle(row) == nfc(req.title), let cell = kids(row).first else { out["step"] = "ROW_MOVED"; return nil }
            act(row, "AXScrollToVisible")
            act(cell, kAXShowMenuAction)
            var item: AXUIElement?
            waitFor(12, 0.1) {
                guard let m = kids(cell, kAXMenuRole).first else { return false }
                item = kids(m).first { title($0) == "채팅방 열기" }
                if item == nil { act(m, kAXCancelAction) }
                return true
            }
            guard let item else { out["step"] = "NO_OPEN_ITEM"; return nil }
            act(item, kAXPressAction)
        }
        out["how"] = how
        var w: AXUIElement?
        waitFor(60, 0.1) { w = self.windows(named: req.title).first; return w != nil }
        out["ms_open"] = ms()
        guard let w else { out["step"] = "NOT_OPENED_AFTER_PRESS"; return nil }
        return (w, true)
    }

    /// Put the text in and send (or clear again on a dry run). Never touches text the user was typing.
    /// Focus goes to the box first: setting the value and pressing "전송" without focus did not send
    /// in testing. If the button does not empty the box, Return is sent only while the focus is on this box.
    func type(_ w: AXUIElement, _ req: FastSendRequest, _ out: inout [String: Any]) -> Bool {
        let msg = normBox(req.text)
        var box: AXUIElement?
        waitFor(30, 0.1) { box = self.inputBox(w); return box != nil }
        guard let box else { out["step"] = "NO_INPUT_BOX"; return false }
        func wipe() {  // only our own text
            for _ in 0..<4 {
                let cur = normBox(value(box))
                if cur.isEmpty { return }
                if cur == msg || msg.hasPrefix(cur) { setAX(box, kAXValueAttribute, "" as CFString) } else { return }
                pause(0.2)
            }
        }
        setAX(w, kAXMainAttribute, kCFBooleanTrue)
        setAX(box, kAXFocusedAttribute, kCFBooleanTrue)
        let cur = normBox(value(box))
        if cur == msg { out["reused"] = true }
        else if !cur.isEmpty { out["step"] = "BOX_NOT_EMPTY"; return false }
        else { setAX(box, kAXValueAttribute, msg as CFString) }
        if !waitFor(10, 0.1, { normBox(value(box)) == msg }) { wipe(); out["step"] = "VALUE_MISMATCH"; return false }
        if req.dryRun {
            wipe()
            out["step"] = "SET_AND_CLEARED"
            out["ok"] = normBox(value(box)).isEmpty
            return false
        }
        let emptied = { waitFor(15, 0.1) { value(box).isEmpty } }
        out["pressed"] = true  // from here on the message may have been sent
        var how = ""
        if let btn = sendButton(w) {
            act(btn, kAXPressAction)
            // The button often does nothing (measured); do not wait long before trying Return.
            if waitFor(6, 0.1, { value(box).isEmpty }) { how = "button" }
        }
        if how.isEmpty {
            setAX(box, kAXFocusedAttribute, kCFBooleanTrue)
            let onBox = waitFor(10, 0.05) {
                guard let fe = ax(self.app, kAXFocusedUIElementAttribute), let fw = ax(self.app, kAXFocusedWindowAttribute) else { return false }
                return CFEqual(fe, box) && CFEqual(fw, w)
            }
            if onBox && normBox(value(box)) == msg {
                postReturn(pid)
                if emptied() { how = "return" }
            }
        }
        out["ms_press"] = ms()
        if how.isEmpty { wipe(); out["step"] = "BOX_NOT_EMPTIED"; return false }
        out["sent_by"] = how
        out["step"] = "PRESSED"
        return true
    }

    func close(_ w: AXUIElement) -> Bool {
        guard let b = ax(w, kAXCloseButtonAttribute) else { return false }
        act(b as! AXUIElement, kAXPressAction)
        return waitFor(20, 0.1) { !self.windows.contains { CFEqual($0, w) } }
    }
}

// MARK: - Row index guess

public struct ChatListRow: Sendable {
    public var chatId: Int64, type: Int, pin: Int, unread: Bool, lastUpdatedAt: Int64, isOpen: Bool, vtype: Int
    public init(chatId: Int64, type: Int, pin: Int, unread: Bool, lastUpdatedAt: Int64, isOpen: Bool, vtype: Int) {
        self.chatId = chatId; self.type = type; self.pin = pin; self.unread = unread
        self.lastUpdatedAt = lastUpdatedAt; self.isOpen = isOpen; self.vtype = vtype
    }
}

public enum ChatListOrder {
    /// Where a chat appears in the main window list: folder rows (type >= 10000) first, then pinned chats
    /// (larger pin first), then by lastUpdatedAt descending. Whether unread chats come first is a setting
    /// not stored in the DB, so both indexes are returned. `inFolder` = the chat has no row of its own.
    public static func guess(_ rows: [ChatListRow], chatId: Int64, splitOpenList: Bool) -> (side: String?, guesses: [Int], inFolder: Bool) {
        guard let me = rows.first(where: { $0.chatId == chatId }) else { return (nil, [], false) }
        if me.vtype != 0 { return (nil, [], true) }
        let pool = rows.filter { $0.vtype == 0 && (!splitOpenList || $0.isOpen == me.isOpen) }
        var out: [Int] = []
        for unreadFirst in [true, false] {
            let order = pool.sorted { a, b in
                func key(_ r: ChatListRow) -> [Int64] {
                    [r.type < 10000 ? 1 : 0, r.type >= 10000 ? Int64(r.type) : 0, r.pin < 0 ? 1 : 0, Int64(-r.pin),
                     (unreadFirst && !r.unread) ? 1 : 0, -r.lastUpdatedAt]
                }
                return key(a).lexicographicallyPrecedes(key(b))
            }
            if let i = order.firstIndex(where: { $0.chatId == chatId }), !out.contains(i) { out.append(i) }
        }
        return (me.isOpen ? "open" : "chat", out, false)
    }
}
