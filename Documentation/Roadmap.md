# Roadmap

Each phase ends with every target building, the relevant checks passing on
a real phone, and a report of what changed and what is still limited.

| Phase | Scope | Status |
|---|---|---|
| **0 · Inspect and plan** | Existing technology, reuse assessment, architecture | Done |
| **1 · Foundation** | Workspace, protocol specification, design tokens, ConduitKit, proven media stack, Mac app with menu bar and workspace, Android skeleton | Done — two hands-on checks pending |
| **2 · Mac workspace** | Full workspace UI, phone screen with all existing mirroring features, fit/fill, fullscreen, always-on-top, screenshot | Planned |
| **3 · Menu bar** | Connection ownership, quick actions, notifications, launch at login, auto-connect | Planned |
| **4 · Android** | Pairing, foreground service, home, Macs, features, settings, share target, trackpad | Planned |
| **5 · Link sharing** | Android → Mac and Mac → Android, recents, notifications | Planned |
| **6 · Calls** | Incoming call events, accept/decline/end, outgoing requests, permissions | Planned |
| **7 · Polish and release** | Latency, reconnection, accessibility, shortcuts, icons, onboarding, packaging | Planned |

## Plan — what is being built next

Everything still planned (links, files, notifications, calls, the trackpad,
find-my-Mac) needs one thing first: a channel between Conduit for Android
and Conduit for Mac. Mirroring will keep running over adb, because it needs
shell privileges; everything else runs over Conduit Link, which needs none
and works over any network the two share — including the phone's hotspot.

| Stage | What it adds | Depends on |
|---|---|---|
| **A · Anywhere** | Reach the phone over its own hotspot, where Wireless debugging cannot go | — |
| **B · Conduit Link** | The channel: Mac listener and Bonjour advert, phone client and foreground service, identity keys, pairing, sealed frames, heartbeat. Built on both sides; interop checked between Kotlin and the running Mac — pairing on the phone pending | A |
| **C · Device state** | Battery, charging and network shown on the Mac from the phone itself, not from adb polling | B |
| **D · Links** | Share a link from the phone to the Mac and back, from the share sheet and the menu bar | B |
| **E · Find my Mac** | Ring this Mac from the phone | B |
| **F · Files** | Send a file each way, over the link's file channel | B |
| **G · Notifications** | Phone notifications on the Mac, opt-in per app, with dismiss | B |
| **H · Phone as trackpad** | The phone's screen drives the Mac's pointer; needs macOS Accessibility permission | B |
| **I · Calls** | Incoming call events on the Mac, and answer/decline where Android allows it | B, G |
| **J · Camera** | The phone's camera in a Conduit window through scrcpy. Using it in other Mac apps needs a Camera Extension and a paid Apple Developer account | — |

Each stage ends the way every phase does: both apps build, the checks pass
on the phone, and anything still limited is labelled in the UI rather than
hidden.

## Phase 1 verification

| Check | Status |
|---|---|
| ConduitKit builds; 35 tests pass (protocol vectors, scrcpy byte layouts, adb parsing, phone grouping) | Done |
| Android app builds; core runs the same protocol vectors | Done |
| Mac app builds for macOS 15; interfaces cannot import the owner | Done |
| Menu bar and workspace layouts checked in light and dark | Done |
| Mirroring, input, audio socket and screen-off through the new owner, on a Galaxy S24 Ultra | Done — see [Measurements](Measurements.md) |
| Recovery after the phone-side server dies, and after losing USB mid-session | Done |
| Two scrcpy servers side by side (for a background clipboard session) | Done |
| Wireless debugging found through macOS Bonjour and connected automatically | Done |
| Mirroring continues over Wi-Fi when the cable is pulled, in the Mac app | Done |
| scrcpy camera source on the test phone | Done |
| Android interface checked on the phone | Done |
| Phone screen in its own window while mirroring | Built — hands-on check pending |
| Redesigned Android interface (live Wi-Fi, battery and setup cards) | Rendered off-device in light and dark — check on the phone pending |
| Phone screen off ignores touches | Built as a touch guard in Conduit for Android — check on the phone pending |
| Mirroring over the phone's own hotspot | Built — check on the phone pending |
| Device → Mac clipboard and audio playback checked by a person | Pending |

## Known platform limits

These shape the product and are shown in the UI rather than hidden.

- **Mirroring, remote input and audio need Wireless debugging** (or USB
  debugging). Android does not let an ordinary app inject input or capture
  audio without shell privileges.
- **Wireless debugging cannot run on a hotspot.** Android turns it off
  whenever Wi-Fi is off, and refuses to start without a Wi-Fi network
  (AOSP `AdbDebuggingManager`). Conduit opens adb's own port instead, from
  the Mac while the phone is connected, and the phone then answers over its
  hotspot. That port stays open on every network the phone joins until it is
  turned off or the phone restarts, so Conduit says so plainly and offers
  the switch.
- **Turning the phone's screen off leaves its touchscreen live** on the test
  phone, and adb cannot disable an input device. Conduit for Android
  swallows those touches with an accessibility service while the Mac has the
  screen off; it needs Android 13 or later.
- **Phone → Mac clipboard** works through the mirroring session. Android 10+
  blocks background clipboard reads for apps.
- **Phone as trackpad** needs the Android app on screen; Android delivers
  touches only to the foreground app.
- **Call audio stays on the phone.** Cellular call audio cannot be routed to
  the Mac. Call control (answer, decline, end) is possible where Android
  allows it and will be verified per device.
- **Links sent to Android** open from a notification: Android 10+ does not
  let apps open screens from the background.
- **The system-wide camera** (a Camera Extension) needs Developer ID
  signing; it is planned, not built.
