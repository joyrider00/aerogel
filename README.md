# Aerogel

A glass HUD for Slack on macOS. A message comes in, a glass toast slides into the top-right corner, you click it, the thread opens right there, you reply, and you're back to work. Slack never comes to the front.

- **Toasts → thread in place.** Click a toast and the whole thread (or DM) opens beside your inbox, with full history.
- **Needs-you inbox.** DMs, group DMs, @mentions, keywords, and replies in threads you've posted in, grouped per thread. Replying from anywhere (including real Slack) clears the item.
- **Reply like Slack.** Enter sends, Shift-Enter adds a newline, `@name` mentions resolve, "Also send to #channel" is there, and you can attach files by paste, drag, or the paperclip.
- **React, edit, delete, copy link.** Hover a message for quick reactions and the full emoji picker (custom workspace emoji included).
- **Jump anywhere.** ⌘K opens any channel or DM, or starts a new DM.
- **Keyboard first.** Use the shortcuts below.
- **Stays in sync with Slack.** Opening a channel or DM marks it read in Slack too.
- **Liquid Glass.** Built with the macOS 26 SDK it uses Apple's native `glassEffect`. Older SDKs and macOS 13–15 get a hand-tuned translucent aerogel material instead.

| Shortcut | Action |
|---|---|
| ⌃⌥Space | Show / hide HUD (from anywhere) |
| ⌃⌥R | Open the newest item, cursor in the reply box |
| J / K or ↑ / ↓ | Move through inbox |
| ↵ | Open |
| E | Mark done |
| R | Focus reply |
| ⌥↑ / ⌥↓ | Next / previous item, even while typing |
| ⌘K | Jump to channel or person |
| ⌘O | Open current conversation in Slack |
| S | Snooze the selected item for an hour (hover it for other times) |
| ⌘[ | Back |
| Esc | Back out one level (picker → assistant → edit → thread → hide) |

## Slash commands

Type `/` in any reply box (or a toast's reply field) for suggestions.

- **`/assistant <message>`** asks your own assistant server about the conversation you're in, or tells it what to do ("summarise this thread", "draft a reply saying we'll ship Friday"). A panel opens above the reply box, where follow-ups need no prefix. The assistant gets the messages on screen and which channel and thread they're from. Drafts come back as cards: edit them, then **Send** (posts as you) or **Discard**. Nothing is posted without that click. Esc goes back to Slack. Set it up in Settings → Assistant. If you give it a name there, the command uses that name too: "Friday" makes `/friday`.
- **Your own commands are files.** Each file in `~/Library/Application Support/Aerogel/Commands/` is a command named after the file: `silence.mp4` makes `/silence`, which uploads that video. `.txt` and `.md` files send their text instead (saved replies). Words after the command go along as a caption.

## Install

Requires macOS 13+ and Swift 5.9+ (Xcode or the Command Line Tools).

```sh
git clone https://github.com/joyrider00/aerogel && cd aerogel
scripts/build-app.sh --demo      # try it with a fake workspace first
scripts/build-app.sh --install   # build and copy to /Applications
```

## Connect Slack (about one minute)

Each person creates their **own** private Slack app. That's deliberate:

- **Privacy.** Socket Mode delivers events to whoever holds the app token. If one app were shared across a team, every member's DMs would flow through the same socket. With one app per person, your messages go only to your Mac.
- **Rate limits.** Slack throttles `conversations.history` and `conversations.replies` heavily for distributed apps that aren't in the Slack Marketplace. Internal, single-workspace apps are exempt.

Steps:

1. Open Aerogel → Settings → **Create Slack app**. The button opens api.slack.com with [`slack-manifest.json`](slack-manifest.json) prefilled. Pick your workspace and click Create.
2. **Install to Workspace**, then copy the **User OAuth Token** (`xoxp-…`) from *OAuth & Permissions*.
3. In *Basic Information → App-Level Tokens*, generate a token with the `connections:write` scope (`xapp-…`).
4. Paste both tokens into Settings and click **Save & Connect**. Tokens are stored in `~/Library/Application Support/Aerogel/secrets.json`, readable only by your macOS user (encrypted at rest only if FileVault is on). Not the Keychain: an app you build yourself has no Apple team ID, so the Keychain would ask for your password after every rebuild.
5. Turn off Slack's own desktop notifications (Slack → Settings → Notifications) so you don't get two of each.

Some workspaces require admin approval before you can install apps. If yours does, the install step will say so.

## Assistant API

`/assistant` works with any server that implements these endpoints. Every request carries `Authorization: Bearer <token>`. Aerogel only sends the token over HTTPS, or plain HTTP to `localhost`.

- **`GET /types`**: any 2xx response. Used only by **Save & Test**.
- **`POST /ask/stream`**: the body is JSON:
  ```json
  { "text": "the question",
    "screen": "the conversation as plain text",
    "slack": { "channel": "C…", "name": "#general", "thread": "1700000000.000100 (only in a thread)" },
    "conversationId": "returned by an earlier reply; omitted on the first question" }
  ```
  Reply with server-sent events. Each event is an `event:` line followed by a `data:` line holding JSON:
  - `event: text` with `{"text":"…"}` streams the answer.
  - `event: tool` with `{"name":"…"}` shows what it's doing.
  - `event: done` with `{"text":"…","conversationId":"…","approvals":[…]}` finishes the reply.
  - `event: error` with `{"error":"…"}` reports a failure.

  Each approval is `{"id","kind","status","payload":{"text","to"}}`. Approvals with `kind: "slack"` render as editable draft cards.
- **`POST /approvals/:id/decide`**: the body is `{"approve": true|false, "edits": {"text": "…"}}`. The response is `{"status": "sent", "error": null}`. Your server does the sending, so nothing goes out until the user clicks Send.

Treat `screen` as untrusted: it contains other people's messages.

## How it works

```
Slack ──Socket Mode (WebSocket, user events)──▶ SocketModeClient
                                                     │
                                       AppModel.handle(event)
                       classify: DM / mention / keyword / watched thread
                                                     │
                          InboxItem ──▶ glass toast or macOS notification
                                                     │ click
                         HUD panel ◀── conversations.replies / history
                                                     │ reply
                                     chat.postMessage / files upload v2
```

- `Sources/Aerogel/Slack`: Web API client (429-aware), Socket Mode client (acks, reconnect with backoff, ping, reconnect on wake), models, and the app manifest.
- `Sources/Aerogel/Core`: `AppModel` (all state and Slack actions), the mrkdwn renderer, emoji table, token and state storage, the global hotkey, and the demo workspace.
- `Sources/Aerogel/UI`: the non-activating floating panels, glass material, inbox, thread view, composer, and settings.

The HUD is an `NSPanel` with `.nonactivatingPanel`. It floats over full-screen apps and doesn't steal focus from the app you were in until you click into the reply box.

## What Slack's API can't do (yet)

These open in the real Slack app via ⌘O:

- **Huddles and canvases.** There's no public API for joining huddles or editing canvases.
- **Per-thread read state.** Slack's API has no way to mark a single thread as read, so the "Threads" view in Slack may still show unread replies you already answered from Aerogel. Channel and DM read state syncs correctly.
- **"Threads you follow."** The API doesn't expose your followed threads. Aerogel tracks threads you've posted in, started, or been mentioned in, starting from when you install it.

## Roadmap ideas

- Customizable hotkeys
- Snooze ("remind me in 1h")
- Rich Block Kit rendering (currently shows the message's text fallback)
- Multiple workspaces
- Signed and notarized releases with Sparkle updates

## License

MIT
