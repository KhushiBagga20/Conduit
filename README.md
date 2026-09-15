# Conduit

**Your Android, connected to your Mac.**

Conduit links an Android phone to a Mac the way Continuity links Apple
devices: see and control the phone's screen, use it as a trackpad or a
camera, send links and clipboard both ways, and handle calls — from an
Android app, a menu bar utility and a full Mac workspace that all share one
connection.

> **Status: early development.** Conduit for Mac is built on a mirroring
> client — video, input, clipboard and audio — that was physically tested
> before Conduit existed; verifying it on a phone through Conduit's new
> connection owner is the last Phase 1 step. Pairing with Conduit for Android,
> link sharing, calls and the trackpad are planned. See the
> [roadmap](Documentation/Roadmap.md).

## One product, three interfaces

| | |
|---|---|
| **Conduit for Android** | Pairing, connection status, phone-side features and permissions |
| **Conduit menu bar** | Status, quick actions and notifications — always available |
| **Conduit workspace** | The full Mac app: phone screen, trackpad, camera, calls, links, clipboard |

One phone, one connection, one shared device state. Closing the workspace
never disconnects the phone.

## Repository

```
Conduit/
├── Android/            Conduit for Android (Kotlin, Jetpack Compose)
├── Mac/                Conduit for Mac: menu bar + workspace (SwiftUI)
├── Shared/
│   ├── ConduitKit/     Swift package shared by the Mac interfaces
│   ├── Protocol/       Protocol specification and cross-platform test vectors
│   └── Design/         Design tokens for all three interfaces
├── CameraExtension/    Planned system camera extension
├── Documentation/      Architecture, roadmap, security, permissions
└── Scripts/            Development checks
```

Read [Documentation/Architecture.md](Documentation/Architecture.md) first, then
[Documentation/Development.md](Documentation/Development.md) to build and run.

## Requirements

| | |
|---|---|
| Mac | macOS 15.0 or later, Xcode 26 |
| Phone | Android 12 or later |
| Tools | `adb` (`brew install android-platform-tools`), JDK 17 for Android builds |

## Contributing

Run `Scripts/preflight.sh` before every commit. It shows the status and diff
summary and refuses secret-shaped content, signing assets and local paths.

## Credits

Screen mirroring is built on [scrcpy](https://github.com/Genymobile/scrcpy)
by Genymobile. Conduit redistributes the unmodified scrcpy server and
implements its own native Mac client for scrcpy's protocol.

## License

Apache License 2.0 — see [LICENSE](LICENSE) and [NOTICE](NOTICE).
