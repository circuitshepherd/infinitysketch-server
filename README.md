# infsketch-server

The local-network sync server for [InfinitySketch](https://apps.apple.com/app/infinitysketch), an
iOS/iPadOS sketching app. Run it on a machine in your home or studio network and your devices keep
their sketches in sync — and AI agents can read, draw into, and rework the same documents through
an [MCP](https://modelcontextprotocol.io) endpoint.

A cross-platform Swift command-line application: **macOS** and **Linux** are tested on every commit;
**Windows** is intended but currently unverified.

## What it does

- **Live sync between devices.** Each device mirrors its open documents to the server over a single
  WebSocket channel; edits settle to the server within seconds and reach every other subscribed
  device. Documents are local-first — every device keeps a full copy, and losing the server never
  loses a sketch.
- **A web overview.** `http://<host>:8080/` lists the server's documents with live-updating
  previews; each document has its own page with a live frame while a device has it open.
- **Scan to join.** At startup the server prints a QR code in the terminal. Scanning it with an
  iPhone/iPad camera opens InfinitySketch and asks — always asks — before pointing the app at this
  server.
- **AI agents over MCP.** `http://<host>:<port>/mcp` exposes the document store to agents: listing,
  rendering (PNG), stroke/text/image/grid authoring and revision, selection control, tagging,
  merging, undo. Operations that need PencilKit (drawing, rendering) are relayed to a connected
  device; everything else the server does itself. Agent edits land live on open canvases.

## Quick start

Requires [Swift 6.0 or newer](https://www.swift.org/install/).

```sh
git clone https://gitlab.com/pepi.woess/infinitysketch-server.git
cd infinitysketch-server
swift run infsketch-server --docs ~/infsketch-docs
```

Then scan the QR code the server prints with your iPad or iPhone camera — the app opens and asks to
join. Or type the address by hand in the app under Settings. The web overview is at
`http://localhost:8080/`.

Flags: `--port N` (default 8080), `--docs DIR` (default `./docs` — created if missing; documents
are stored there as plain `.infsketch` files, deletions go to a `.trash/` folder pruned after 30
days, matching the iOS *Recently Deleted* window).

## App compatibility

The app and the server must speak the same wire-protocol version, and the check is **exact** — a
mismatched pair refuses cleanly at the handshake instead of failing somewhere subtle later.

| InfinitySketch (App Store) | infsketch-server tag | wire protocol |
|---|---|---|
| 2.0 | v1.0.0 | 7 |

Run the tagged release that matches your app version; `main` may be ahead of what the shipped app
speaks.

## Security model — read this before exposing it

The server has **no authentication and no TLS**. Anything that can reach the port has the full
surface: every document's content, every write, and deletion. This is a deliberate design for
**trusted local networks** — the same trust you extend to a shared printer or NAS on your LAN.

Do not port-forward it to the internet or run it on a network with devices you don't trust. The
device channel is plain `ws://`; the join QR carries a plain `http://` URL.

## Connecting an AI agent

The startup banner prints the MCP URL beside the join code. Point any MCP-capable agent (Claude
Code, etc.) at it as a streaming-HTTP server:

```
http://<host>:<port>/mcp
```

Start with the `infsketch://guide` resource — it is listed first and carries the cross-tool
knowledge an agent needs before picking a tool. Each tool documents its own arguments and reply
keys. Reads (listing, rendering, geometry) work with no device connected; authoring strokes,
text styling, and rendering need at least one device connected to the server, because only
PencilKit can produce or rasterize stroke data.

## Development

```sh
swift test        # the full suite on the host platform
```

Linux is the honest gate for cross-platform claims — code that compiles on macOS has failed on
Linux here before. The CI image is `swift:6.1` (see `.gitlab-ci.yml`); to run it locally:

```sh
docker run --rm -v "$PWD:/src" -w /src swift:6.1 swift test
```

The macOS suite runs more tests than Linux — the difference is the MCP adapter tests, which need
an SSE client transport that is not available on Linux.

Targets (`Package.swift`):

- **`InfSketchWire`** — the wire protocol and chunked-transfer types. Zero dependencies; this is
  the library the InfinitySketch app links.
- **`InfSketchServerKit`** — the server implementation: WebSocket sessions, document store, web
  UI, MCP adapter, device-command relay.
- **`infsketch-server`** — the CLI entry point.
- **`infsketch-demo`** — a small demo client (macOS) that ticks a document for testing.

`docs/protocol.md` is the map of the wire protocol; `docs/design.md` is the original (2026-07)
project scaffold design, kept as history.

## Dependencies

- [FlyingFox](https://github.com/swhitty/FlyingFox) (MIT) — HTTP + WebSocket server
- [MCP Swift SDK](https://github.com/modelcontextprotocol/swift-sdk) (MIT) — the MCP endpoint
- [swift-crypto](https://github.com/apple/swift-crypto) (Apache-2.0) — SHA-256 for write guards
- [swift-qrcode-generator](https://github.com/fwcd/swift-qrcode-generator) (MIT) — the terminal
  join code

`InfSketchWire` itself depends on nothing.

## License

Licensed under the Apache License, Version 2.0. See [`LICENSE`](LICENSE) and [`NOTICE`](NOTICE).
