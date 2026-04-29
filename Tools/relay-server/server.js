import http from "node:http";
import { WebSocketServer, WebSocket } from "ws";

const port = Number.parseInt(process.env.PORT || "8787", 10);
const path = process.env.RELAY_PATH || "/codex-mobile";
const rooms = new Map();

const server = http.createServer((req, res) => {
  if (req.url === "/readyz") {
    res.writeHead(200, { "content-type": "text/plain" });
    res.end("ok\n");
    return;
  }
  res.writeHead(404);
  res.end("not found\n");
});

const wss = new WebSocketServer({ server, path });

wss.on("connection", (socket, request) => {
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

    socket.context = {
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

setInterval(() => {
  for (const client of wss.clients) {
    if (client.readyState === WebSocket.OPEN) {
      client.send(JSON.stringify({ type: "ping" }));
    }
  }
}, 30_000).unref();

server.listen(port, () => {
  console.log(`codex-mobile relay listening on ws://0.0.0.0:${port}${path}`);
});

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
  if (!binary) {
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
