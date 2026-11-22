# kakaocli — native local history fork

This fork of [silver-flight-group/kakaocli](https://github.com/silver-flight-group/kakaocli) makes local KakaoTalk history retrieval work inside the compiled CLI. Native account recovery, key derivation, SQLCipher reads, resolved room names, regular/open chat kinds, paginated search, contact candidates and original-message context are built into `kakaocli`.

카카오톡 로컬 기록 조회를 CLI 내부에서 처리하는 포크입니다. 별도 Python 조회 스크립트 없이 일반·오픈채팅과 연락 후보를 검색하고 원문 근거를 확인합니다.

## Install and configure

Requirements: macOS, Swift 6.1 or newer, SQLCipher and the KakaoTalk Mac app. Tested with Apple Swift 6.4.

```sh
brew install sqlcipher
git clone https://github.com/PeraSite/kakaocli.git
cd kakaocli
./scripts/install.sh            # build, sign, install ~/.local/bin/kakaocli
export PATH="$HOME/.local/bin:$PATH"
kakaocli --version
```

`install.sh` signs with an "Apple Development" or "Developer ID Application" identity from your keychain when
there is one. macOS then ties the permissions below to that certificate and they survive rebuilds. With an
ad-hoc signature every rebuild silently loses them.

### Permissions

kakaocli needs two macOS permissions, and **only kakaocli** needs them:

| Permission | Used for |
|---|---|
| Full Disk Access | read the local KakaoTalk database (history, chat list, delivery check) |
| Accessibility | send: open the chat window, type into the input box, press send |

System Settings → Privacy & Security → *Full Disk Access* and → *Accessibility* → **+** → press ⌘⇧G →
`~/.local/bin/kakaocli`. If an older `kakaocli` entry is listed, remove it with **−** first (it is tied to the old
signature).

macOS checks the permissions of the app that *launched* a process. `kakaocli` typed in Terminal is checked
against Terminal, so you would have to give Terminal (and every script running in it) access to your whole disk.
Instead run it through **`scripts/kakao`**, which asks launchd to start kakaocli directly:

```sh
install -m 755 scripts/kakao ~/.local/bin/kakao
kakao permissions          # Read local DB: ok · Accessibility: ok
kakao status --json
kakao auth --save --json
```

`kakao` takes the same arguments as `kakaocli` and returns its output and exit code.

See [LOCAL_HISTORY.md](LOCAL_HISTORY.md) for copied DB/preferences setup, recovery options, private configuration
and full read examples. Reading needs no server login, KakaoTalk password, UI interaction or LOCO.

## Send messages

```sh
kakao send "Chat name" "Hello"                 # exact name, else a unique substring
kakao send --chat-id 1234567890 "Hello"        # IDs from `kakao chats --page`
kakao send --me "note to self"
kakao send --chat-id 1234567890 --file msg.txt --json
kakao send "Chat name" "Hello" --dry-run       # open, type, clear, close — nothing is sent
```

Sending drives the real KakaoTalk app through the macOS Accessibility API, like a person typing on the Mac.
It never emulates Kakao's server protocol (LOCO). What happens:

1. KakaoTalk is launched if it is not running, without coming to the front.
2. The chat window opens, fastest path first: an already open window; for one-to-one friend chats the
   `kakaotalk://friend?action=chat&user_id=…` deep link; otherwise the main window chat list, reading only the
   rows near the index predicted from the local DB ordering, then selecting the row and sending Return to
   KakaoTalk only (no mouse, no clipboard).
3. The text goes into the input box and send is pressed. A box that already contains text you were typing is
   never touched.
4. The window it opened is closed and the app you were using gets the focus back.
5. The local DB is checked for the new message from you with exactly that text.

A group chat measured 1.9 s end to end, including the database check.

Exit codes: `0` sent and found in the DB, `1` not sent (nothing was pressed), `2` chat not found or ambiguous,
`3` send was pressed but the message did not show up in the DB — check KakaoTalk before retrying.
`--json` prints `ok`, `step`, `pressed`, `how` (`already_open` · `deeplink` · `return` · `menu`), `verified`,
`log_id` and timings.

Chats inside folders (quiet chat rooms) have no row in the main list and are refused, as are names that match
several chats. Opening a chat marks its unread messages as read.

## Use with an agent

```sh
mkdir -p ~/.agents/skills
cp -R skills/kakaocli ~/.agents/skills/
kakaocli chats --kind open --page
kakaocli candidates --term '사장님' --term '대표님' --kind one-to-one --page
kakaocli search '사장님' --sender me --page
```

The [kakaocli skill](skills/kakaocli/SKILL.md) calls this native binary. Install it in the shared `~/.agents/skills` directory for agents that support this discovery path. For example: `$kakaocli 내가 연락했던 사장님과 가게를 대화 근거와 함께 전부 찾아줘`.

Candidates require context review: mentioning an owner in a friend chat does not establish contact with that owner. The skill checks original messages, separates store channels and group conversations, and follows all matching result pages. A local copy includes only its captured history; `status` exposes the source and available message period.

Run `swift test` for synthetic encrypted DB and chat-list ordering tests. `send` is this fork's own implementation; the upstream login and harvest commands are retained unchanged ([upstream documentation](https://github.com/silver-flight-group/kakaocli/blob/8b6ffcfdaebc592a735dc1a8bd5e50037e626406/README.md)).

## Disclaimer

> **This project is not affiliated with, endorsed by, or associated with Kakao Corp. in any way.**
>
> "KakaoTalk" and "카카오톡" are trademarks of Kakao Corp. This tool is an independent, unofficial project.
>
> **What this tool does:**
> - Reads the KakaoTalk local database on your own machine (read-only, never modifies it)
> - Automates the native KakaoTalk Mac client via standard macOS Accessibility APIs
>
> **What this tool does NOT do:**
> - Does not reverse-engineer or reimplement the KakaoTalk protocol (LOCO)
> - Does not call any Kakao APIs or servers
> - Does not decompile or modify the KakaoTalk application
> - Does not bypass any authentication or security mechanisms
>
> This tool accesses only your own data stored locally on your own computer. Use responsibly and at your own risk. The authors are not responsible for any consequences of using this software, including but not limited to account restrictions by Kakao.

## 면책 조항

> **이 프로젝트는 카카오와 제휴, 보증, 또는 관련이 없습니다.**
>
> "KakaoTalk" 및 "카카오톡"은 카카오의 상표입니다. 이 도구는 독립적인 비공식 프로젝트입니다.
>
> **이 도구가 하는 것:**
> - 사용자의 컴퓨터에 있는 카카오톡 로컬 데이터베이스를 읽기 전용으로 읽습니다
> - 표준 macOS 접근성 API를 통해 카카오톡 Mac 클라이언트를 자동화합니다
>
> **이 도구가 하지 않는 것:**
> - 카카오톡 프로토콜(LOCO)을 역분석하거나 재구현하지 않습니다
> - 카카오 API나 서버를 호출하지 않습니다
> - 카카오톡 애플리케이션을 디컴파일하거나 수정하지 않습니다
>
> 이 도구는 사용자 본인의 컴퓨터에 저장된 본인의 데이터에만 접근합니다. 책임감 있게 사용하시기 바랍니다. 카카오의 계정 제한 등 이 소프트웨어 사용으로 인한 결과에 대해 저자는 책임지지 않습니다.

## Credits / 크레딧

Developed by **[Brian ByungHyun Shin](https://github.com/brianshin22)** at **[Silver Flight Group](https://github.com/silver-flight-group)**.

Database decryption approach based on research by [blluv](https://gist.github.com/blluv/8418e3ef4f4aa86004657ea524f2de14).

Inspired by [wacli](https://github.com/steipete/wacli) by Peter Steinberger — a similar CLI tool for WhatsApp on Mac.

The chat-opening flow and KakaoTalk UI labels used by `send` follow the measurements in [kakaocli-skill](https://github.com/Tygb99/kakaocli-skill) by Tygb99 (MIT, Copyright (c) 2026 Tygb99), reimplemented with direct Accessibility calls.

Built with [Claude Code](https://claude.ai/code).

## License

MIT License. Copyright (c) 2026 Silver Flight Group, LLC. See [LICENSE](LICENSE) for details.

## [Changelog](CHANGELOG.md)
