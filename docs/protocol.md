# The wire protocol — a map

The source is the contract: every message and its exact JSON shape lives in
`Sources/InfSketchWire/WireProtocol.swift` (`ClientMessage` / `ServerMessage`), and the tests pin
the behaviour. This file is the map — what the pieces are and why they exist, so you can find the
right source file without reverse-engineering the design.

## Transport

One WebSocket per client, at `GET /ws`. Messages are JSON text frames. Bulk byte fields (document
snapshots, op payloads, PNG frames) above an inline threshold travel as **chunked binary frames**
instead: the JSON message carries a `TransferDescriptor` announcing a transfer id, the bytes follow
as binary chunks, and `transferEnd` / `transferAbort` close it. Session-layer code never sees a
transfer — the WS adapter reassembles before messages reach `SessionManager`. Sender/reassembler
live in `InfSketchWire` (`TransferSender`, `TransferReassembler`); both directions use them.

## Handshake and versioning

The first message must be `hello(protocolVersion, capabilities, deviceId)`; the server answers
`helloAck` or refuses. **Nothing else may be sent before `helloAck`** — a request sent early draws
`error(helloRequired)` and costs the connection.

The version check is **exact equality** (`WireProtocol.version`, currently 7), and that is
deliberate: both decoders throw on an unknown message `type` rather than ignoring it, so an older
peer does not degrade gracefully — it would die on the first message it cannot decode, arbitrarily
long after connecting, with no diagnosable cause. Refusing at the handshake converts that into a
clean, immediate error. Consequently **every wire addition bumps the version**, however small.

`capabilities` declares what the client can do for the server — device-relayed ops (`render`,
`createDoc`, `authorStrokes`, `authorText`, `authorImage`, `authorGrids`, `mergeDocs`,
`copyElements`, `reorderElements`, `transformElements`, `controlSelection`, `provideContent`) and
transport features (`blobOmission`).

## Document sessions

- `subscribe(docId, fromSeq, createIfMissing)` → `subscribed(docId, seq, snapshot)` or
  `subscribeFailed`. The snapshot is the full document; there is no history replay.
- Writes are `op(docId, opId, payload, expectation)`. An accepted op is broadcast to every
  subscriber as `event` with a per-session increasing `seq`; the writer's own op comes back as its
  ack. A refused op is `reject(docId, opId, reason, seq)`.
- `expectation` is a compare-and-swap guard (`WriteExpectation`): `matchBytes` (the exact bytes the
  writer read), `matchHash` (SHA-256 of them — what the app's settle push uses), `absent` (creation:
  the doc must not exist), or `none`. Enforced in `DocumentSession.submit`; a stale write is
  rejected instead of clobbering newer content. Retry-after-refetch is the contract.
- `deleteDoc` removes the document (no expectation — the user asked for it gone); live subscribers
  are told via `docDeleted` so a device holding a copy stops syncing it rather than silently
  re-uploading it. Deleted files go to the store's `.trash/`, pruned after 30 days.

## Blob omission (why pushes are small)

Image blobs dominate document size and never change, so documents in flight are stripped against
bytes the receiver already holds: `StrippedDocument` (binary, in `InfSketchWire`) cuts the encoded
document into byte runs and blob references, and the receiver splices its own copy's bytes back.
The rebuild is **digest-verified** — the sender names what the result must hash to, and a mismatch
falls back to a whole-document resend, never a wrong document. All four directions use it
(device→server push, server→device broadcast and relay requests, device→server relay replies),
gated on the `blobOmission` hello capability per peer.

## Device-relayed operations

Only PencilKit can author or rasterize stroke data, so the server relays such work to a connected
device that advertised the capability: `strokeOpRequest(requestId, docId, payload, spec)` carries
the current document bytes plus an op-spec JSON; the device computes and answers `strokeOpReply`
(and `createDocRequest`/`createDocReply` for new documents, which need the app's template). Replies
are pure functions on the bytes — the document need not be open on the device and nothing touches
its disk. The broker (`DeviceCommandBroker`) enforces per-kind timeouts.

## Discovery, status, and live frames

- `listDocs` → `docList` — the store's documents with size, modified date, seq, subscriber count.
- `advertiseDocs` — a device announces documents it holds locally (metadata + thumbnail, no
  content), kept in an in-memory index so other devices can browse and fetch them on demand; pruned
  when the advertising device disconnects.
- `subscribeStatus` → `statusEvent` pushes (doc updated / deleted / subscriber changes) — what the
  web overview and the app's browser refresh from.
- `watchDoc` / `unwatchDoc` — a browser viewing a document's page makes the device render live
  frames (`frame`, ephemeral PNG, no seq, no persistence); `watchers` tells the device someone is
  looking, `frameAvailable` tells watchers a new frame exists.

## Keepalive and backpressure

The WebSocket layer offers no write-completion signal and no reachable ping/pong, so liveness is an
app-level message: the server sends `ping` when a connection has been sent more than a byte budget
since its last inbound message, or has been idle too long; **any** inbound message clears it, and
`pong` exists so a passive receiver can answer. A peer that stops reading is disconnected rather
than buffered without bound. See `ConnectionHealth`.

## HTTP surface

| Route | What |
|---|---|
| `GET /` | Web overview — document list with live-updating previews |
| `GET /doc/<id>` | Per-document page with a live frame while a device has it open |
| `GET /api/docs` | JSON document listing |
| `GET /api/docs/<id>/frame` | Preview PNG — latest live frame, else the stored thumbnail |
| `GET /join` | Scan-to-join landing page; hands the address to the app via a custom URL scheme |
| `GET /ws` | The device WebSocket channel |
| `/mcp` | The MCP endpoint for agents (streaming HTTP + SSE) |

## MCP

`MCP/` in `InfSketchServerKit` mounts the official [MCP Swift
SDK](https://github.com/modelcontextprotocol/swift-sdk). Tools flow through the same session/op
path as device pushes — same CAS guards, same broadcast — so agent edits reach open documents live.
The `infsketch://guide` resource (listed first) carries the cross-tool knowledge; every tool's
`description` documents its arguments and reply keys, and unknown arguments are rejected by name.
