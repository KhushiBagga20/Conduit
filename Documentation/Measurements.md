# Measurements

Facts established on real hardware. Code that depends on one of these says
so in a comment; if one stops being true, the code built on it needs
revisiting.

**Test setup, 15 September 2026:** Galaxy S24 Ultra (SM-S928B), Android 16,
over USB and Wireless debugging, with the Mac and the phone on the same Wi-Fi
network. Mac → phone round trip on that network: 7.7–84.7 ms, averaging
43 ms.

## Conduit end to end

A harness drove `ConduitEngine` exactly as the Mac app does. All 20 checks
passed:

| Area | Result |
|---|---|
| Detection | Phone detected over USB through `adb track-devices`; properties loaded in ~0.3 s; one connection announcement, with the phone's own name |
| Mirroring | Running 1.2–2.0 s after the request; H.264 886×1920; zero dropped frames |
| Sockets | Audio connected as raw PCM; control connected; video → audio → control order held |
| Isolation | Each server runs on a unique `scid` socket with its own forward |
| Input | Screen-off and screen-on reached the phone (checked in SurfaceFlinger) |
| Recovery | Server killed on the phone → relaunched on a new socket; mirroring resumed in ~2.2 s; the old forward was removed |
| Transport loss | USB link reset during mirroring → session moved to Wi-Fi and kept decoding within ~2 s |
| Stop | Returns to idle; server gone from the phone; forward removed |

## scrcpy-server v4.1

1. **The server deletes its own jar as soon as it has loaded it.** The jar is
   pushed before every launch, and each server gets its own path. With a
   shared path, a second server launched right after the first aborts,
   because the first has already removed the file.
2. **Device metadata comes only after every socket is accepted.** The first
   socket gets the dummy byte immediately. The device name follows only once
   video, audio and control have all connected, so a client that waits for
   the name before opening the next socket deadlocks.
3. **The "Device:" log line comes slightly before the socket accepts.**
   Connecting on that line alone made the first attempt bounce; the
   reconnect backoff then stretched recovery to 11–13 s. A 250 ms grace
   brought it to about 2 s.
4. **Two servers run side by side.** A mirroring server (video + control) and
   a control-only server ran together. The control-only server's commands
   reached the phone while the other kept streaming. This makes the planned
   background clipboard session viable.
5. **Screen-off is visible only in SurfaceFlinger.** `SET_DISPLAY_POWER` off
   shows as `powerMode=OFF` in `dumpsys SurfaceFlinger`, while the display
   manager's `mScreenState` stays `ON`.
6. **The camera source works.** The phone exposes four cameras (two back,
   two front, up to 60 fps). The back camera streamed 1280×720 H.264 at
   about 7.3 Mbps.

## adb and Wireless debugging

7. **A Mac authorised over USB is accepted over Wireless debugging** with no
   separate pairing step.
8. **A stale adb server blocks Wi-Fi.** An adb server that had been running
   since before the Mac changed networks answered `No route to host` for the
   phone's port, even though the port was reachable. Conduit now restarts the
   adb server once to recover, never while mirroring.
9. **Wireless discovery waits silently without Local Network access.**
   Conduit reports a waiting browser as an "Allow Local Network access"
   activity entry.
10. **Once Wi-Fi resolves, the phone shows as one device on two transports.**
    Conduit connected over Wireless debugging by itself, and the phone
    appeared with USB and Wi-Fi together.

## Not yet verified on a device

| Item | Why not yet |
|---|---|
| The Android interface, visually | The phone was locked during testing |
| Device → Mac clipboard | Needs text copied on the phone during a session |
| Audio playback, by ear | The socket connected as PCM, but nobody was listening |
