// Slack Glass team relay.
//
// One Slack app for the whole team sends its events here (Events API). For each event the relay asks Slack which
// teammates can see it, then pushes it to every Mac those people are signed in on. Each person signs in with
// "Sign in with Slack"; the relay keeps their token so any number of Macs can share it.
//
// Nothing is stored except each signed-in person's Slack token, their device sessions (hashed), and the last
// few minutes of their events so a Mac that was asleep can catch up.

import { DurableObject } from "cloudflare:workers";

export interface Env {
  USERS: DurableObjectNamespace<UserHub>;
  SLACK_CLIENT_ID: string;
  SLACK_CLIENT_SECRET: string;
  SLACK_SIGNING_SECRET: string;
  SLACK_APP_TOKEN: string;
  STATE_SECRET: string;
  APP_ZIP_URL: string;
}

// Keep in sync with Sources/SlackGlass/Slack/SlackManifest.swift.
const USER_SCOPES = [
  "channels:history", "channels:read", "channels:write",
  "groups:history", "groups:read", "groups:write",
  "im:history", "im:read", "im:write",
  "mpim:history", "mpim:read", "mpim:write",
  "users:read", "chat:write",
  "reactions:read", "reactions:write",
  "files:read", "files:write",
  "emoji:read", "search:read",
];
const USER_EVENTS = [
  "message.channels", "message.groups", "message.im", "message.mpim",
  "reaction_added", "reaction_removed",
];
// tokens_revoked arrives without subscribing; it signs that person out everywhere.

const BUFFER_SECONDS = 15 * 60;
const BUFFER_MAX = 500;
// Read/snooze marks shared between one person's Macs. Kept longer than events so a Mac that was off for
// days still clears what you already handled elsewhere.
const MARK_SECONDS = 14 * 24 * 3600;
const MARK_MAX = 1000;

export default {
  async fetch(req: Request, env: Env, ctx: ExecutionContext): Promise<Response> {
    const url = new URL(req.url);
    const route = `${req.method} ${url.pathname}`;
    try {
      switch (route) {
        case "GET /": return html(landingPage(url.origin, env));
        case "GET /setup": return html(setupPage(url.origin, env));
        case "GET /manifest.json": return json(manifest(url.origin));
        case "GET /install": return installScript(url.origin, env);
        case "GET /auth/start": return authStart(url, env);
        case "GET /auth/callback": return authCallback(url, env);
        case "POST /slack/events": return slackEvents(req, env, ctx);
        case "GET /v1/me":
        case "GET /v1/ws":
        case "POST /v1/signout":
          return toUserHub(req, url, env);
      }
      return new Response("Not found", { status: 404 });
    } catch (e) {
      console.error(route, e);
      return new Response("Server error", { status: 500 });
    }
  },
};

// MARK: - Sign in with Slack

async function authStart(url: URL, env: Env): Promise<Response> {
  if (!configured(env)) return html(page("Not set up yet", `<p>This team server isn't finished. Open <a href="/setup">/setup</a>.</p>`), 503);
  const a = new URL("https://slack.com/oauth/v2/authorize");
  a.searchParams.set("client_id", env.SLACK_CLIENT_ID);
  a.searchParams.set("user_scope", USER_SCOPES.join(","));
  a.searchParams.set("redirect_uri", `${url.origin}/auth/callback`);
  a.searchParams.set("state", await signState(env));
  return Response.redirect(a.toString(), 302);
}

async function authCallback(url: URL, env: Env): Promise<Response> {
  const fail = (msg: string) => html(page("Sign-in didn't work", `<p>${esc(msg)}</p><p><a href="/auth/start">Try again</a></p>`), 400);
  if (url.searchParams.get("error")) return fail(`Slack said: ${url.searchParams.get("error")}`);
  const code = url.searchParams.get("code");
  if (!code || !(await checkState(url.searchParams.get("state") ?? "", env))) return fail("This sign-in link expired. Start again from Slack Glass.");

  const r = await slackForm("oauth.v2.access", {
    client_id: env.SLACK_CLIENT_ID,
    client_secret: env.SLACK_CLIENT_SECRET,
    code,
    redirect_uri: `${url.origin}/auth/callback`,
  });
  const user = r.authed_user;
  if (!r.ok || !user?.access_token) return fail(`Slack said: ${r.error ?? "no user token"}`);
  const team: string = r.team?.id;

  const session = `${team}.${user.id}.${randomToken()}`;
  await hub(env, team, user.id).signIn(await sha256(session), {
    token: user.access_token,
    user_id: user.id,
    team_id: team,
  });

  const back = new URL("slackglass://signed-in");
  back.searchParams.set("session", session);
  back.searchParams.set("server", url.origin);
  return html(page("Signed in", `
    <p>You're signed in. Switching back to Slack Glass…</p>
    <p><a class="button" href="${esc(back.toString())}">Open Slack Glass</a></p>
    <script>location.href = ${JSON.stringify(back.toString())}</script>`));
}

async function signState(env: Env): Promise<string> {
  const body = `${Date.now()}.${randomToken()}`;
  return `${body}.${await hmacHex(env.STATE_SECRET, body)}`;
}

async function checkState(state: string, env: Env): Promise<boolean> {
  const i = state.lastIndexOf(".");
  if (i < 0) return false;
  const body = state.slice(0, i);
  const t = Number(body.split(".")[0]);
  return Date.now() - t < 10 * 60_000 && safeEqual(state.slice(i + 1), await hmacHex(env.STATE_SECRET, body));
}

// MARK: - Slack events

async function slackEvents(req: Request, env: Env, ctx: ExecutionContext): Promise<Response> {
  const body = await req.text();
  const p = JSON.parse(body);
  // Slack checks the URL while the app is being created, before the signing secret is set here.
  if (p.type === "url_verification" && !env.SLACK_SIGNING_SECRET) return json({ challenge: p.challenge });
  if (!(await verifySlack(req, body, env))) return new Response("Bad signature", { status: 401 });
  if (p.type === "url_verification") return json({ challenge: p.challenge });
  if (p.type === "event_callback") ctx.waitUntil(dispatch(p, env));
  return new Response(null, { status: 200 });
}

async function verifySlack(req: Request, body: string, env: Env): Promise<boolean> {
  const ts = req.headers.get("x-slack-request-timestamp") ?? "";
  const sig = req.headers.get("x-slack-signature") ?? "";
  if (!env.SLACK_SIGNING_SECRET || Math.abs(Date.now() / 1000 - Number(ts)) > 300) return false;
  return safeEqual(sig, `v0=${await hmacHex(env.SLACK_SIGNING_SECRET, `v0:${ts}:${body}`)}`);
}

async function dispatch(p: any, env: Env): Promise<void> {
  const team: string = p.team_id;
  const event = p.event;
  if (event?.type === "tokens_revoked") {
    for (const u of event.tokens?.oauth ?? []) await hub(env, team, u).revoke();
    return;
  }
  if (event?.type === "app_uninstalled") return;
  const users = await recipients(p, env);
  await Promise.all(users.map((u) => hub(env, team, u).deliver(p.event_id, event).catch((e) => console.error("deliver", u, e))));
}

// Slack lists only one of the people an event concerns; this asks for all of them. Cached briefly per
// conversation, since everyone in a channel gets the same answer.
const recipientCache = new Map<string, { at: number; users: string[] }>();

async function recipients(p: any, env: Env): Promise<string[]> {
  const fromPayload: string[] = (p.authorizations ?? []).filter((a: any) => !a.is_bot && a.user_id).map((a: any) => a.user_id);
  const channel: string | undefined = p.event?.channel ?? p.event?.item?.channel;
  const key = channel ? `${p.team_id}:${channel}` : undefined;
  const cached = key ? recipientCache.get(key) : undefined;
  if (cached && Date.now() - cached.at < 60_000) return union(cached.users, fromPayload);
  if (!p.event_context || !env.SLACK_APP_TOKEN) return fromPayload;

  const users: string[] = [];
  let cursor = "";
  for (let page = 0; page < 20; page++) {
    const r = await slackForm("apps.event.authorizations.list", { event_context: p.event_context, cursor, limit: "200" }, env.SLACK_APP_TOKEN);
    if (!r.ok) { console.error("authorizations.list", r.error); return fromPayload; }
    for (const a of r.authorizations ?? []) if (!a.is_bot && a.user_id) users.push(a.user_id);
    cursor = r.response_metadata?.next_cursor ?? "";
    if (!cursor) break;
  }
  if (key) {
    recipientCache.set(key, { at: Date.now(), users });
    if (recipientCache.size > 5000) recipientCache.clear();
  }
  return union(users, fromPayload);
}

// MARK: - Device API (Slack Glass on each Mac)

async function toUserHub(req: Request, url: URL, env: Env): Promise<Response> {
  const session = (req.headers.get("authorization") ?? "").replace(/^Bearer\s+/i, "");
  const [team, user] = session.split(".");
  if (!team || !user) return json({ error: "signed_out" }, 401);
  const stub = hub(env, team, user);
  const sessionHash = await sha256(session);
  switch (url.pathname) {
    case "/v1/me": {
      const me = await stub.me(sessionHash);
      return me ? json(me) : json({ error: "signed_out" }, 401);
    }
    case "/v1/signout":
      await stub.signOut(sessionHash);
      return json({ ok: true });
    default: {
      const r = new Request(`https://hub/ws${url.search}`, req);
      r.headers.set("x-session", sessionHash);
      return stub.fetch(r);
    }
  }
}

type Account = { token: string; user_id: string; team_id: string };
type Buffered = { seq: number; at: number; event_id: string; event: unknown };
/// One Mac handled an Activity item: "read" (opened, done, cleared) up to `ts`, or "snooze" until `until`.
type Mark = { op: "read" | "snooze"; id: string; channel: string; thread_ts: string | null; ts: string; until?: number; item?: unknown; at: number };

export class UserHub extends DurableObject<Env> {
  private async account(): Promise<Account | undefined> { return this.ctx.storage.get<Account>("account"); }
  private async sessions(): Promise<Record<string, number>> { return (await this.ctx.storage.get("sessions")) ?? {}; }

  async signIn(sessionHash: string, account: Account): Promise<void> {
    const s = await this.sessions();
    s[sessionHash] = Date.now();
    await this.ctx.storage.put({ account, sessions: s });
  }

  async me(sessionHash: string): Promise<Account | null> {
    if (!(await this.sessions())[sessionHash]) return null;
    return (await this.account()) ?? null;
  }

  async signOut(sessionHash: string): Promise<void> {
    const s = await this.sessions();
    delete s[sessionHash];
    for (const ws of this.ctx.getWebSockets(sessionHash)) ws.close(4401, "signed_out");
    // Last Mac signed out: forget the token entirely.
    if (Object.keys(s).length === 0) await this.ctx.storage.deleteAll();
    else await this.ctx.storage.put("sessions", s);
  }

  async revoke(): Promise<void> {
    for (const ws of this.ctx.getWebSockets()) ws.close(4401, "signed_out");
    await this.ctx.storage.deleteAll();
  }

  async deliver(eventID: string, event: unknown): Promise<void> {
    if (!(await this.account())) return; // never signed in here
    const buf = (await this.ctx.storage.get<Buffered[]>("buf")) ?? [];
    if (buf.some((b) => b.event_id === eventID)) return; // Slack retry
    const seq = ((await this.ctx.storage.get<number>("seq")) ?? 0) + 1;
    const now = Date.now() / 1000;
    const entry = { seq, at: now, event_id: eventID, event };
    const kept = [...buf, entry].filter((b) => now - b.at < BUFFER_SECONDS).slice(-BUFFER_MAX);
    await this.ctx.storage.put({ buf: kept, seq });
    const msg = JSON.stringify({ type: "event", ...entry });
    for (const ws of this.ctx.getWebSockets()) {
      try { ws.send(msg); } catch {}
    }
  }

  async fetch(req: Request): Promise<Response> {
    if (req.headers.get("upgrade")?.toLowerCase() !== "websocket") return new Response("Expected WebSocket", { status: 426 });
    const sessionHash = req.headers.get("x-session") ?? "";
    if (!(await this.sessions())[sessionHash]) return json({ error: "signed_out" }, 401);

    const pair = new WebSocketPair();
    const [client, server] = [pair[0], pair[1]];
    this.ctx.acceptWebSocket(server, [sessionHash]);

    // Resume: replay whatever this Mac missed since the last event it saw.
    const after = Number(new URL(req.url).searchParams.get("after") ?? 0);
    const seq = (await this.ctx.storage.get<number>("seq")) ?? 0;
    server.send(JSON.stringify({ type: "hello", seq }));
    if (after > 0 && after < seq) {
      const buf = (await this.ctx.storage.get<Buffered[]>("buf")) ?? [];
      for (const b of buf) if (b.seq > after) server.send(JSON.stringify({ type: "event", ...b }));
    }
    // What your other Macs read or snoozed, so this one clears the same items (it may have been off for days).
    server.send(JSON.stringify({ type: "marks", marks: await this.marks() }));
    return new Response(null, { status: 101, webSocket: client });
  }

  async webSocketMessage(ws: WebSocket, message: string | ArrayBuffer): Promise<void> {
    if (message === "ping") { ws.send("pong"); return; }
    if (typeof message !== "string" || message.length > 16_000) return;
    let m: any;
    try { m = JSON.parse(message); } catch { return; }
    if (m?.type !== "mark") return;
    const mark = cleanMark(m.mark);
    if (!mark) return;
    await this.ctx.storage.put(`mark:${mark.id}`, mark);
    const out = JSON.stringify({ type: "marks", marks: [mark] });
    for (const other of this.ctx.getWebSockets()) {
      if (other !== ws) try { other.send(out); } catch {}
    }
    await this.pruneMarks();
  }

  private async marks(): Promise<Mark[]> {
    const now = Date.now() / 1000;
    const all = [...(await this.ctx.storage.list<Mark>({ prefix: "mark:" })).values()];
    return all.filter((m) => now - m.at < MARK_SECONDS).sort((a, b) => a.at - b.at).slice(-MARK_MAX);
  }

  private async pruneMarks(): Promise<void> {
    const now = Date.now() / 1000;
    const all = [...(await this.ctx.storage.list<Mark>({ prefix: "mark:" })).entries()].sort((a, b) => b[1].at - a[1].at);
    const drop = all.filter(([, m], i) => i >= MARK_MAX || now - m.at >= MARK_SECONDS).map(([k]) => k);
    for (let i = 0; i < drop.length; i += 128) await this.ctx.storage.delete(drop.slice(i, i + 128));
  }

  async webSocketClose(ws: WebSocket, code: number): Promise<void> {
    try { ws.close(code === 1005 ? 1000 : code); } catch {}
  }
}

function cleanMark(m: any): Mark | null {
  const str = (v: unknown, max = 64) => (typeof v === "string" && v.length > 0 && v.length <= max ? v : null);
  const channel = str(m?.channel), ts = str(m?.ts);
  const thread = m?.thread_ts == null ? null : str(m.thread_ts);
  if (!channel || !ts || (m?.thread_ts != null && !thread)) return null;
  if (m.op !== "read" && m.op !== "snooze") return null;
  const mark: Mark = { op: m.op, id: `${channel}:${thread ?? ""}`, channel, thread_ts: thread, ts, at: Date.now() / 1000 };
  if (m.op === "snooze") {
    if (typeof m.until !== "number" || !isFinite(m.until)) return null;
    mark.until = m.until;
    if (m.item && typeof m.item === "object" && JSON.stringify(m.item).length < 8_000) mark.item = m.item;
  }
  return mark;
}

function hub(env: Env, team: string, user: string) {
  return env.USERS.get(env.USERS.idFromName(`${team}:${user}`));
}

// MARK: - Pages

function configured(env: Env): boolean {
  return Boolean(env.SLACK_CLIENT_ID && env.SLACK_CLIENT_SECRET && env.SLACK_SIGNING_SECRET && env.SLACK_APP_TOKEN && env.STATE_SECRET);
}

function landingPage(origin: string, env: Env): string {
  if (!configured(env)) return setupPage(origin, env);
  return page("Slack Glass", `
    <p>Answer Slack without opening Slack. To install Slack Glass on your Mac, open <b>Terminal</b> and paste:</p>
    <pre>curl -fsSL ${esc(origin)}/install | bash</pre>
    <p>Then click <b>Sign in with Slack</b>. Do the same on each of your Macs.</p>`);
}

function setupPage(origin: string, env: Env): string {
  const createURL = `https://api.slack.com/apps?new_app=1&manifest_json=${encodeURIComponent(JSON.stringify(manifest(origin)))}`;
  const tick = (ok: unknown) => (ok ? "✅" : "⬜️");
  return page("Set up your team server", `
    <ol>
      <li><a class="button" href="${esc(createURL)}" target="_blank">Create the Slack app ↗</a><br>
        Pick your workspace and click <b>Create</b>. Everything is filled in.</li>
      <li>In the new app's <b>Basic Information</b>, copy the <b>Client ID</b>, <b>Client Secret</b> and <b>Signing Secret</b>.</li>
      <li>On the same page, under <b>App-Level Tokens</b>, click <b>Generate Token and Scopes</b>, add the
        <code>authorizations:read</code> scope and generate. Copy the token (<code>xapp-…</code>).</li>
      <li>Paste them into the setup script in Terminal (it's waiting for them), or run
        <code>npx wrangler secret put NAME</code> for each.</li>
    </ol>
    <p>${tick(env.SLACK_CLIENT_ID)} Client ID · ${tick(env.SLACK_CLIENT_SECRET)} Client Secret ·
       ${tick(env.SLACK_SIGNING_SECRET)} Signing Secret · ${tick(env.SLACK_APP_TOKEN)} App-level token ·
       ${tick(env.STATE_SECRET)} State secret</p>
    <p>When all five are ticked, share this with your team:</p>
    <pre>curl -fsSL ${esc(origin)}/install | bash</pre>`);
}

function manifest(origin: string) {
  return {
    display_information: {
      // Slack shows this name next to every message sent from Slack Glass, so it's kept short.
      name: "SG",
      description: "A glass HUD for reading and replying to Slack without opening Slack.",
      background_color: "#1a1033",
    },
    oauth_config: { redirect_urls: [`${origin}/auth/callback`], scopes: { user: USER_SCOPES } },
    settings: {
      event_subscriptions: { request_url: `${origin}/slack/events`, user_events: USER_EVENTS },
      org_deploy_enabled: false,
      socket_mode_enabled: false,
      token_rotation_enabled: false,
    },
  };
}

function installScript(origin: string, env: Env): Response {
  const script = `#!/bin/bash
# Installs Slack Glass and points it at this team server.
set -euo pipefail
SERVER=${shq(origin)}
ZIP=${shq(env.APP_ZIP_URL)}
APP="/Applications/Slack Glass.app"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

echo "Downloading Slack Glass…"
curl -fsSL "$ZIP" -o "$TMP/app.zip"
ditto -x -k "$TMP/app.zip" "$TMP"

osascript -e 'quit app "Slack Glass"' >/dev/null 2>&1 || true
for _ in 1 2 3 4 5 6 7 8 9 10; do pgrep -xq SlackGlass || break; sleep 0.3; done
pkill -x SlackGlass 2>/dev/null || true

rm -rf "$APP"
ditto "$TMP/Slack Glass.app" "$APP"
xattr -dr com.apple.quarantine "$APP" 2>/dev/null || true
defaults write io.github.joyrider00.slackglass relayURL "$SERVER"
open "$APP"
echo "Slack Glass is installed. Click \\"Sign in with Slack\\" in the window that opened."
`;
  return new Response(script, { headers: { "content-type": "text/x-shellscript; charset=utf-8" } });
}

function page(title: string, body: string): string {
  return `<!doctype html><html lang="en"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1"><title>${esc(title)}</title>
<style>
  :root { color-scheme: light dark; --bg:#f6f5fa; --fg:#1d1b26; --muted:#6b6880; --card:#fff; --accent:#4a3aff; }
  @media (prefers-color-scheme: dark) { :root { --bg:#14121c; --fg:#ece9f5; --muted:#9a96ad; --card:#1e1b29; --accent:#8f84ff; } }
  body { margin:0; background:var(--bg); color:var(--fg); font:16px/1.55 -apple-system, system-ui, sans-serif; }
  main { max-width:620px; margin:48px auto; padding:28px; background:var(--card); border-radius:16px; }
  h1 { margin-top:0; font-size:24px; } li { margin-bottom:12px; }
  pre { padding:12px 14px; border-radius:10px; background:var(--bg); overflow-x:auto; font-size:14px; }
  code { font-size:14px; } a { color:var(--accent); }
  .button { display:inline-block; margin:4px 0; padding:8px 14px; border-radius:9px; background:var(--accent); color:#fff; text-decoration:none; font-weight:600; }
</style></head><body><main><h1>${esc(title)}</h1>${body}</main></body></html>`;
}

// MARK: - Helpers

async function slackForm(method: string, params: Record<string, string>, token?: string): Promise<any> {
  const headers: Record<string, string> = { "content-type": "application/x-www-form-urlencoded" };
  if (token) headers.authorization = `Bearer ${token}`;
  const r = await fetch(`https://slack.com/api/${method}`, { method: "POST", headers, body: new URLSearchParams(params) });
  return r.json();
}

function html(body: string, status = 200): Response {
  return new Response(body, { status, headers: { "content-type": "text/html; charset=utf-8" } });
}

function json(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), { status, headers: { "content-type": "application/json" } });
}

function esc(s: string): string {
  return s.replace(/[&<>"']/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" })[c]!);
}

function shq(s: string): string {
  return `'${s.replace(/'/g, `'\\''`)}'`;
}

function union(a: string[], b: string[]): string[] {
  return [...new Set([...a, ...b])];
}

function randomToken(): string {
  const b = crypto.getRandomValues(new Uint8Array(32));
  return btoa(String.fromCharCode(...b)).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}

async function sha256(s: string): Promise<string> {
  return hex(await crypto.subtle.digest("SHA-256", new TextEncoder().encode(s)));
}

async function hmacHex(secret: string, data: string): Promise<string> {
  const key = await crypto.subtle.importKey("raw", new TextEncoder().encode(secret), { name: "HMAC", hash: "SHA-256" }, false, ["sign"]);
  return hex(await crypto.subtle.sign("HMAC", key, new TextEncoder().encode(data)));
}

function hex(buf: ArrayBuffer): string {
  return [...new Uint8Array(buf)].map((b) => b.toString(16).padStart(2, "0")).join("");
}

function safeEqual(a: string, b: string): boolean {
  if (a.length !== b.length) return false;
  let d = 0;
  for (let i = 0; i < a.length; i++) d |= a.charCodeAt(i) ^ b.charCodeAt(i);
  return d === 0;
}
