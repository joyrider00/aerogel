# Slack Glass

Answer Slack without opening Slack. When a message arrives, a glass toast slides into the top-right corner of your Mac. Click it and the whole thread opens right there, floating over whatever you were doing. Reply, press Enter, and you're back to work. The Slack window never comes to the front.

Slack Glass is a small macOS menu-bar app built on Slack's public API. It's free and open source, and it runs entirely on your Mac.

> Slack Glass is an independent project. It isn't made, endorsed or supported by Slack Technologies or Salesforce.

## Contents

- [What you get](#what-you-get)
- [Install](#install)
- [Set up a team server](#set-up-a-team-server)
- [Connect your Slack](#connect-your-slack)
- [Using it](#using-it)
- [Slash commands](#slash-commands)
- [Settings](#settings)
- [Privacy and security](#privacy-and-security)
- [Troubleshooting](#troubleshooting)
- [Update or uninstall](#update-or-uninstall)
- [Assistant API](#assistant-api)
- [How it works](#how-it-works)

## What you get

- **Toasts that open in place.** Click a toast and the thread or DM opens in a floating panel with its full history. You can also reply straight from the toast.
- **An Activity inbox.** DMs, group DMs, @mentions, your keywords, and new replies in threads you've posted in, grouped by thread. Opening an item clears it, and so does replying from anywhere, including Slack itself.
- **Chats.** Browse and search every channel and DM, and use the arrow keys to move through the results. When nothing needs you, this is what you see.
- **Search.** Search every message you can see in Slack, using Slack's own modifiers (`from:@maya`, `in:#eng`, `has:link`). Open a result and it jumps to that message in its thread or channel.
- **Reply like Slack.** Enter sends, Shift-Enter adds a new line, and typing `@` suggests people to mention. "Also send to #channel" works too. You can attach files by pasting, by dragging them (screenshots included), or with the paperclip.
- **Schedule, snooze and drafts.** Schedule a message for later. Snooze an item until it matters. Whatever you half-typed in a conversation is still there when you come back.
- **React, edit, delete and copy links.** Hover a message to get quick reactions and the full emoji picker, including your workspace's custom emoji.
- **Images, videos and presence.** Click an image to see it full size, or a video to play it right there; you can copy either or save it to Downloads. Green dots show who's online.
- **PDFs open in Preview.** Other files, and Slack links, open in the Slack app at the message they were posted in, never in a browser tab.
- **Slash commands made from files.** Drop `party.gif` into a folder and `/party` sends it.
- **An optional AI assistant.** Bring your own assistant server and type `/assistant` to have it read a thread or draft a reply. Nothing is sent until you click Send.
- **Keyboard first.** Every action has a shortcut (see [Shortcuts](#shortcuts)).
- **Glass that matches your Mac.** It uses Apple's Liquid Glass when built with the macOS 26 SDK, and a hand-tuned frosted material on macOS 13–15.

## Install

**If your team has a Slack Glass server**, open Terminal and paste the command your team shared. It looks like this:

```sh
curl -fsSL https://slack-glass-relay.yourteam.workers.dev/install | bash
```

Slack Glass opens. Click **Sign in with Slack**, then **Allow**. That's all. Do the same on each of your Macs; every Mac you're signed in on gets every message.

**Otherwise**, build the app yourself. It takes about two minutes and needs no programming knowledge.

**Requirements:** macOS 13 Ventura or newer, and Apple's free command-line developer tools.

1. Open **Terminal** (press ⌘Space, type "Terminal", press Enter).
2. If you've never installed the developer tools, run this and click **Install** in the window that appears:
   ```sh
   xcode-select --install
   ```
3. Download and build Slack Glass:
   ```sh
   git clone https://github.com/joyrider00/slack-glass.git
   cd slack-glass
   scripts/build-app.sh --demo
   ```
   This opens Slack Glass with a **fake workspace**, so you can try everything without connecting Slack. Click the little glass bubble under your menu-bar clock, or press **⌃⌥Space** (Control-Option-Space). A fake message arrives a few seconds after launch. When you're done, quit it from the menu-bar icon (right-click → Quit).
4. Install it for real:
   ```sh
   scripts/build-app.sh --install
   ```
   This copies **Slack Glass.app** to your Applications folder and opens it, which brings up the Settings window.

## Set up a team server

A team server (the `relay/` folder) is a small Cloudflare Worker. It makes setup one click for everyone on your team and sends each message to every Mac a person is signed in on. One person sets it up once, in about ten minutes, on a free Cloudflare account:

```sh
relay/setup.sh
```

The script deploys the server, opens its setup page, and asks for four values from the Slack app that the page creates for you: the **Client ID**, **Client Secret** and **Signing Secret**, plus an **app-level token** with the `authorizations:read` scope. When it finishes it prints your team's install command. A Slack admin may need to approve the app.

How it works: the team's Slack app sends its events to the server. For each event, the server asks Slack which teammates can see it and pushes it to all of their signed-in Macs over a live connection. It keeps the last 15 minutes, so a Mac that was asleep catches up when it wakes. It stores each signed-in person's Slack token (so all their Macs can use it), hashed device sessions, and that 15-minute buffer. Signing out on your last Mac deletes your token. Sending, history, search and files still go straight from your Mac to Slack.

To publish a new build for the install command, run `scripts/release.sh <version>`.

## Connect your Slack

Without a team server, Slack Glass connects through a private Slack app you create yourself (Settings → **Use your own Slack app instead**). Use a separate app on each Mac: Slack splits one app's messages between all the Macs connected to it.

Slack Glass talks to Slack through a small private Slack app that **you** create in your own workspace. Nobody else, including the author of Slack Glass, has access to it. Setup takes about a minute. The Settings window walks you through these steps:

1. **Create the app.** Click **Create Slack app** in Settings. Your browser opens api.slack.com with everything already filled in from [`slack-manifest.json`](slack-manifest.json). Pick your workspace and click **Create**.
2. **Install it and copy your user token.** In the Slack app's page, open **Install App** (or **OAuth & Permissions**), click **Install to Workspace** and allow it. Copy the **User OAuth Token**. It starts with `xoxp-`. Paste it into field 2 in Settings.
3. **Create an app-level token.** Go to **Basic Information → App-Level Tokens**, click **Generate Token and Scopes**, give it any name, add the **`connections:write`** scope and click **Generate**. Copy the token. It starts with `xapp-`, or `xoxe.xapp-` if your workspace uses rotating tokens. Paste it into field 3.
4. **Only if a token starts with `xoxe.`:** your workspace issues tokens that expire. Settings shows a fourth step. Paste the **Refresh token** from the same dialog, plus the **Client ID** and **Client Secret** from **Basic Information → App Credentials**, so Slack Glass can renew the tokens on its own.
5. Click **Save & Connect**. The status should change to **Connected**.
6. **Turn off Slack's own desktop notifications** (Slack → Settings → Notifications) so you don't get every message twice.

**Why does everyone create their own app?** Slack delivers messages over a live connection to whoever holds the app-level token. With one shared app, everyone's DMs would flow through the same connection. With one app per person, your messages go only to your Mac. Single-workspace apps also avoid the strict rate limits Slack places on apps that aren't in its Marketplace.

**Can't install apps?** Some workspaces need an admin to approve new apps. If yours does, the install step will say so, and you can request approval from there.

## Using it

### The basics

- **The bubble** sits just under your menu-bar clock and shows how many items need you. Click it to open or close the panel, or drag it anywhere; it remembers where you put it. You can turn it off in Settings.
- **The menu-bar icon** does the same: left-click to open, right-click for Settings and Quit.
- **Toasts** appear when something needs you. Click one to open the thread, type in its reply box to answer without opening anything, or let it fade after 8 seconds.
- **The panel** has three tabs:
  - **Activity:** the inbox described above.
  - **Chats:** every channel and DM. Start typing to search, use ↑↓ to pick one, and press Enter to open it.
  - **Search:** messages across Slack (see [Searching](#searching)).
- **Opening a conversation** shows it to the left of the inbox. ⌘[ goes back, and Esc closes one layer at a time.
- Slack Glass **doesn't take focus** from the app you're in until you click into the reply box. Clicking anywhere outside the panel closes it.

### Replying

- **Enter** sends. **Shift-Enter** starts a new line.
- **Mention someone** by typing `@` and part of their name. Suggestions start with the people in the conversation, then people you've talked to recently. Use ↑↓ and Enter or Tab (or click) to insert one. In channels, `@here`, `@channel` and `@everyone` are offered too.
- **Attach files** by pasting them (⌘V), dragging them onto the conversation, or clicking the paperclip. You can drag the screenshot preview that appears after ⌘⇧4 straight in.
- **Schedule a message** with the clock button next to Send: in 1 hour, in 3 hours, tomorrow at 9 AM, Monday at 9 AM, or a custom time.
- **Drafts** are saved per conversation as you type. A ✎ in the inbox marks conversations with an unsent draft.
- **Hover a message** to react, edit or delete your own messages, copy a link, or open it in Slack.

### Searching

Press **⌘F** or click **SEARCH**, then type. Results appear as you type, newest first. Use ↑↓ to move and Enter to open one. The message opens in its thread, or in its channel with the conversation around it, highlighted.

Slack's search modifiers all work: `from:@maya`, `in:#eng`, `in:@sam`, `has:link`, `has:file`, `is:thread`, `before:2026-01-01`, `after:2026-06-01`, and `"exact phrase"`. The chips under the search box add the common ones for you, including **In #this-channel** for the conversation you have open.

### Snoozing

Hover an inbox item and click the moon to snooze it for 20 minutes, 1 hour, 3 hours, until tomorrow at 9 AM, or until Monday at 9 AM. Press **S** to snooze the selected item for an hour. Snoozed items come back on their own, or straight away if someone replies. To see them, or bring one back early, click **N snoozed** at the bottom of the inbox.

### Shortcuts

| Shortcut | Action |
|---|---|
| ⌃⌥Space | Show or hide the panel, from any app |
| ⌃⌥R | Open the newest item with the cursor in the reply box |
| J / K or ↓ / ↑ | Move through the inbox |
| Enter | Open the selected item |
| E | Mark the selected item done |
| S | Snooze the selected item for an hour |
| R | Jump to the reply box |
| ⌥↓ / ⌥↑ | Open the next or previous item, even while typing |
| ⌘K | Jump to any channel or person, or start a new DM |
| ⌘F | Search messages |
| ⌘[ | Back |
| ⌘O | Open the current conversation in Slack |
| ⌘W | Close the panel |
| Esc | Back out one layer: picker → assistant → edit → conversation → close |

In the image and video viewer, Space plays or pauses a video, ⌘C copies, ⌘S saves to Downloads, and Esc closes the viewer (and only the viewer).

## Slash commands

Type `/` in any reply box, including a toast's, to see your commands. Tab completes one.

### Commands are files

Every file in `~/Library/Application Support/Slack Glass/Commands/` becomes a command named after the file:

| File | Command | What it sends |
|---|---|---|
| `shipit.gif` | `/shipit` | Uploads the GIF |
| `nope.mp4` | `/nope` | Uploads the video |
| `standup.txt` | `/standup` | Sends the file's text (handy for saved replies) |

Words after the command are sent along as a caption, for example `/shipit finally`. To open the folder, go to Settings → General → **Open Commands folder**. You don't need to restart after adding files.

### `/assistant`

If you run your own AI assistant server, Slack Glass can hand it the conversation you're looking at. Type `/assistant summarise this thread` or `/assistant draft a reply saying we'll ship Friday`. A panel opens above the reply box; follow-up questions need no prefix.

- The assistant receives the messages on screen and which channel and thread they're from.
- Anything it drafts appears as a card. Edit it, then click **Send** (it posts as you) or **Discard**. **Nothing is posted without that click.**
- **Use as my reply** copies an answer into your reply box instead.
- If you name the assistant in Settings, the command uses that name: "Friday" makes `/friday`.

Set it up in Settings → Assistant. Your server needs to implement the small [Assistant API](#assistant-api) below.

## Settings

| Section | What's there |
|---|---|
| Connect Slack | The setup steps, your tokens, and the connection status |
| Notifications | Glass toasts, macOS notifications, or badge only; sound; whether @here and @channel count; extra keywords to watch for |
| Assistant | Name (and slash command), server address, token, and a connection test |
| General | Glass tint (clear to smoky), the floating bubble, your slash commands, launch at login, and the shortcut list |

## Privacy and security

- **Nothing leaves your Mac except calls to Slack's API,** plus your assistant server if you set one up. There's no analytics, tracking or server run by this project.
- **Tokens** are stored in `~/Library/Application Support/Slack Glass/secrets.json`. Only your macOS user can read that file, and Slack Glass never writes it anywhere else. Turn on **FileVault** (System Settings → Privacy & Security) so it's encrypted at rest too. (Slack Glass doesn't use the Keychain because an app you build yourself has no Apple developer ID, so the Keychain would ask for your password after every rebuild.)
- **Your inbox, drafts and snoozes** are stored in `state.json` in the same folder.
- **Links in messages** open only if they're web, email or Slack links. A link someone sends can't launch a local file or another app.
- **Your token is sent only to Slack** (`*.slack.com`), never to image or link hosts.
- **The assistant token** is only sent over HTTPS, or plain HTTP to your own Mac (`localhost`).
- **Revoke access at any time:** delete the app at [api.slack.com/apps](https://api.slack.com/apps), or click **Remove tokens** in Settings.

The permissions the Slack app asks for are listed in [`slack-manifest.json`](slack-manifest.json). It reads and writes messages, reactions and files as you, searches messages, and reads users, channels and custom emoji.

## Troubleshooting

**"Save & Connect" stays greyed out.** The hint under the fields says which token is in the wrong place. Field 2 takes the `xoxp-` user token and field 3 takes the `xapp-` (or `xoxe.xapp-`) app-level token. A token starting with `xoxe.` also needs step 4.

**The inbox is empty after connecting.** It only collects messages that arrive after Slack Glass connects. Older conversations are under **Chats**.

**"You're not in #channel."** You can read a channel only after joining it. Press ⌘O to open it in Slack and join there.

**Messages arrive late or not at all.** Check the status in Settings. Slack Glass reconnects on its own after sleep or network changes. If it keeps failing, click **Save & Connect** again. If you use rotating tokens, make sure step 4 is filled in.

**Search says it needs one more permission.** Your Slack app was created before search was added. On [api.slack.com/apps](https://api.slack.com/apps), open your app → **OAuth & Permissions** → **User Token Scopes**, add `search:read`, then click **Reinstall to Workspace**. The User OAuth Token normally stays the same. If the page shows a different one, paste it into Settings.

**I get every notification twice.** Turn off desktop notifications in Slack itself.

**No typing indicators?** Slack's API doesn't send them to apps like this one. Online dots work.

**The build fails.** Run `xcode-select --install` again, then try `swift --version`. You need Swift 5.9 or newer.

## Update or uninstall

**Update:**

```sh
cd slack-glass
git pull
scripts/build-app.sh --install
```

Your tokens and settings are kept.

**Uninstall:** quit Slack Glass, delete it from Applications, and delete `~/Library/Application Support/Slack Glass/`. Then delete your Slack app at [api.slack.com/apps](https://api.slack.com/apps).

## Assistant API

`/assistant` works with any server that implements these endpoints. Every request carries `Authorization: Bearer <token>`.

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

Treat `screen` as untrusted input: it contains other people's messages, which may try to instruct your model.

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

- `Sources/SlackGlass/Slack`: the Web API client (handles rate limits and token refresh), the Socket Mode client (acknowledges events, reconnects with backoff and after sleep), the models, the app manifest, and the assistant client.
- `Sources/SlackGlass/Core`: `AppModel` (all state and Slack actions), the mrkdwn renderer, the emoji table, storage, the global hotkeys, and the demo workspace.
- `Sources/SlackGlass/UI`: the floating panels, glass material, inbox, conversation view, composer, image viewer, bubble, and settings.

The panel is an `NSPanel` with `.nonactivatingPanel`. It floats over full-screen apps and doesn't steal focus from the app you were in.

### What Slack's API can't do

These open in the real Slack app with ⌘O:

- **Huddles and canvases.** Slack has no public API for them.
- **Per-thread read state.** The API can't mark a single thread as read, so Slack's "Threads" view may still show replies you already answered here. Channel and DM read state syncs correctly.
- **Threads you follow.** The API doesn't expose them. Slack Glass watches threads you've posted in, started or been mentioned in, starting from when you install it.

## Contributing

Issues and pull requests are welcome. Run `scripts/build-app.sh --demo` to work against the fake workspace without connecting Slack. Ideas on the list:
- customizable hotkeys
- rich Block Kit rendering
- multiple workspaces
- signed, notarized downloads with automatic updates

## License

[MIT](LICENSE)
