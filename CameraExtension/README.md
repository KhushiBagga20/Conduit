# Camera Extension — planned

A Core Media I/O Camera Extension would make the phone's camera selectable
in FaceTime, Zoom and every other Mac app, not only inside Conduit.

**Status: planned, not implemented.**

## Why it is not built yet

- A camera extension is a system extension. Installing one requires the
  `com.apple.developer.system-extension.install` entitlement, Developer ID
  signing and notarization — which need a paid Apple Developer Program
  membership. Local development builds cannot load it.
- The user must approve it in System Settings, so it deserves its own
  onboarding step.

## How the current camera pipeline prepares for it

The camera feature is built around a replaceable stream interface
(`CameraStream` in ConduitKit). Today one implementation exists: the phone
camera through scrcpy (`video_source=camera`). The preview in the Conduit
app is only one consumer of decoded frames.

When the extension lands it becomes a second consumer: the app (or the
future helper) pushes the same frames into the extension's sink stream.
Neither the phone side nor the decoding changes.
