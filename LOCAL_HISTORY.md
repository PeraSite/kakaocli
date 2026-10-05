# Native local-history fork

This fork adds reliable local KakaoTalk database setup and evidence retrieval for AI agents. Recovery, key derivation, SQLCipher reads, contact candidates and context lookup are implemented inside the compiled `kakaocli` executable. No Python helper, exported archive, Kakao server login or LOCO call is required for these commands.

## Build and install

Requirements: macOS, Swift 6.1 or newer (tested with Apple Swift 6.2.3), and SQLCipher.

```sh
brew install sqlcipher
git clone https://github.com/PeraSite/kakaocli.git
cd kakaocli
swift build -c release
mkdir -p ~/.local/bin
install -m 755 .build/release/kakaocli ~/.local/bin/kakaocli
export PATH="$HOME/.local/bin:$PATH"
```

The fork reports `0.7.0-local.1`. Development tests use the pinned official Swift Testing package so the test suite can run with Command Line Tools as well as Xcode.

## First local setup

If your terminal already has access to KakaoTalk's container:

```sh
kakaocli auth --save --json
kakaocli status --json
```

If the OS prevents direct container access, use Finder to copy the encrypted DB, its matching `-wal` and `-shm` files, and KakaoTalk preference plists into a private local directory. Then provide those paths:

```sh
kakaocli auth --db /path/to/copied/database \
  --preferences-dir /path/to/copied/preferences --save --json
```

`auth` checks both `DESIGNATEDFRIENDSREVISION` and `DENYFILEEXTIONSIONREVISION` account markers, tests inexpensive numeric candidates first, and then runs a bounded native multithreaded SHA-512 recovery. Defaults are a 6-billion exclusive ID ceiling and 120 seconds; `--max-user-id`, `--recover-timeout`, `--workers`, `--user-id` and `--uuid` can be supplied when needed.

The recovered ID must decrypt the database and match `NTChatContext`. The verified local configuration is saved as `~/.kakaocli/config.json` with mode `0600`. It contains the user ID, device UUID, source DB path and optional preference path. The derived passphrase is computed in memory and is never stored or printed. `KAKAOCLI_CONFIG` can select a different configuration file without changing HOME.

Subsequent commands reuse that configuration. A copy remains a copy: `status` explicitly reports `local-copy` or `live-local-db` and the available message timestamps. This fork does not bypass macOS file access controls or load missing history from the server.

## Agent retrieval

```sh
kakaocli chats --page --limit 40 --offset 0
kakaocli chats --kind open --page
kakaocli chats --kind one-to-one --contacted --page
kakaocli search '사장님' --sender me --page --limit 40
kakaocli candidates --term '사장님' --term '대표님' \
  --title-term '사장' --title-term '대표' --kind one-to-one --page --limit 40
kakaocli context --chat-id 12345 --log-id 9007199254740993 --msg-id 1 --before 5 --after 5 --json
kakaocli query 'SELECT chatId,logId,msgId,message FROM NTChatMessage LIMIT 10' --named
```

The numeric context IDs above are examples; use IDs from real search results. Paginated responses include `total`, `offset`, `limit`, `next_offset` and `rows`. Iterate until `next_offset` is null when a complete matching set is needed. Chat/message ID fields are JSON strings so 64-bit identifiers are not rounded by JavaScript.

Chat names come from local custom names, group metadata, open-link titles, contact profiles and binary-plist member lists. `kind` distinguishes `direct`, `group`, `channel`, `open-direct`, `open-group`, `self` and `unknown`; `open` and `one-to-one` are filter aliases. Names constructed from members have `name_source=displayMemberIds`.

`candidates` returns evidence-bearing candidates, not definitive role classifications. It defaults to chats you have actually authored messages in, excludes self-chat, and marks channel/group cases requiring additional identity review. A store channel does not establish that its operator is the owner; an owner mentioned in a friend chat does not establish contact with that owner. Use `context` to resolve these cases.

`messages --chat` checks all locally listed chats and refuses ambiguous matches instead of silently selecting the first 200 rooms. `--sender` and page options are available on `messages` and `search`. Raw message types and attachment metadata are preserved.

## Skill

`skills/kakaocli/SKILL.md` directs agents to these native commands and explains coverage, pagination, evidence and contact identity checks. Copy that folder to `~/.agents/skills/kakaocli` for shared discovery by compatible agents. The skill's runtime dependency is the compiled `kakaocli` binary.

## Validation

```sh
swift test
swift build -c release
```

Tests create synthetic SQLCipher databases. They cover account marker variants and bounded recovery, encrypted reads, complete name resolution, open profile scoping, pagination, composite message identity, read-only SQL enforcement, candidate scope and private identifier caching. Real databases and keys are never committed. See the calling chat's local validation report for measurements against that Mac; personal source data is intentionally outside this repository.

The original key derivation is retained from upstream's implementation, which credits [blluv's local DB research](https://gist.github.com/blluv/8418e3ef4f4aa86004657ea524f2de14). This fork retains the upstream MIT license. Existing UI-based sending commands remain separate from the local-history workflow.
