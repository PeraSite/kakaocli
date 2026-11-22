# Changelog

### v0.8.0 - Fast UI sending and isolated permissions (fork)
- `send` rewritten: resolves the chat in the local DB (name, `--chat-id`, `--me`), opens it by deep link (one-to-one) or by the predicted chat-list row, types and presses send through Accessibility only, closes the window it opened and confirms delivery in the local DB. `--file`, stdin, `--dry-run`, `--json`, exit codes 0/1/2/3. No LOCO.
- `permissions` command: reports Full Disk Access and Accessibility for this executable (`--prompt` asks macOS).
- `scripts/install.sh`: builds and signs with a keychain development identity so permissions survive rebuilds.
- `scripts/kakao`: runs kakaocli through launchd so only kakaocli, not the terminal, needs the permissions.

### v0.5.0 - Chat Harvest (Phase 4)
- `harvest` command: bulk-capture chat display names and load message history
- Vision framework OCR to locate "View Previous Chats" button
- CGEvent-based clicking for reliable UI interaction
- CGWindow API for paywall popup detection
- Auto-dismiss Talk Drive Plus paywall dialogs
- MetadataStore: persistent chatId → displayName at `~/.kakaocli/metadata.json`
- `query` command: raw read-only SQL queries against the decrypted database

### v0.4.1 - Robust Auto-Login
- Fix credential storage: switch from Security framework to `security` CLI
- Fix state detection: use status bar menu when AX window is not visible
- Fix login transition: non-aggressive polling avoids interfering with login flow

### v0.4.0 - App Lifecycle & Login (Phase 3.5)
- `login` command: store/check/clear credentials (macOS Keychain)
- AppLifecycle: auto-launch KakaoTalk, auto-login via AX automation
- `ensureReady()` called before all send operations

### v0.3.0 - Agent Integration (Phase 3)
- `sync` command with `--follow` for real-time NDJSON message streaming
- Webhook support: `--webhook <url>` POSTs new message batches
- AGENTS.md: AI agent integration instructions

### v0.2.0 - UI Automation (Phase 2)
- Send messages via macOS Accessibility API
- `send` command with chat name matching
- `--me` flag for self-chat (나와의 채팅) via badge detection
- `inspect` command to dump UI element tree

### v0.1.0 - Database Reader (Phase 1)
- SQLCipher database decryption (PBKDF2-SHA256, cipher_default_compatibility=3)
- Auto-detect device UUID, user ID, container path
- `auth`, `chats`, `messages`, `search`, `schema`, `status` commands
- JSON output for all read commands
