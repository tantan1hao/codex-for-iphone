import crypto from "node:crypto";
import http from "node:http";
import { WebSocketServer, WebSocket } from "ws";

const port = Number.parseInt(process.env.PORT || "8787", 10);
const path = process.env.RELAY_PATH || "/codex-mobile";
const remoteControlEnrollPath = "/backend-api/wham/remote/control/server/enroll";
const remoteControlServerPath = "/backend-api/wham/remote/control/server";
const rooms = new Map();
const remoteEnrollmentsByServerID = new Map();

const server = http.createServer(async (req, res) => {
  const url = new URL(req.url || "/", `http://${req.headers.host || "localhost"}`);
  if (url.pathname === "/readyz") {
    res.writeHead(200, { "content-type": "text/plain" });
    res.end("ok\n");
    return;
  }
  if (req.method === "POST" && url.pathname === remoteControlEnrollPath) {
    await handleRemoteControlEnroll(req, res);
    return;
  }
  res.writeHead(404);
  res.end("not found\n");
});

const rawRelayWSS = new WebSocketServer({ noServer: true });
const remoteControlServerWSS = new WebSocketServer({ noServer: true });

server.on("upgrade", (req, socket, head) => {
  const url = new URL(req.url || "/", `http://${req.headers.host || "localhost"}`);
  if (url.pathname === path) {
    rawRelayWSS.handleUpgrade(req, socket, head, (ws) => rawRelayWSS.emit("connection", ws, req));
    return;
  }
  if (url.pathname === remoteControlServerPath) {
    remoteControlServerWSS.handleUpgrade(req, socket, head, (ws) => {
      remoteControlServerWSS.emit("connection", ws, req);
    });
    return;
  }
  socket.destroy();
});

rawRelayWSS.on("connection", (socket, request) => {
  socket.once("message", (data, isBinary) => {
    if (isBinary) {
      reject(socket, "first message must be register JSON");
      return;
    }
    let registration;
    try {
      registration = JSON.parse(data.toString("utf8"));
    } catch {
      reject(socket, "first message must be register JSON");
      return;
    }

    const validationError = validateRegistration(registration);
    if (validationError) {
      reject(socket, validationError);
      return;
    }

    const remoteControl = registration.capabilities?.includes("remote_control_v2")
      || registration.metadata?.mode === "remote_control";

    socket.context = {
      mode: remoteControl ? "remote_control" : "raw_jsonrpc",
      role: registration.role,
      room: registration.room,
      token: registration.token,
      name: registration.name,
      peer: null,
      pending: [],
    };

    socket.send(JSON.stringify({ type: "register_ack", ok: true }));
    attachToRoom(socket);
    socket.on("message", (payload, binary) => forwardOrHandleControl(socket, payload, binary));
  });
});

remoteControlServerWSS.on("connection", (socket, request) => {
  const serverID = String(request.headers["x-codex-server-id"] || "");
  const enrollment = remoteEnrollmentsByServerID.get(serverID);
  if (!enrollment) {
    socket.close(1008, "unknown remote control server");
    return;
  }

  socket.context = {
    mode: "remote_control",
    role: "mac",
    room: enrollment.environmentID,
    token: enrollment.serverID,
    name: decodeCodexName(request.headers["x-codex-name"]) || enrollment.name,
    peer: null,
    pending: [],
  };

  attachToRoom(socket);
  socket.on("message", (payload, binary) => forwardOrHandleControl(socket, payload, binary));
  console.log(`remote_control server connected: environment=${enrollment.environmentID} name=${socket.context.name}`);
});

setInterval(() => {
  for (const client of rawRelayWSS.clients) {
    if (client.readyState === WebSocket.OPEN && client.context?.mode !== "remote_control") {
      client.send(JSON.stringify({ type: "ping" }));
    }
  }
}, 30_000).unref();

server.listen(port, () => {
  console.log(`codex-mobile relay listening on ws://0.0.0.0:${port}${path}`);
  console.log(`remote_control enroll endpoint listening on http://0.0.0.0:${port}${remoteControlEnrollPath}`);
  console.log(`remote_control server websocket listening on ws://0.0.0.0:${port}${remoteControlServerPath}`);
});

async function handleRemoteControlEnroll(req, res) {
  try {
    const body = await readJSONBody(req);
    const serverID = crypto.randomUUID();
    const environmentID = crypto.randomUUID();
    const name = sanitizeName(body?.name || "Codex");
    const enrollment = { serverID, environmentID, name };
    remoteEnrollmentsByServerID.set(serverID, enrollment);

    const publicRelay = process.env.PUBLIC_RELAY_WS || `ws://<relay-host>:${port}${path}`;
    const pairingURL = new URL("codex-mobile://pair");
    pairingURL.searchParams.set("v", "1");
    pairingURL.searchParams.set("name", name);
    pairingURL.searchParams.set("host", "remote");
    pairingURL.searchParams.set("port", "443");
    pairingURL.searchParams.set("token", serverID);
    pairingURL.searchParams.set("cwd", "/");
    pairingURL.searchParams.set("mode", "remote-control");
    pairingURL.searchParams.set("relay", publicRelay);
    pairingURL.searchParams.set("room", environmentID);

    console.log(`remote_control enrolled: environment=${environmentID} name=${name}`);
    console.log(`pairing link: ${pairingURL.toString()}`);

    res.writeHead(200, { "content-type": "application/json" });
    res.end(JSON.stringify({ server_id: serverID, environment_id: environmentID }));
  } catch (error) {
    res.writeHead(400, { "content-type": "application/json" });
    res.end(JSON.stringify({ error: error.message || "invalid enroll request" }));
  }
}

function validateRegistration(message) {
  if (message?.type !== "register") return "first message must be register";
  if (message.platform !== "codex_mobile") return "platform must be codex_mobile";
  if (message.role !== "phone" && message.role !== "mac") return "role must be phone or mac";
  if (!message.room || !/^[A-Za-z0-9_-]{8,}$/.test(message.room)) return "room is invalid";
  if (!message.token || String(message.token).length < 32) return "token is invalid";
  return null;
}

function attachToRoom(socket) {
  const { room, role, token } = socket.context;
  const entry = rooms.get(room) || {};
  const otherRole = role === "phone" ? "mac" : "phone";
  const peer = entry[otherRole];

  if (peer?.readyState === WebSocket.OPEN && peer.context.token !== token) {
    reject(socket, "token mismatch");
    return;
  }

  closeIfOpen(entry[role]);
  entry[role] = socket;
  rooms.set(room, entry);

  if (peer?.readyState === WebSocket.OPEN) {
    socket.context.peer = peer;
    peer.context.peer = socket;
    flushPending(socket);
    flushPending(peer);
  }

  socket.on("close", () => detachFromRoom(socket));
  socket.on("error", () => detachFromRoom(socket));
}

function detachFromRoom(socket) {
  const context = socket.context;
  if (!context) return;
  const entry = rooms.get(context.room);
  if (!entry) return;
  if (entry[context.role] === socket) {
    delete entry[context.role];
  }
  if (context.peer?.context?.peer === socket) {
    context.peer.context.peer = null;
  }
  if (!entry.phone && !entry.mac) {
    rooms.delete(context.room);
  }
}

function forwardOrHandleControl(socket, payload, binary) {
  if (socket.context?.mode !== "remote_control" && !binary) {
    const text = payload.toString("utf8");
    if (handleControl(socket, text)) return;
  }

  const peer = socket.context?.peer;
  if (!peer || peer.readyState !== WebSocket.OPEN) {
    queueUntilPeer(socket, payload, binary);
    return;
  }
  peer.send(payload, { binary });
}

function queueUntilPeer(socket, payload, binary) {
  const pending = socket.context?.pending;
  if (!pending) return;
  if (pending.length >= 64) {
    socket.send(JSON.stringify({ type: "relay_error", error: "peer not connected" }));
    return;
  }
  pending.push({ payload: Buffer.from(payload), binary });
}

function flushPending(socket) {
  const peer = socket.context?.peer;
  const pending = socket.context?.pending;
  if (!peer || peer.readyState !== WebSocket.OPEN || !pending?.length) return;
  while (pending.length > 0) {
    const item = pending.shift();
    peer.send(item.payload, { binary: item.binary });
  }
}

function handleControl(socket, text) {
  try {
    const message = JSON.parse(text);
    if (message.type === "ping") {
      socket.send(JSON.stringify({ type: "pong" }));
      return true;
    }
    if (message.type === "pong") {
      return true;
    }
  } catch {
    return false;
  }
  return false;
}

function reject(socket, error) {
  socket.send(JSON.stringify({ type: "register_ack", ok: false, error }));
  socket.close(1008, error);
}

function closeIfOpen(socket) {
  if (socket?.readyState === WebSocket.OPEN) {
    socket.close(1000, "replaced");
  }
}

async function readJSONBody(req) {
  const chunks = [];
  for await (const chunk of req) {
    chunks.push(chunk);
  }
  const raw = Buffer.concat(chunks).toString("utf8");
  return raw.length ? JSON.parse(raw) : {};
}

function sanitizeName(value) {
  return String(value).trim().slice(0, 120) || "Codex";
}

function decodeCodexName(value) {
  if (!value) return null;
  try {
    return Buffer.from(String(value), "base64").toString("utf8");
  } catch {
    return null;
  }
}
