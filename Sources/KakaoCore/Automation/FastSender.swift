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
    /// The chat sits inside the group row of this open chat link (link name, see `ChatListOrder.guess`).
    /// `guesses` then point at the group row.
    public var group: String?

    public init(chatId: Int64, title: String, text: String, dryRun: Bool = false,
                side: String? = nil, guesses: [Int] = [], peerUserId: Int64? = nil, group: String? = nil) {
        self.chatId = chatId; self.title = title; self.text = text; self.dryRun = dryRun
        self.side = side; self.guesses = guesses; self.peerUserId = peerUserId; self.group = group
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

// Windows on other Spaces are not in kAXWindows. They can be reached by building the element from its
// remote token (pid, 0, "coco", element id), the method AltTab uses (github.com/lwouis/alt-tab-macos).
@_silgen_name("_AXUIElementCreateWithRemoteToken")
private func _AXUIElementCreateWithRemoteToken(_ token: CFData) -> Unmanaged<AXUIElement>?

func remoteWindowsRange(_ pid: pid_t, _ r: Range<UInt64>) -> [(AXUIElement, UInt64)] {
    var out: [(AXUIElement, UInt64)] = []
    var token = Data(count: 20)
    token.replaceSubrange(0..<4, with: withUnsafeBytes(of: pid) { Data($0) })
    token.replaceSubrange(8..<12, with: withUnsafeBytes(of: Int32(0x636f636f)) { Data($0) })
    for id in r {
        token.replaceSubrange(12..<20, with: withUnsafeBytes(of: id) { Data($0) })
        guard let e = _AXUIElementCreateWithRemoteToken(token as CFData)?.takeRetainedValue() else { continue }
        if (ax(e, kAXRoleAttribute) as? String) == (kAXWindowRole as String) { out.append((e, id)) }
    }
    return out
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
    /// Windows including those on other Spaces: kAXWindows lists only the current Space's, so with a
    /// full-screen app in front KakaoTalk seemed to have no windows at all (2026-11-27 NO_MAIN_WINDOW).
    /// Windows including those on other Spaces. kAXWindows lists only the current Space's, so with a
    /// full-screen app in front KakaoTalk seemed to have no windows (2026-11-27 NO_MAIN_WINDOW). The others are
    /// found once by remote token, and windows opened later are the app's focused/main window (measured: a window
    /// KakaoTalk opens on its own Space becomes AXFocusedWindow even while another Space is shown).
    private var offSpace: [AXUIElement] = []
    private var scanned = false
    var windows: [AXUIElement] {
        var res = (ax(app, kAXWindowsAttribute) as? [AXUIElement]) ?? []
        func add(_ w: AXUIElement) { if !res.contains(where: { CFEqual($0, w) }) { res.append(w) } }
        if !scanned {
            scanned = true
            offSpace = remoteWindowsRange(pid, 0..<3000).map(\.0)
        }
        for a in [kAXFocusedWindowAttribute, kAXMainWindowAttribute] {
            if let w = ax(app, a), role(w as! AXUIElement) == kAXWindowRole {
                let w = w as! AXUIElement
                if !offSpace.contains(where: { CFEqual($0, w) }) { offSpace.append(w) }
            }
        }
        offSpace.removeAll { role($0) != kAXWindowRole }  // closed windows stop answering
        offSpace.forEach(add)
        return res
    }
    /// The main window is not on the Space being shown (a full-screen app is in front). Return keys sent to the
    /// app do nothing then, so rows are opened with the context menu.
    func isOffSpace(_ w: AXUIElement) -> Bool {
        !((ax(app, kAXWindowsAttribute) as? [AXUIElement]) ?? []).contains { CFEqual($0, w) }
    }
    var allWindows: [AXUIElement] { windows }
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
        // A chat inside a link group is reached through the group row ("오픈채팅, <link>" or "<link>").
        let wants = req.group.map { [nfc("오픈채팅, " + $0), nfc($0)] } ?? [nfc(req.title)]
        var row: AXUIElement?
        rowSearch: for s in order {
            if !s.isEmpty && s != listSide(main) {
                if !showSide(main, s) { out["step"] = "LIST_NOT_SWITCHED"; return nil }
                restore = s == was ? nil : was
            }
            let rows = (ax(list, kAXRowsAttribute) as? [AXUIElement]) ?? kids(list, kAXRowRole)
            let useGuess = (s.isEmpty || s == req.side) ? req.guesses : []
            for want in wants {
                if let i = findRow(rows, want, useGuess, &out) { row = rows[i]; out["row"] = i; break rowSearch }
                if (out["step"] as? String) == "AMBIGUOUS" { return nil }
            }
        }
        out["ms_find"] = ms()
        guard let row else { out["step"] = req.group == nil ? "NOT_IN_LIST" : "GROUP_NOT_IN_LIST"; return nil }

        guard req.group != nil else {
            guard let how = openAndWait(row, list: list, in: main, &out, { self.windows(named: req.title).first }) else {
            if out["step"] == nil { out["step"] = "NOT_OPENED_AFTER_PRESS" }; return nil
        }
            out["how"] = how
            return waitChatWindow(req.title, &out).map { ($0, true) }
        }

        // Group row: it opens an untitled window listing the link's chats; open ours from there.
        let before = windows.filter { title($0).isEmpty }
        var gw: AXUIElement?
        var glist: AXUIElement?
        let how = openAndWait(row, list: list, in: main, &out) {
            for w in self.windows where title(w).isEmpty {
                guard let sa = kids(w, kAXScrollAreaRole).first, let l = kids(sa).first, role(l) == kAXTableRole else { continue }
                let rs = (ax(l, kAXRowsAttribute) as? [AXUIElement]) ?? kids(l, kAXRowRole)
                if rs.contains(where: { self.rowTitle($0) == nfc(req.title) }) { gw = w; glist = l; return w }
            }
            return nil
        }
        guard let how else { if out["step"] == nil { out["step"] = "GROUP_NOT_OPENED" }; return nil }
        out["ms_group"] = ms()
        guard let gw, let glist else { out["step"] = "GROUP_NOT_OPENED"; return nil }
        let groupOpenedByUs = !before.contains { CFEqual($0, gw) }
        defer { if groupOpenedByUs { out["group_closed"] = close(gw) } }
        let grows = (ax(glist, kAXRowsAttribute) as? [AXUIElement]) ?? kids(glist, kAXRowRole)
        let hits = grows.filter { rowTitle($0) == nfc(req.title) }
        if hits.count != 1 { out["step"] = hits.isEmpty ? "NOT_IN_GROUP" : "AMBIGUOUS"; return nil }
        guard let how2 = openAndWait(hits[0], list: glist, in: gw, &out, { self.windows(named: req.title).first }) else {
            if out["step"] == nil { out["step"] = "NOT_OPENED_AFTER_PRESS" }; return nil
        }
        out["how"] = "group:\(how)+\(how2)"
        return waitChatWindow(req.title, &out).map { ($0, true) }
    }

    /// Open a row and wait until `appeared` finds the window it opens. A Return that opened nothing within 2 s
    /// (seen when KakaoTalk is on another Space) is followed by the context menu once; opening twice only
    /// brings the same window forward. Returns how, or nil (with `step` set when the row could not be pressed).
    func openAndWait(_ row: AXUIElement, list: AXUIElement, in win: AXUIElement, _ out: inout [String: Any],
                     _ appeared: @escaping () -> AXUIElement?) -> String? {
        guard let how = openRow(row, list: list, in: win, &out) else { return nil }
        if waitFor(how == "return" ? 20 : 50, 0.1, { appeared() != nil }) { return how }
        guard how == "return" else { return nil }
        out["return_no_window"] = true
        guard let how2 = openRow(row, list: list, in: win, menuOnly: true, &out) else { return nil }
        return waitFor(50, 0.1, { appeared() != nil }) ? "return+\(how2)" : nil
    }

    func waitChatWindow(_ t: String, _ out: inout [String: Any]) -> AXUIElement? {
        var w: AXUIElement?
        waitFor(60, 0.1) { w = self.windows(named: t).first; return w != nil }
        out["ms_open"] = ms()
        if w == nil { out["step"] = "NOT_OPENED_AFTER_PRESS" }
        return w
    }

    /// Open a list row in window `win`. Returns how ("return" | "menu"), or nil with `step` set.
    ///
    /// Path 1: select the row and send Return to KakaoTalk only (no mouse, no clipboard, no activation).
    /// A key sent to the process goes to its focused element. If that were a chat input box, a half-typed
    /// message could be sent, so Return is sent only when the selected row is this row alone, `win` is main
    /// and the focus is on its list.
    /// Path 2: the row's context menu "채팅방 열기", only if the row still shows the same title.
    func openRow(_ row: AXUIElement, list: AXUIElement, in win: AXUIElement, menuOnly: Bool = false, _ out: inout [String: Any]) -> String? {
        let want = rowTitle(row)
        if menuOnly || isOffSpace(win) {
            out["off_space"] = !menuOnly
        } else {
        setAX(row, kAXSelectedAttribute, kCFBooleanTrue)
        if waitFor(10, 0.05, { flag(row, kAXSelectedAttribute) }) {
            if !flag(win, kAXMainAttribute) { setAX(win, kAXMainAttribute, kCFBooleanTrue) }
            setAX(list, kAXFocusedAttribute, kCFBooleanTrue)
            let focusedOK = waitFor(10, 0.05) {
                guard let fw = ax(self.app, kAXFocusedWindowAttribute), let fe = ax(self.app, kAXFocusedUIElementAttribute) else { return false }
                return flag(win, kAXMainAttribute) && CFEqual(fw, win)
                    && ["AXTable", "AXOutline", "AXRow", "AXCell"].contains(role(fe as! AXUIElement))
            }
            let selected = ((ax(list, kAXSelectedRowsAttribute) as? [AXUIElement]) ?? []).map(rowTitle)
            if focusedOK && selected == [want] { postReturn(pid); return "return" }
            out["return_skipped"] = focusedOK ? "SELECT_CHANGED" : "FOCUS_NOT_CONFIRMED"
        } else {
            out["return_skipped"] = "SELECT_NOT_CONFIRMED"
        }
        }
        guard rowTitle(row) == want, let cell = kids(row).first else { out["step"] = "ROW_MOVED"; return nil }
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
        return "menu"
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
    /// NTChatRoom.linkId (open chats). Chats with vtype != 0 that share a link are shown as one row.
    public var linkId: Int64
    public init(chatId: Int64, type: Int, pin: Int, unread: Bool, lastUpdatedAt: Int64, isOpen: Bool, vtype: Int, linkId: Int64 = 0) {
        self.chatId = chatId; self.type = type; self.pin = pin; self.unread = unread
        self.lastUpdatedAt = lastUpdatedAt; self.isOpen = isOpen; self.vtype = vtype; self.linkId = linkId
    }
}

public enum ChatListOrder {
    /// Where a chat appears in the main window list: folder rows (type >= 10000) first, then pinned chats
    /// (larger pin first), then by lastUpdatedAt descending. Whether unread chats come first is a setting
    /// not stored in the DB, so both indexes are returned.
    ///
    /// `grouped` = the chat has no row of its own: it came in through a one-to-one open chat link you host
    /// (NTChatRoom.vtype != 0), and KakaoTalk shows all chats of that link as one row named after the link
    /// ("오픈채팅, <linkName>"). Opening that row shows a window listing the chats. The guesses are then the
    /// index of that group row. (Measured 2026-11-27 on KakaoTalk Mac with the "부카 문의" link.)
    public static func guess(_ rows: [ChatListRow], chatId: Int64, splitOpenList: Bool) -> (side: String?, guesses: [Int], grouped: Bool) {
        guard let me = rows.first(where: { $0.chatId == chatId }) else { return (nil, [], false) }
        let grouped = me.vtype != 0
        // Grouped chats collapse into one row per link that carries the newest member's time.
        var visible = rows.filter { $0.vtype == 0 }
        var groups: [Int64: ChatListRow] = [:]
        for r in rows where r.vtype != 0 {
            var g = groups[r.linkId] ?? ChatListRow(chatId: -r.linkId - 1, type: r.type, pin: -1, unread: false,
                                                   lastUpdatedAt: 0, isOpen: true, vtype: 0, linkId: r.linkId)
            g.lastUpdatedAt = max(g.lastUpdatedAt, r.lastUpdatedAt)
            g.unread = g.unread || r.unread
            groups[r.linkId] = g
        }
        visible += groups.values
        let target = grouped ? -me.linkId - 1 : chatId
        let isOpen = grouped ? true : me.isOpen
        let pool = visible.filter { !splitOpenList || $0.isOpen == isOpen }
        var out: [Int] = []
        for unreadFirst in [true, false] {
            let order = pool.sorted { a, b in
                func key(_ r: ChatListRow) -> [Int64] {
                    [r.type < 10000 ? 1 : 0, r.type >= 10000 ? Int64(r.type) : 0, r.pin < 0 ? 1 : 0, Int64(-r.pin),
                     (unreadFirst && !r.unread) ? 1 : 0, -r.lastUpdatedAt]
                }
                return key(a).lexicographicallyPrecedes(key(b))
            }
            if let i = order.firstIndex(where: { $0.chatId == target }), !out.contains(i) { out.append(i) }
        }
        return (isOpen ? "open" : "chat", out, grouped)
    }
}

// MARK: - UI probe (development)

extension FastSender {
    /// Dump parts of the KakaoTalk UI without activating it, for developing the send flow.
    /// steps: "main" (main window on the chats tab, top level + first rows), "rows" (all row titles),
    /// "row=<title>" (that row's subtree), "open=<title>" (open that row with Return, then list windows),
    /// "win=<title>" (dump that window), "wins" (window titles).
    public static func probe(_ steps: [String], depth: Int = 4) -> String {
        guard isTrusted() else { return "NO_ACCESSIBILITY" }
        guard let a = NSRunningApplication.runningApplications(withBundleIdentifier: bundleId).first else { return "NOT_RUNNING" }
        let k = Kakao(a.processIdentifier, Date())
        var lines: [String] = []
        func dump(_ e: AXUIElement, _ d: Int, _ maxD: Int, maxKids: Int = 40) {
            let r = role(e), t = title(e), v = value(e), ds = desc(e), id = str(e, kAXIdentifierAttribute)
            var l = String(repeating: "  ", count: d) + "[\(r)]"
            if !t.isEmpty { l += " t=\"\(t.prefix(50))\"" }
            if !v.isEmpty { l += " v=\"\(v.prefix(50))\"" }
            if !ds.isEmpty { l += " d=\"\(ds.prefix(50))\"" }
            if !id.isEmpty { l += " id=\(id)" }
            let acts = (try? { () -> [String] in var n: CFArray?; AXUIElementCopyActionNames(e, &n); return (n as? [String]) ?? [] }()) ?? []
            if !acts.isEmpty { l += " acts=\(acts.joined(separator: ","))" }
            lines.append(l)
            guard d < maxD else { return }
            let ks = kids(e)
            for c in ks.prefix(maxKids) { dump(c, d + 1, maxD, maxKids: maxKids) }
            if ks.count > maxKids { lines.append(String(repeating: "  ", count: d + 1) + "… \(ks.count - maxKids) more") }
        }
        var main: AXUIElement?
        for s in steps {
            lines.append("## \(s)")
            if s == "wins" { lines += k.windows.map { "win: \(title($0))" }; continue }
            if s == "appwins" {
                for a in [kAXFocusedWindowAttribute, kAXMainWindowAttribute] {
                    if let w = ax(k.app, a) { lines.append("\(a): t=\(title(w as! AXUIElement)) sub=\(str(w as! AXUIElement, kAXSubroleAttribute))") } else { lines.append("\(a): nil") }
                }
                lines += kids(k.app).map { "child: \(role($0)) \(title($0))" }
                let t0 = Date(); let n = remoteWindowsRange(k.pid, 0..<UInt64(Int(ProcessInfo.processInfo.environment["N"] ?? "20000")!))
                lines.append("scan \(Int(Date().timeIntervalSince(t0)*1000))ms: " + n.map { "\($0.1)=\(title($0.0))" }.joined(separator: ", "))
                continue
            }
            if s == "allwins" {
                lines += k.allWindows.map { "aw: \(title($0)) sub=\(str($0, kAXSubroleAttribute))" }; continue
            }
            if s == "close-untitled" { lines += k.windows.filter { title($0).isEmpty }.map { "closed=\(k.close($0))" }; continue }
            if s == "main" {
                var out: [String: Any] = [:]
                main = k.mainChatWindow(&out)
                guard let m = main else { lines.append("no main: \(out)"); continue }
                for c in kids(m) where role(c) != kAXScrollAreaRole { dump(c, 0, 2) }
                if let sa = kids(m, kAXScrollAreaRole).first, let list = kids(sa).first {
                    lines.append("list role=\(role(list))")
                    let rows = (ax(list, kAXRowsAttribute) as? [AXUIElement]) ?? kids(list, kAXRowRole)
                    lines.append("rows=\(rows.count)")
                    for r in rows.prefix(6) { dump(r, 1, depth, maxKids: 12) }
                }
                continue
            }
            guard let m = main ?? k.windows(named: "카카오톡").first else { lines.append("need main"); continue }
            let rows: [AXUIElement] = {
                guard let sa = kids(m, kAXScrollAreaRole).first, let list = kids(sa).first else { return [] }
                return (ax(list, kAXRowsAttribute) as? [AXUIElement]) ?? kids(list, kAXRowRole)
            }()
            if s.hasPrefix("side=") { lines.append("side now=\(k.listSide(m)) ok=\(k.showSide(m, String(s.dropFirst(5))))"); continue }
            if s == "rows" { lines += rows.enumerated().map { "\($0.offset): \(k.rowTitle($0.element))" }; continue }
            if s.hasPrefix("row=") {
                let want = nfc(String(s.dropFirst(4)))
                for (i, r) in rows.enumerated() where k.rowTitle(r) == want { lines.append("index \(i)"); dump(r, 1, depth + 2) }
                continue
            }
            if s.hasPrefix("menu=") || s.hasPrefix("menupress=") {
                let press = s.hasPrefix("menupress=")
                let parts = String(s.drop(while: { $0 != "=" }).dropFirst()).components(separatedBy: "|")
                let want = nfc(parts[0])
                guard let r = rows.first(where: { k.rowTitle($0) == want }), let cell = kids(r).first else { lines.append("row not found"); continue }
                act(r, "AXScrollToVisible")
                act(cell, kAXShowMenuAction)
                pause(0.5)
                guard let mn = kids(cell, kAXMenuRole).first else { lines.append("no menu"); continue }
                let items = kids(mn)
                lines.append("items=\(items.map(title))")
                if press, parts.count > 1, let it = items.first(where: { title($0) == parts[1] }) { act(it, kAXPressAction); lines.append("pressed") }
                else { act(mn, kAXCancelAction) }
                pause(1.0)
                continue
            }
            if s.hasPrefix("win=") {
                let n = String(s.dropFirst(4))
                for w in (n == "-" ? k.windows.filter { title($0).isEmpty } : k.windows(named: n)) { dump(w, 0, depth, maxKids: 15) }
                continue
            }
            if s.hasPrefix("open=") {
                let want = nfc(String(s.dropFirst(5)))
                guard let r = rows.first(where: { k.rowTitle($0) == want }),
                      let sa = kids(m, kAXScrollAreaRole).first, let list = kids(sa).first else { lines.append("row not found"); continue }
                setAX(r, kAXSelectedAttribute, kCFBooleanTrue)
                setAX(m, kAXMainAttribute, kCFBooleanTrue)
                setAX(list, kAXFocusedAttribute, kCFBooleanTrue)
                pause(0.3)
                let sel = ((ax(list, kAXSelectedRowsAttribute) as? [AXUIElement]) ?? []).map(k.rowTitle)
                lines.append("selected=\(sel)")
                if sel == [want] { postReturn(k.pid) } else { lines.append("not pressing"); continue }
                pause(1.5)
                lines += k.windows.map { "win: \(title($0))" }
                continue
            }
            if s.hasPrefix("sleep=") { pause(Double(s.dropFirst(6)) ?? 1); continue }
        }
        return lines.joined(separator: "\n")
    }
}
