# infsketch-server

Cross-platform server backend for **InfinitySketch** — a Swift command-line application
intended to run on macOS, Linux, and Windows.

> **Status: v0 walking skeleton.** The server hosts WebSocket document sessions
> (JSON wire protocol, seq-ordered broadcast), a directory-backed document store,
> a REST listing API with thumbnails, and a live web overview page at `/`.
> Documents of any size sync over the single WebSocket channel: bulk payloads
> above an inline threshold travel as chunked binary messages (see the
> 2026-07-10 WS chunked transfer design in the InfinitySketch app repo).
> Protocol design: the transport spec in the InfinitySketch app repo
> (`docs/superpowers/specs/2026-07-09-server-transport-design.md`).
> Agents connect via MCP at `/mcp` (HTTP + SSE, official swift-sdk): document
> resources incl. live frames, text-annotation and document tools — see the
> 2026-07-11 MCP design in the app repo.
> Not yet here: resume/backlog replay, render delegation, auth
> (v1 runs open — intended for trusted networks only), TLS (use a reverse proxy),
> slow-socket backpressure (a stalled client buffers server-side until keepalive lands).

## Requirements

- Swift 6.0 or newer — <https://www.swift.org/install/>

## Build & run

```sh
swift test                                     # run the test suite
swift run infsketch-server --docs ./docs       # serve; open http://localhost:8080
swift run infsketch-demo --doc <id>            # demo client (macOS): ticks a doc
```

## Platforms

The code is plain Swift + Foundation with no Apple-only APIs, so it is designed to compile
and run on **macOS, Linux, and Windows**. Linux tests run on GitLab CI (`swift:6.1` image).
Windows support is experimental and currently unverified; it will be CI-verified by the GitHub mirror workflow (`.github/workflows/windows.yml`) once a GitHub mirror is set up.

## License

Licensed under the Apache License, Version 2.0. See [`LICENSE`](LICENSE) and [`NOTICE`](NOTICE).
