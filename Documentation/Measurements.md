# Measurements

Facts established on real hardware. Code that depends on one of these says
so in a comment; if one stops being true, the code built on it needs
revisiting.

**Test setup, 15 September 2026:** Galaxy S24 Ultra (SM-S928B), Android 16,
over USB and Wireless debugging, with the Mac and the phone on the same Wi-Fi
network. Mac → phone round trip on that network: 7.7–84.7 ms, averaging
43 ms.

## Conduit end to end

A harness drove `ConduitEngine` exactly as the Mac app does. All 21 checks
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

### Pulling the cable, in the Mac app

Mirroring started over USB, then the cable was pulled by hand:

| Time | Event |
|---|---|
| 0.0 s | Cable pulled; Conduit moves the session to the existing Wi-Fi transport |
| 1.3 s | Mirroring decoding again over Wi-Fi |
| 3.1 s | The phone restarts Wireless debugging on a new port (finding 11), dropping the Wi-Fi transport too |
| 10.9 s | Conduit reconnects on the new port and mirroring resumes |

The 8-second second gap came from a retry backoff applied even though the
address had changed. The reconnector now tries a new address at once; that
fix has not been re-measured. After it, wireless mirroring was used for a
full session and reported as working well.

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

7. **`stay_awake` leaks.** It sets "stay awake while charging", and scrcpy
   restores the old value on exit only if it differs. A server relaunched
   before the previous one's cleanup ran recorded the modified value as the
   original, so the phone was left staying awake while charging after
   mirroring stopped. Conduit no longer passes `stay_awake`; `keep_active`
   keeps the phone awake on every transport without changing a setting.

## adb and Wireless debugging

8. **A Mac authorised over USB is accepted over Wireless debugging** with no
   separate pairing step.
9. **A stale adb server blocks Wi-Fi.** An adb server that had been running
   since before the Mac changed networks answered `No route to host` for the
   phone's port, even though the port was reachable. Conduit now restarts the
   adb server once to recover, never while mirroring.
10. **Wireless discovery waits silently without Local Network access.**
   Conduit reports a waiting browser as an "Allow Local Network access"
   activity entry.
11. **Unplugging USB restarts Wireless debugging on a new port.** About three
    seconds after the cable is pulled, the phone's Wireless debugging service
    comes back on a different port, so the Wi-Fi transport drops along with
    USB. Connecting only when the Bonjour advert changed never recovered from
    this — the original wireless mirroring bug.
12. **Once Wi-Fi resolves, the phone shows as one device on two transports.**
    Conduit connected over Wireless debugging by itself, and the phone
    appeared with USB and Wi-Fi together.

## Turning the phone's screen off

13. **The touchscreen stays live with the panel off.** With scrcpy's
    `SET_DISPLAY_POWER`, the phone's screen goes dark but still takes touches
    and vibrates on them.
14. **Android's own display power-off does not help on this phone.** With
    `cmd display power-off 0` (Android 15 and later) the mirror kept updating —
    frame sizes during the 30-second test stayed at 20–88 KB — and input from
    the Mac kept working, but the touchscreen still took input. `getevent` on
    the touchscreen node recorded nothing during that window, so those touches
    reach Android some other way; this was not investigated further.
    Conduit keeps scrcpy's method and pauses touch vibration while the screen
    is off, restoring it afterwards.

## Not yet verified on a device

| Item | Why not yet |
|---|---|
| Device → Mac clipboard | Needs text copied on the phone during a session |
| Audio playback, by ear | The socket connected as PCM, but nobody was listening |
