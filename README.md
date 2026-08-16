# infsketch-server

The local-network sync server for [InfinitySketch](https://apps.apple.com/app/infinitysketch), an
iOS/iPadOS sketching app. Run it on a machine in your home or studio network and your devices keep
their sketches in sync — and AI agents can read, draw into, and rework the same documents through
an [MCP](https://modelcontextprotocol.io) endpoint.

A cross-platform Swift command-line application: **macOS** and **Linux** are tested on every commit,
and **Windows** builds and passes the full suite natively (verified 2026-08-09 on Windows 11 with
Swift 6.3.3). Windows users do not need a toolchain at all — there is a
[ready-to-run download](#windows).

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
git clone https://github.com/circuitshepherd/infinitysketch-server.git
cd infinitysketch-server
swift run infsketch-server --docs ~/infsketch-docs
```

Then scan the QR code the server prints with your iPad or iPhone camera — the app opens and asks to
join. Or type the address by hand in the app under Settings. The web overview is at
`http://localhost:8080/`.

Flags: `--port N` (default 8080), `--docs DIR` (default `./docs` — created if missing; documents
are stored there as plain `.infsketch` files, deletions go to a `.trash/` folder pruned after 30
days, matching the iOS *Recently Deleted* window), `--no-open` (do not open a browser at startup).

### Windows

**Don't build it — download it.** Grab the `infsketch-server-<version>-windows-x86_64.zip` from
[Releases](https://github.com/circuitshepherd/infinitysketch-server/releases), unzip, and run
`infsketch-server.exe`. No Swift, no Visual Studio, no Developer Mode, nothing to install: the
Swift runtime ships in the folder beside the executable. Keep the `.dll` files next to the `.exe`.

Two things to expect the first time. SmartScreen warns about an unsigned executable — *More info*
→ *Run anyway*. And the QR code needs a terminal that renders ANSI colour; Windows Terminal does,
and the server turns on virtual-terminal processing itself so the classic console works too (if
you see escape sequences as literal text, the code on screen will not scan).

If it cannot start — port 8080 already taken is the usual reason — the window **stays open** and
says so, rather than flashing and closing with the error unread.

#### Building from source on Windows

Only needed if you are developing the server. Install
[Swift for Windows](https://www.swift.org/install/windows/) (`winget install Swift.Toolchain`) and
Visual Studio 2022 with the *Desktop development with C++* workload — Swift links through MSVC's
`link.exe`. A plain PowerShell is fine: Swift locates the linker itself, and the *x64 Native Tools*
prompt is **not** required (an earlier version of this file said it was; measured false on 6.3.3,
where a from-scratch build succeeds with `link.exe` absent from `PATH`).

**Turn on Developer Mode first** (Settings → System → For developers). Without it the dependency
checkout fails outright with *"unable to create symlink … Permission denied"* — two dependencies
(swift-nio, swift-async-algorithms) contain symlinks, and Windows refuses to create those
unprivileged. Note that a machine-wide `core.symlinks = false` does **not** protect you: SwiftPM
force-writes `core.symlinks = true` into every dependency checkout, overriding it. If you cannot
enable Developer Mode, override it for the session instead — environment config outranks repo
config:

```pwsh
$env:GIT_CONFIG_COUNT = 1
$env:GIT_CONFIG_KEY_0 = "core.symlinks"
$env:GIT_CONFIG_VALUE_0 = "false"
```

```pwsh
git clone https://github.com/circuitshepherd/infinitysketch-server.git
cd infinitysketch-server
swift run infsketch-server --docs $env:USERPROFILE\infsketch-docs
```

Two more Windows notes: **`~` is not expanded by PowerShell**, so `--docs ~/infsketch-docs` creates
a directory literally named `~` — use `$env:USERPROFILE\...` as above; and without Developer Mode
SwiftPM cannot create its `.build\debug` shortcut, so built binaries are under
`.build\x86_64-unknown-windows-msvc\debug\` instead.

## App compatibility

The app and the server must speak the same wire-protocol version, and the check is **exact** — a
mismatched pair refuses cleanly at the handshake instead of failing somewhere subtle later.

| InfinitySketch (App Store) | infsketch-server tag | wire protocol |
|---|---|---|
| 2.1 | v1.0.0 | 11 |

Run the tagged release that matches your app version; `main` may be ahead of what the shipped app
speaks. Syncing with a server arrived in InfinitySketch 2.1 — earlier versions have no server
feature at all, so there is nothing for this to pair with.

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

**[`docs/mcp-tools.md`](docs/mcp-tools.md) is the full tool reference** — every argument, its
type and its description, grouped by what they act on. It is generated from the same definitions
`tools/list` serves, so it cannot drift from the server; `swift test` fails if it does. Regenerate
after changing a tool:

```sh
INFSKETCH_REGENERATE_DOCS=1 swift test --filter ToolReferenceTests
```

## Development

```sh
swift test        # the full suite on the host platform
```

Linux is the honest gate for cross-platform claims — code that compiles on macOS has failed on
Linux here before. The CI image is `swift:6.1` (see `.gitlab-ci.yml`); to run it locally:

```sh
docker run --rm -v "$PWD:/src" -w /src swift:6.1 swift test
```

The macOS suite runs more tests than Linux and Windows — the difference is the MCP adapter tests,
which drive a real client over real HTTP and so need an SSE client transport. The SDK compiles that
in only on Apple platforms, so the gate is the `MCP_SSE_CLIENT` flag defined in `Package.swift`
beside the dependency that causes it. It is written as a POSITIVE list of the platforms that HAVE
the capability, because it used to say `!os(Linux)` — naming the one platform then known to lack it
— and Windows silently fell on the wrong side of that.

This repository is developed on a private GitLab repository and published here on GitHub; the two
CI configurations split along that line, and each is inert on the other host. `.gitlab-ci.yml` runs
the Linux gate; `.github/workflows/windows.yml` builds and tests on Windows, builds the
self-contained release package on **every push** (uploaded as a build artifact), and attaches it to
the GitHub Release for a `v*` tag.

To build the package by hand:

```pwsh
.\scripts\package-windows.ps1              # version from `git describe`
.\scripts\package-windows.ps1 -Version 1.0.0
```

It writes `dist/infsketch-server-<version>-windows-x86_64{,.zip}` (~32 MB zipped) and then
**launches the packaged executable with `PATH` stripped to the system directories**. That
verification is the point of the script rather than a nicety: the build machine has Swift
installed, so an incomplete package finds the runtime through `PATH` and works perfectly there
while failing on every user's machine. It is also why the script copies *every* DLL from the
redistributable runtime instead of the ones the executable imports — `_FoundationICU.dll` is loaded
transitively and appears in no import table, and a package built from the import table alone dies
at startup.

The single-executable alternative is not available: `--static-swift-stdlib` is accepted and
silently ignored on Windows, `-Xswiftc -static-stdlib` fails with *"unable to load standard
library"*, and the static runtime that does ship (in `WindowsExperimental.sdk`) cannot be reached
from SwiftPM — pointing `SDKROOT` at it breaks manifest compilation. Revisit when swift.org
publishes a Windows static Swift SDK as it already does for Linux and WebAssembly.

Targets (`Package.swift`):

- **`InfSketchWire`** — the wire protocol and chunked-transfer types. Zero dependencies; this is
  the library the InfinitySketch app links.
- **`InfSketchServerKit`** — the server implementation: WebSocket sessions, document store, web
  UI, MCP adapter, device-command relay.
- **`infsketch-server`** — the CLI entry point.
- **`infsketch-demo`** — a small demo client (macOS) that ticks a document for testing.

`docs/protocol.md` is the map of the wire protocol; `docs/design.md` is the original (2026-07)
project scaffold design, kept as history.

### Consumed as a submodule

The InfinitySketch app repository vendors this repository as a git submodule at `server/`, and links
**`InfSketchWire` as a local package reference** — not as a versioned dependency. The two are
developed as pairs: an app worktree on branch `X` alongside this repository on branch `X`, so a
change spanning both sides is one coherent pair of commits.

Two consequences worth knowing before you push:

- **This repository's `main` must be pushed *before* the app pushes the gitlink that names it.**
  A gitlink pointing at a commit that never left one machine leaves every fresh clone of the app
  unable to fetch it, and because `InfSketchWire` is a local package reference the app then does not
  build at all. The app repository enforces the ordering with a `pre-push` hook, because plain
  `git push` reports success in exactly this case.
- **The wire-protocol check is exact equality**, so app and server deploy together. After merging
  either side, rebuild both before concluding that sync is broken — a stale binary on either end
  refuses the handshake and simply looks offline.

## Dependencies

- [FlyingFox](https://github.com/swhitty/FlyingFox) (MIT) — HTTP + WebSocket server
- [MCP Swift SDK](https://github.com/modelcontextprotocol/swift-sdk) (MIT) — the MCP endpoint.
  **Temporarily pinned to a [fork](https://github.com/circuitshepherd/swift-sdk) — upstream 0.12.1
  plus one commit** that lets the MCP module compile on Windows: upstream guards `import
  EventSource` with `#if !os(Linux)` while its manifest links EventSource on Apple platforms only,
  so on Windows the guard is true and the module is absent. The fix expresses the condition as
  `canImport(EventSource)`; see `docs/swift-sdk-windows-eventsource.patch`. The pin is dropped once
  an upstream release carries it.
- [swift-crypto](https://github.com/apple/swift-crypto) (Apache-2.0) — SHA-256 for write guards
- [swift-qrcode-generator](https://github.com/fwcd/swift-qrcode-generator) (MIT) — the terminal
  join code

`InfSketchWire` itself depends on nothing.

## License

Licensed under the Apache License, Version 2.0. See [`LICENSE`](LICENSE) and [`NOTICE`](NOTICE).
