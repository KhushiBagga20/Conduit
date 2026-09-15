# Conduit architecture

Conduit is one product with three interfaces:

| Interface | Platform | Responsibility |
|---|---|---|
| **Conduit for Android** | Android 12+ | Phone-side permissions, hardware, services and Android-native actions |
| **Conduit menu bar** | macOS 15+ | Always-available status, quick actions, notifications — and the owner of the connection |
| **Conduit workspace** | macOS 15+ | The full window: phone screen, trackpad, camera, calls, links, clipboard, activity, devices, settings |

```
ONE PHONE · ONE CONNECTION · ONE SHARED DEVICE STATE · THREE INTERFACES
```

## Decisions

These were agreed before implementation started. Changing one is a design
change, not a refactor.

1. **One connection owner.** On the Mac, the menu bar layer owns the only
   connection to a phone. The workspace window is a second interface in the
   same process. Closing the workspace never closes the connection.
2. **A seam for a future helper.** Both Mac interfaces talk to the owner
   through one state-and-command API (`ConduitStore` + `ConduitCommands`).
   The owner can later move into a helper process behind XPC without
   rewriting either interface. That move happens only once the shared-state
   architecture is stable.
3. **Two transports, for honest reasons.**
   - **adb / scrcpy** carries screen mirroring, remote input, audio and
     clipboard. These need shell-level privileges on the phone that an
     ordinary Android app cannot have, so they require Wireless debugging
     (or USB debugging).
   - **Conduit Link**, Conduit's own authenticated protocol between the
     Android app and the Mac, carries device state, commands and events:
     battery, network, link sharing, calls, phone-as-trackpad, and more. It
     needs no developer options.
4. **Proven code is moved, not rewritten.** The scrcpy client — wire
   protocol, video parser, VideoToolbox decoder, display layer, audio
   playback, input mapping, reconnect logic — was physically tested on a
   Galaxy S24 Ultra before Conduit existed. It lives in `ConduitMedia` with
   its original concurrency settings and only mechanical changes.
5. **Camera behind an interface.** The first camera implementation is
   scrcpy's camera source (`video_source=camera`). It sits behind a
   replaceable `CameraStream` interface so an app-side Camera2 stream or a
   Core Media I/O Camera Extension can be added later without touching the
   UI.
6. **Trackpad in both directions.** "Use phone as trackpad" turns the phone
   into a Mac trackpad. While mirroring, the Mac's own trackpad and mouse
   control the phone.
7. **Platforms.** macOS 15.0 minimum. Android 12 (API 31) minimum, Jetpack
   Compose with Material 3.
8. **Signing is additive.** Development builds use a personal Apple
   Development certificate. Developer ID signing, notarization and the
   camera extension are layered on later through `Mac/Config` xcconfig
   files, without restructuring the project.

## Layers on the Mac

```
Mac/Conduit (app target)
├── App/          composition root — creates the owner, wires scenes
├── MenuBar/      menu bar interface        ─┐ depend on ConduitState,
└── Workspace/    workspace interface        ─┘ ConduitDesign, ConduitMedia

Shared/ConduitKit (Swift package)
├── ConduitProtocol   wire formats shared with Android — no platform code
├── ConduitState      DeviceState, activity, ConduitStore, ConduitCommands
├── ConduitMedia      scrcpy client: sockets, parser, decoder, renderer, audio, input
├── ConduitCore       the owner: adb, scrcpy servers, device monitor, sessions
└── ConduitDesign     tokens and shared SwiftUI components
```

**Rule:** interface code never imports `ConduitCore`. Only `App/` creates
the owner. `Scripts/check-architecture.sh` enforces this.

## Android

```
Android/
├── app/     Compose UI: Home, Macs, Features, Activity, Settings
└── core/    protocol models, device identity, design tokens
```

A foreground service will own the phone's side of Conduit Link, so the
connection never depends on a visible Activity.

## Shared definitions

`Shared/Protocol` holds the language-neutral protocol specification and test
vectors. Swift and Kotlin both run the same vectors, which is how two
implementations in two languages stay one protocol.

`Shared/Design` holds the design tokens — colour, status colours, radii,
spacing, type roles, icons and terminology — generated into Swift and
Kotlin, so the three interfaces share one brand system while each keeps its
platform's conventions.
