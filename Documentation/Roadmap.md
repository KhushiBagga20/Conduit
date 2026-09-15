# Roadmap

Each phase ends with every target building, the relevant checks passing on
a real phone, and a report of what changed and what is still limited.

| Phase | Scope | Status |
|---|---|---|
| **0 · Inspect and plan** | Existing technology, reuse assessment, architecture | Done |
| **1 · Foundation** | Workspace, protocol specification, design tokens, ConduitKit, proven media stack, Mac app shell, Android skeleton | In progress |
| **2 · Mac workspace** | Full workspace UI, phone screen with all existing mirroring features, fit/fill, fullscreen, always-on-top, screenshot | Planned |
| **3 · Menu bar** | Connection ownership, quick actions, notifications, launch at login, auto-connect | Planned |
| **4 · Android** | Pairing, foreground service, home, Macs, features, settings, share target, trackpad | Planned |
| **5 · Link sharing** | Android → Mac and Mac → Android, recents, notifications | Planned |
| **6 · Calls** | Incoming call events, accept/decline/end, outgoing requests, permissions | Planned |
| **7 · Polish and release** | Latency, reconnection, accessibility, shortcuts, icons, onboarding, packaging | Planned |

## Known platform limits

These shape the product and are shown in the UI rather than hidden.

- **Mirroring, remote input and audio need Wireless debugging** (or USB
  debugging). Android does not let an ordinary app inject input or capture
  audio without shell privileges.
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
