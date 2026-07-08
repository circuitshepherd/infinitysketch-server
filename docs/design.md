# infsketch-server — project scaffold design

**Date:** 2026-07-08
**Status:** implemented (initial scaffold)

## Purpose

`infsketch-server` is the future server backend for the InfinitySketch iOS/iPadOS app.
It is a Swift command-line application designed to run cross-platform (macOS, Linux,
Windows), and is intended to be **open-sourced** in the future.

At this stage the server's role is deliberately **undecided** (REST API, real-time sync,
blob storage, …). This repository contains only an empty, buildable skeleton so that the
project, its license, and its Git history exist cleanly from day one.

## Key decisions

- **Separate repository from the app.** The InfinitySketch app is proprietary and lives in
  a private repo. This server is destined for open source. Drawing the public/private
  boundary as a *repository* boundary from the first commit avoids ever having to extract
  code out of the app's private history later (and auditing that history for secrets).
- **License: Apache-2.0**, present from the first commit — permissive with an explicit
  patent grant.
- **Visibility: private now, public later.** Developed clean; flip to public when ready.
- **No application-specific code yet.** No `.infsketch` wire types, no networking, no HTTP
  framework. Extracting the shared wire-format types from the app's `InfinitySketchShared`
  into a portable `SketchWireFormat` package is a separate, larger task for its own session.
- **No CI yet (YAGNI).** CI's value here is verifying Linux/Windows builds that can't be
  checked on the macOS dev machine — but the current placeholder compiles trivially
  everywhere. CI will be added in one commit the moment real, platform-sensitive code or a
  dependency lands.
- **Windows support** rules out Vapor (no Windows support). When a networking layer is
  chosen, Hummingbird / SwiftNIO or a thinner stack are the cross-platform-viable options.

## Layout

```
infinitysketch-server/
├── Package.swift                 # executable package, swift-tools 6.0
├── Sources/infsketch-server/
│   └── main.swift                # placeholder entry point
├── LICENSE                       # Apache-2.0
├── NOTICE                        # attribution
├── README.md
├── .gitignore                    # Swift/SPM
└── docs/design.md                # this file
```

## Next steps (future sessions, each its own brainstorm)

1. Decide the server's role/protocol.
2. Extract `SketchWireFormat` (the portable `.infsketch` Codable types) from
   `InfinitySketchShared`, consumed by both the app and this server.
3. Choose a networking stack (Hummingbird / NIO), given the Windows constraint.
4. Add CI (Linux via GitLab shared runners; macOS/Windows via GitHub Actions or paid
   runners) when there is real code to guard.
