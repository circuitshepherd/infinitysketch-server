# infsketch-server

Cross-platform server backend for **InfinitySketch** — a Swift command-line application
intended to run on macOS, Linux, and Windows.

> **Status: early scaffold.** This repository currently contains only an empty, buildable
> skeleton — no server functionality yet. The server's role (REST API, real-time sync,
> document storage, …) is deliberately undecided. See [`docs/design.md`](docs/design.md)
> for the setup rationale and roadmap.

## Requirements

- Swift 6.0 or newer — <https://www.swift.org/install/>

## Build & run

```sh
swift build                    # compile
swift run infsketch-server     # run the placeholder executable
```

## Platforms

The code is plain Swift + Foundation with no Apple-only APIs, so it is designed to compile
and run on **macOS, Linux, and Windows**. Automated cross-platform CI is intentionally not
set up yet (see `docs/design.md`); until then, cross-platform builds are verified locally.

## License

Licensed under the Apache License, Version 2.0. See [`LICENSE`](LICENSE) and [`NOTICE`](NOTICE).
