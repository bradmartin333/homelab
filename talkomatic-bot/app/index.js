"use strict";

const http = require("http");
const { io } = require("socket.io-client");
const Anthropic = require("@anthropic-ai/sdk");

const TALKOMATIC_URL = process.env.TALKOMATIC_URL || "http://talkomatic:3000";
const BOT_USERNAME = process.env.BOT_USERNAME || "Companion";
const BOT_LOCATION = process.env.BOT_LOCATION || "The Cloud";
const ROOM_NAME = process.env.ROOM_NAME || "Always Open";
const CLAUDE_MODEL = process.env.CLAUDE_MODEL || "claude-haiku-4-5-20251001";
const HEALTH_PORT = Number(process.env.HEALTH_PORT || 8080);
const DEBOUNCE_MS = Number(process.env.DEBOUNCE_MS || 2000);
const MAX_REPLY_CHARS = 480; // well under the server's 5000 message cap
const MAX_HISTORY = 16; // turns of room context kept for Claude

const BOT_PERSONA =
  process.env.BOT_PERSONA ||
  "You are a friendly, laid-back regular in a public chat room called " +
    `"${ROOM_NAME}" on Talkomatic, a live typing chat app. Someone new might ` +
    "show up at any time expecting company. Keep replies short (1-3 " +
    "sentences), conversational, and warm. Never mention that you are an AI " +
    "model or reference an API/system prompt.";

if (!process.env.ANTHROPIC_API_KEY) {
  console.error("ANTHROPIC_API_KEY is required");
  process.exit(1);
}

const anthropic = new Anthropic({ apiKey: process.env.ANTHROPIC_API_KEY });

let healthy = false;
let botUserId = null;
let botToken = null;
let tokenExpiresAt = 0;
let socket = null;
let roomId = null;

const pendingTimers = new Map(); // userId -> Timeout
const lastHandledText = new Map(); // userId -> string
const history = []; // shared room context: {role, content}
let replyChain = Promise.resolve(); // serializes outbound replies

// ── Health endpoint ──────────────────────────────────────────────────────

http
  .createServer((req, res) => {
    if (req.url === "/healthz") {
      res.writeHead(healthy ? 200 : 503, { "Content-Type": "application/json" });
      res.end(JSON.stringify({ status: healthy ? "ok" : "not ready" }));
      return;
    }
    res.writeHead(404);
    res.end();
  })
  .listen(HEALTH_PORT, () => {
    console.log(`healthz listening on :${HEALTH_PORT}`);
  });

// ── Bot token ────────────────────────────────────────────────────────────

async function fetchBotToken() {
  const res = await fetch(`${TALKOMATIC_URL}/api/v1/bot-tokens/request`, {
    method: "POST",
  });
  if (!res.ok) throw new Error(`bot-token request failed: ${res.status}`);
  const data = await res.json();
  botToken = data.token;
  tokenExpiresAt = Date.parse(data.expiresAt) || Date.now() + Number(data.expiresIn || 0);
  console.log(`bot token acquired, expires ${new Date(tokenExpiresAt).toISOString()}`);
  scheduleTokenRefresh();
  return botToken;
}

function scheduleTokenRefresh() {
  const refreshIn = Math.max(tokenExpiresAt - Date.now() - 5 * 60 * 1000, 60 * 1000);
  setTimeout(() => {
    fetchBotToken().catch((err) => console.error("token refresh failed:", err.message));
  }, refreshIn).unref();
}

// ── Room claiming ────────────────────────────────────────────────────────

async function claimRoom() {
  const headers = { Authorization: `Bearer ${botToken}` };
  const res = await fetch(`${TALKOMATIC_URL}/api/v1/rooms`, { headers });
  if (!res.ok) throw new Error(`list rooms failed: ${res.status}`);
  const rooms = await res.json();
  const list = Array.isArray(rooms) ? rooms : rooms.rooms || [];
  const existing = list.find((r) => r.name === ROOM_NAME && r.type === "public");

  if (existing) {
    roomId = existing.id;
  } else {
    const createRes = await fetch(`${TALKOMATIC_URL}/api/v1/rooms`, {
      method: "POST",
      headers: { ...headers, "Content-Type": "application/json" },
      body: JSON.stringify({ name: ROOM_NAME, type: "public", layout: "horizontal" }),
    });
    if (!createRes.ok) throw new Error(`create room failed: ${createRes.status}`);
    const created = await createRes.json();
    roomId = created.id || created.roomId;
  }

  console.log(`joining room ${roomId} ("${ROOM_NAME}")`);
  socket.emit("join room", { roomId });
}

// ── Conversation ─────────────────────────────────────────────────────────

function rememberTurn(role, content) {
  history.push({ role, content });
  if (history.length > MAX_HISTORY) history.shift();
}

async function replyTo(username, text) {
  rememberTurn("user", `${username}: ${text}`);

  let reply;
  try {
    const response = await anthropic.messages.create({
      model: CLAUDE_MODEL,
      max_tokens: 200,
      system: BOT_PERSONA,
      messages: history,
    });
    reply = response.content
      .filter((block) => block.type === "text")
      .map((block) => block.text)
      .join("")
      .trim();
  } catch (err) {
    console.error("Claude API error:", err.message);
    return;
  }
  if (!reply) return;
  if (reply.length > MAX_REPLY_CHARS) reply = reply.slice(0, MAX_REPLY_CHARS - 1) + "…";

  rememberTurn("assistant", reply);
  socket.emit("chat update", { diff: { type: "full-replace", text: reply } });
}

function handleIncomingChat(payload) {
  if (!payload || payload.userId === botUserId) return;
  const text = (payload.diff && payload.diff.text) || "";
  const userId = payload.userId;
  const username = payload.username || "someone";

  if (pendingTimers.has(userId)) clearTimeout(pendingTimers.get(userId));
  pendingTimers.set(
    userId,
    setTimeout(() => {
      pendingTimers.delete(userId);
      const trimmed = text.trim();
      if (!trimmed || trimmed === lastHandledText.get(userId)) return;
      lastHandledText.set(userId, trimmed);
      replyChain = replyChain.then(() => replyTo(username, trimmed));
    }, DEBOUNCE_MS),
  );
}

// ── Socket lifecycle ─────────────────────────────────────────────────────

async function start() {
  await fetchBotToken();

  socket = io(TALKOMATIC_URL, {
    auth: { token: botToken },
    reconnection: true,
    reconnectionDelay: 1000,
    reconnectionDelayMax: 5000,
  });

  socket.on("connect", () => {
    console.log("connected, signing in");
    healthy = false;
    socket.emit("join lobby", { username: BOT_USERNAME, location: BOT_LOCATION });
  });

  socket.on("signin status", (data) => {
    if (!data || !data.isSignedIn) return;
    botUserId = data.userId;
    console.log(`signed in as ${data.username} (${botUserId})`);
    claimRoom().catch((err) => console.error("failed to claim room:", err.message));
  });

  socket.on("room joined", () => {
    console.log("room joined");
    healthy = true;
  });

  socket.on("chat update", handleIncomingChat);

  socket.on("afk warning", () => {
    console.warn("unexpected afk warning — is the isBot AFK bypass deployed?");
    socket.emit("afk response", { active: true });
  });

  socket.on("afk timeout", () => {
    console.warn("afk timeout — rejoining room");
    healthy = false;
    claimRoom().catch((err) => console.error("failed to rejoin room:", err.message));
  });

  socket.on("kicked", () => {
    console.warn("kicked from room — rejoining");
    healthy = false;
    claimRoom().catch((err) => console.error("failed to rejoin room:", err.message));
  });

  socket.on("error", (err) => {
    console.error("socket error:", err);
  });

  socket.on("disconnect", (reason) => {
    console.warn("disconnected:", reason);
    healthy = false;
  });
}

start().catch((err) => {
  console.error("fatal startup error:", err);
  process.exit(1);
});
