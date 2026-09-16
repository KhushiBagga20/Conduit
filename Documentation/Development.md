# Development

## Requirements

| | |
|---|---|
| Mac | macOS 15 or later, Xcode 26 |
| adb | `brew install android-platform-tools` |
| Android builds | JDK 17 and the Android SDK (platform 35) |
| Phone | Android 12 or later, with USB debugging or Wireless debugging on |

## Conduit for Mac

Open `Mac/Conduit.xcodeproj`, choose the **Conduit** scheme and run. Conduit
starts in the menu bar; the workspace window opens from there.

From the command line:

```bash
xcodebuild -project Mac/Conduit.xcodeproj -scheme Conduit -configuration Debug build
```

If `xcodebuild` says it requires Xcode, `xcode-select` is pointing at the
Command Line Tools. Prefix the command with
`DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer` instead of changing
the system setting.

**Signing.** Development builds sign automatically with the team in
`Mac/Config/Signing.xcconfig`. To use your own team, create
`Mac/Config/Signing.local.xcconfig` (git-ignored) containing
`DEVELOPMENT_TEAM = YOURTEAMID`. Signing with a stable team keeps macOS
privacy grants such as Local Network across rebuilds.

**Permissions on first run.** macOS asks whether Conduit may use the local
network. Allow it: that is how Conduit finds phones with Wireless debugging
on.

### ConduitKit

The shared Swift package builds and tests on its own:

```bash
cd Shared/ConduitKit
swift test
```

The tests cover the Conduit Link vectors, scrcpy byte layouts, adb output
parsing, phone grouping and server arguments.

### Logs

Conduit logs to the unified log under the subsystem `com.khushi.Conduit`.
Clipboard text, link URLs and call details are never logged.

```bash
/usr/bin/log stream --level debug --predicate 'subsystem == "com.khushi.Conduit"'
```

### Interface snapshots

Debug builds can render the menu bar and workspace pages offscreen with
preview data, without Screen Recording permission:

```bash
Conduit.app/Contents/MacOS/Conduit --render-snapshots /tmp/conduit-snapshots
```

Scroll views do not draw into offscreen captures, so pages are rendered
without their scroll container; the sidebar and forms are stock controls and
are not included.

## Conduit for Android

```bash
cd Android
./gradlew :app:assembleDebug          # build the app
./gradlew :core:testDebugUnitTest     # run the protocol vectors
adb install -r app/build/outputs/apk/debug/app-debug.apk
```

Screens that read the phone are split into a stateful `…Screen()` and a
stateless `…Content()` that only draws. `ui/screens/Previews.kt` renders the
content with sample data in Android Studio's preview pane.

### Conduit Link on this Mac

Conduit listens on port 47384 and advertises `_conduit._tcp` so phones can
find it. macOS refuses the advert until Conduit is allowed in **System
Settings → Privacy & Security → Local Network**; Conduit keeps the port open
either way and says so in Devices, because a phone can also be told where to
find the Mac over adb.

```bash
lsof -nP -iTCP:47384 -sTCP:LISTEN     # the listener
dns-sd -B _conduit._tcp               # the advert, once allowed
```

## Shared definitions

- **Design tokens** — edit `Shared/Design/tokens.json`, then run
  `python3 Shared/Design/generate.py` to regenerate the Swift and Kotlin
  constants.
- **Protocol** — `Shared/Protocol/README.md` is the specification. A change to
  it needs matching vector updates in `Shared/Protocol/vectors`, which both
  platforms' tests run.

## Before every commit

```bash
Scripts/preflight.sh
```

It prints the status and diff summary and fails on secret-shaped content,
signing assets, home-directory paths, the previous product name, interface
code importing `ConduitCore` (`Scripts/check-architecture.sh`), or stale
generated tokens. Build and test the targets you touched as well.
