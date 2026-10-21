# Conduit

**Your Android, connected to your Mac.**

Conduit links an Android phone to a Mac the way Continuity links Apple
devices: see and control the phone's screen, use it as a trackpad or a
camera, send links and clipboard both ways, and handle calls — from an
Android app, a menu bar utility and a full Mac workspace that all share one
connection.

> **Status: early development.** Conduit for Mac mirrors and controls a
> phone over USB, Wireless debugging or the phone's own hotspot — verified on
> a Galaxy S24 Ultra, including carrying on over Wi-Fi when the cable is
> pulled. Conduit for Android pairs with the Mac over Conduit Link, shares
> links both ways, rings the Mac from the phone, and lets the Mac ask for
> its hotspot over Bluetooth. Conduit for Mac browses the phone's storage and
> moves files and folders both ways over adb — checked byte for byte on the
> phone, at the same speed as adb's own tool — and edits phone files in place,
> writing each save from the Mac app back to the phone.
>
> Built but not yet seen working end to end: phone notifications on the
> Mac (Android has not yet let a sideloaded Conduit read notifications),
> the clipboard both ways without mirroring, and the phone as a trackpad
> (it needs macOS Accessibility permission, and has not moved a pointer in
> anger). Files without developer options, and calls, are next. See the
> [roadmap](Documentation/Roadmap.md) and
> [measurements](Documentation/Measurements.md).

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

## Installing it

A build lives in Xcode's build folder, which macOS clears — Conduit vanishes
on the next restart. To keep it, copy the Release build into Applications
once:

```bash
cp -R ~/Library/Developer/Xcode/DerivedData/Conduit-*/Build/Products/Release/Conduit.app /Applications/
```

Conduit then opens from Spotlight like any app and lives in the menu bar. It
does not open at login yet. macOS privacy grants — Local Network, and
Accessibility for the trackpad — belong to the copy that asked for them, so
grant them again after moving it.

## Contributing

Run `Scripts/preflight.sh` before every commit. It shows the status and diff
summary and refuses secret-shaped content, signing assets and local paths.

## Credits

Screen mirroring is built on [scrcpy](https://github.com/Genymobile/scrcpy)
by Genymobile. Conduit redistributes the unmodified scrcpy server and
implements its own native Mac client for scrcpy's protocol.

## License

Apache License 2.0 — see [LICENSE](LICENSE) and [NOTICE](NOTICE).
