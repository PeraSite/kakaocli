# Native CLI details

All retrieval below is implemented in this fork's compiled `kakaocli`. A Python script or exported SQLite archive is not the backend.

## Coverage and setup

Run `kakaocli --version` and `kakaocli status --json`. This fork's version is `0.7.0-local.1`. If PATH selects upstream, prefer the installed `~/.local/bin/kakaocli` and use that executable consistently.

`status` reports `database_path`, `source_mode`, counts by kind, and `first_message_epoch`/`last_message_epoch`. Epochs are Unix seconds. A `local-copy` is a fixed copy; a `live-local-db` is the KakaoTalk container. Neither includes messages that are only on Kakao's server.

First setup is `kakaocli auth --save --json`; for a copied DB/preferences use `--db` and `--preferences-dir`. No Kakao password or server login is needed. If the OS denies file access, use an authorized local copy or an execution app with appropriate macOS access. Do not fall back to login, LOCO or opening chats to load server history.

The configuration contains verified local identifiers and the DB path with file mode 0600. Do not copy its contents into prompts, code, skill files or public repositories. Commands derive the key internally.

## Lists and evidence

- `chats --page [--kind KIND] [--contacted] --limit N --offset N`: resolved names, `name_source`, `kind`, `message_count`, `sent_message_count`, IDs and times.
- `messages --chat-id ID --page [--sender any|me|others] [--since 7d]`: recent records. `--chat NAME` is supported for one unambiguous name; IDs are preferable.
- `search TEXT --page [--sender me|others|any] [--chat-id ID]`: literal substring search with total/next offset.
- `candidates --term WORD --term WORD [--title-term WORD] --page`: OR matching in names and conversation, by chat. Add `--kind one-to-one`, `--kind open`, or a specific kind where useful. `--evidence 0...5` controls preview count. Defaults exclude self-chat and chats without your own messages; `--include-uncontacted` changes the latter explicitly.
- `context --chat-id ID --log-id ID [--msg-id ID] --before N --after N --json`: the full message and neighbors. Specify msg_id if a log has multiple local records. Each side is limited to 0...30 records.
- `query 'SELECT ...' --named`: complex read-only queries, with named columns and string IDs. Mutation, database attachment, disabling query_only, and extension loading are blocked.

`--page` responses have `rows`, `total`, `offset`, `limit`, `next_offset`, `database_path`, and `read_only`. Continue with the returned next offset without changing conditions. `--json` remains an array on chats/messages/search; candidates returns its new page object. IDs are strings. `context` is chronological. `type` is the original numeric message type, `message_kind` is a coarse legacy label, `timestamp` is UTC and `timestamp_kst` is Korean time. Attachments are metadata, not downloaded files.

## Contact interpretation

`candidates` returns `candidate_list_only=true`, `my_matches`, `other_matches`, `title_matches`, first/last contact times and evidence. `review_note` explains channel or group identity concerns. These are retrieval signals rather than proof of a person's role.

`kind=channel` represents an organization/store account. `open-direct` is an open personal chat and `open-group` an open group. Do not count all group members as contacted owners. Names with `name_source=displayMemberIds` are assembled from participants and may mention several people.

For a group, use `query --named` to group actual senders, then inspect the relevant messages:

```sql
SELECT authorId AS sender_id, count(*) AS messages
FROM NTChatMessage WHERE chatId=12345 AND authorId!=0
GROUP BY authorId ORDER BY messages DESC
```

Within an open chat, NTUser profiles are scoped by `(userId,linkId)`. Open and regular profile IDs can differ. A name alone is insufficient to merge people across chats.

## Raw schema anchors

- NTChatRoom: chatId, linkId, type, chatName, directChatMemberUserId, displayMemberIds.
- NTChatMeta(type=3): groupNickname/content hold group titles.
- NTOpenLink: linkId/linkName hold open-link titles.
- NTUser: userId/linkId and displayName/friendNickName/nickName.
- NTChatMessage: `(chatId,logId,msgId)` is the message key; authorId, message, type, sentAt, attachment, supplement.

The tested type mapping is 0=direct, 1=group, 2=channel, 3+positive linkId=open-direct, 4+positive linkId=open-group, 5=self. Check `schema` and actual link/member data after an application schema update. Message-only histories absent from NTChatRoom are still returned by search/messages; contact candidate enumeration covers locally listed rooms, so additional search is appropriate when historical completeness matters.
