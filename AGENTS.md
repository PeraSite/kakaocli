# Agent guide for the local-history fork

Read [LOCAL_HISTORY.md](LOCAL_HISTORY.md) for build, local setup and CLI contracts.

The local database commands do not need KakaoTalk passwords, server login, UI automation or LOCO. Use this fork's compiled binary and its native auth, status, chats, messages, search, candidates, context and query commands. auth --save validates and privately caches local identifiers; never include the derived key, real account identifiers, real preferences or personal chat data in source control.

- Keep SQL reads read-only and ID output lossless.
- Preserve page totals and composite message identity (chatId, logId, msgId).
- Distinguish store channels, regular chats and open profiles.
- Treat contact candidates as candidates until original context supports the role/relationship.
- Use synthetic encrypted databases in tests; real-data validation stays outside the repository.
- Run swift test, swift build -c release, and validate the skill after relevant changes.
- OS file access failures are distinct from decryption failures. Support readable original data or authorized local copies; do not introduce server login or a permission bypass as a fallback.

Existing UI send/login/harvest commands are separate upstream functionality. When working on them, honor the user's explicit scope, validate the exact chat and message, and use self-chat/dry-run for any authorized send tests. Local-history testing never needs to send a message.
