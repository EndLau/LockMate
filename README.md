# LockMate

A Warlock summon queue addon for **World of Warcraft 3.3.5a (Wrath of the Lich King)**.

LockMate listens for players typing `123` in raid, party, or whisper chat and adds them to a summon queue. Click a name to cast Ritual of Summoning on them and announce it to the group. The queue syncs automatically with other players who have LockMate installed, and the window manages itself — appearing when someone needs a summon and hiding when the queue is empty.

---

## Requirements

- World of Warcraft client **3.3.5a** (Wrath of the Lich King, build 12340)
- You must be a **Warlock** with Ritual of Summoning trained

---

## Installation

1. Download the latest release and extract the zip
2. Copy the `LockMate` folder into:
   ```
   World of Warcraft\Interface\AddOns\
   ```
   The final path should look like:
   ```
   Interface\AddOns\LockMate\LockMate.toc
   Interface\AddOns\LockMate\LockMate.lua
   ```
3. Launch the game (or type `/reload`) and enable the addon on the character select screen

---

## How It Works

### Summon Queue

Any player who types **123** in a channel you are monitoring (configurable) is automatically added to the queue window. The window appears on screen when at least one player is waiting and hides itself when the queue is empty.

| Action | Result |
|--------|--------|
| Player types `123` in raid/party/whisper | Added to the summon queue |
| **Left-click** a name in the list | Targets the player, casts Ritual of Summoning, and announces to the group |
| **Right-click** a name in the list | Removes the player from the queue |
| Queue becomes empty | Window auto-hides |

**Combat check** — if the player is in combat when you click their name, LockMate whispers them `"Can't summon you while in combat!"` and does nothing else.

**Already summoned** — if you click a player who was already summoned this session and is still nearby, a local notice appears instead of casting again.

### Queue Sync

When two or more players in the same raid or party both have LockMate loaded, their queues are kept in sync automatically using addon messages. Adding, removing, or summoning a player broadcasts that change to all LockMate users in the group. When a new member joins, their client requests a full snapshot of the current queue so they are immediately up to date.

### Soul Shard Management

LockMate can automatically delete Soul Shards from your inventory when you exceed a configurable limit. It correctly handles **stacking shards** (servers where shards stack to more than 1) by reading actual stack sizes rather than slot counts. Shards in regular bags are deleted first; shards in Soul Shard bags are only removed if you are still over the limit after clearing the regular bags.

---

## Settings (`/lm`)

Open the settings window by typing `/lm` or clicking the gear icon (⚙) in the top-right corner of the queue window. All changes are buffered — nothing is applied until you click **Save**. Clicking **Cancel** or the X button discards all changes.

### Listen Channels
Choose which channels LockMate monitors for the `123` keyword:
- `/Raid chat`
- `/Party chat`
- `/Whispers` (direct messages to you)

### Summon Announcement
Customise the message sent when you begin a summon. Use `%s` as a placeholder for the player's name.
Default: `Summoning %s. Click the portal!`

### Send Announcement Via
- **Group chat** — posted to /Raid, /Party, or /Say depending on your group status
- **Whisper** — also whispered to the player being summoned

### Soul Shard Management
- **Auto-delete** — enable or disable automatic shard deletion
- **Silent deletion** — suppress the chat notification when shards are deleted
- **Max shards slider** (0–84) — shards above this limit are deleted after you save

### Window Settings
- **Lock window** — when locked the queue frame cannot be moved or resized
- **Unlock** — drag the title bar to reposition; drag the bottom-right corner to resize
- **Background opacity** — control how transparent the window background is (0–100%)

---

## Changelog

### v1.1.0
- **Group membership check** — players are now only added to the summon queue if they are in your current party or raid. Previously a whisper containing `123` from anyone, including players you were no longer grouped with, would appear in the list.
- **Queue auto-clears on group change** — when a player leaves the group they are automatically removed from the queue. If you leave or the group fully disbands, the entire queue is wiped immediately.
- **Self excluded from queue** — your own character name will never appear in your local queue list, even if you type `123` yourself or receive a sync from another LockMate user.
- **Party leader chat now detected** — previously the party leader's messages fired `CHAT_MSG_PARTY_LEADER` instead of `CHAT_MSG_PARTY`, causing their `123` to be silently ignored. Both events are now handled.

### v1.0.0
- Initial public release.

| Command | Description |
|---------|-------------|
| `/lm` | Toggle the settings window |
| `/lm show` | Pin the queue window open even when the queue is empty |
| `/lm hide` | Hide the queue window (it will reappear automatically when someone queues) |
| `/lm clear` | Remove everyone from the queue |
| `/lm help` | Print the command list |


