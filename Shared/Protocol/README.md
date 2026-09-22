# Conduit Link protocol — version 1

Conduit Link connects **Conduit for Android** and **Conduit for Mac** over
the local network. It carries device state, commands, events, low-latency
input and bulk streams between the two.

It does **not** carry screen mirroring, remote input into the phone, phone
audio or the scrcpy clipboard. Those run through scrcpy over adb, because
they need shell privileges an Android app cannot have. See
[Documentation/Architecture.md](../../Documentation/Architecture.md).

**Status.** Framing, envelopes, error codes and the v1 message catalog are
fixed; both platforms test against the vectors in [`vectors/`](vectors).
The handshake and pairing section is a reviewed draft that is implemented
in Phase 4 — its test vectors land with that implementation.

---

## 1. Roles and discovery

| | |
|---|---|
| **Mac** | Listener. Always running while Conduit is open. |
| **Phone** | Connector. It roams between networks, so it finds the Mac, not the other way round. |

- The Mac advertises Bonjour service type **`_conduit._tcp`** with TXT keys
  `id` (the Mac's device ID, §4) and `v` (highest protocol version).
- It prefers TCP port **47384**, and falls back to any free port if that one
  is taken. Bonjour always advertises the real port.
- The phone tries each trusted Mac's last-known address first, and runs
  discovery in parallel.

## 2. Framing

Every byte on the connection belongs to a frame. All integers are
big-endian.

```
 0         1         2                   6
┌─────────┬─────────┬───────────────────┬─────────────────┐
│ channel │  type   │   length (u32)    │ payload         │
│   u8    │   u8    │                   │ `length` bytes  │
└─────────┴─────────┴───────────────────┴─────────────────┘
```

| Channel | Name | Direction | Types |
|---|---|---|---|
| 0 | `control` | both | `0` handshake (plaintext), `1` envelope (encrypted) |
| 1 | `input` | phone → Mac | §7 |
| 2 | `sensor` | phone → Mac | reserved |
| 3 | `haptic` | Mac → phone | §7 |
| 4 | `media` | both | reserved (app-side camera, audio) |
| 5 | `file` | both | reserved (file transfer) |

- **Size limits.** A control payload may be at most 1 MiB; other channels
  at most 4 MiB. A larger length is a protocol error and closes the
  connection.
- **Unknown channel or type.** The stream is treated as desynchronised and
  the connection is closed. TCP does not reorder or drop bytes, so this can
  only mean a bug; guessing would inject garbage.
- **Before the handshake completes,** only `control/handshake` frames are
  allowed.
- **After it completes,** every other frame's payload is sealed (§5.4), and
  `control/handshake` is no longer allowed.

This header and the binary layouts in §7 come from the trackpad prototype
that preceded Conduit, measured on real hardware: a pointer move costs
6 + 4 bytes before encryption.

## 3. Envelopes

After the handshake, channel 0 type 1 carries one JSON object per frame
(UTF-8, no trailing newline).

### Command

```json
{ "v": 1, "type": "command", "requestID": "6E8B2C1A-0F3D-4B8E-9A61-2F5D7C9E0B14",
  "action": "link.send", "payload": { "url": "https://example.com" } }
```

### Response

```json
{ "v": 1, "type": "response", "requestID": "6E8B2C1A-0F3D-4B8E-9A61-2F5D7C9E0B14",
  "status": "success", "payload": {} }
```

```json
{ "v": 1, "type": "response", "requestID": "6E8B2C1A-0F3D-4B8E-9A61-2F5D7C9E0B14",
  "status": "failure",
  "error": { "code": "permission_denied", "message": "Conduit needs permission to show notifications." } }
```

### Event

```json
{ "v": 1, "type": "event", "event": "call.incoming",
  "epoch": "0B7C9D2E-6A41-4F0B-8E3C-5D2A1F9B7C60", "seq": 42, "timestamp": 1757912345678,
  "payload": { "callID": "c-17", "number": "+91XXXXXXXXXX", "name": "Unknown" } }
```

### Field rules

| Field | Rule |
|---|---|
| `v` | Required. The protocol version the sender is speaking. Must not exceed the version agreed in the handshake. |
| `type` | Required: `command`, `response` or `event`. Any other value is `invalid_request`. |
| `requestID` | Required on commands and responses. A UUID, unique within the sender's session. |
| `action` | Required on commands. Dotted lowercase name (§6). |
| `event` | Required on events. Dotted lowercase name (§6). |
| `status` | Required on responses: `success` or `failure`. |
| `error` | Required when `status` is `failure`: `{ "code", "message" }`. `message` is human-readable and safe to show. |
| `epoch` | Required on events. A UUID the sender generates each time its process starts. |
| `seq` | Required on events. Starts at 1 in each epoch and increases by 1 per event. |
| `timestamp` | Optional. Sender's wall clock, in milliseconds since the Unix epoch. For display only; never for ordering. |
| `payload` | Optional object. Receivers ignore fields they do not know. |

### Behaviour

- **Responses.** Every command gets exactly one response. The sender gives
  up after 15 seconds (unless the action says otherwise) and reports
  `timeout` locally.
- **Duplicates.** A receiver remembers the last 256 completed `requestID`s
  for 5 minutes. A repeated command is not executed again: the cached
  response is re-sent. A repeat of a command still in progress is ignored,
  because the original will answer.
- **Stale events.** A receiver tracks the last `(epoch, seq)` per peer. An
  event with a lower or equal `seq` in the same epoch is dropped as stale.
- **Restarts.** An event with a new `epoch` means the peer restarted. The
  receiver discards per-session assumptions and sends `state.sync`.
- **Unknown names.** An unknown `action` gets a `failure` response with
  code `unsupported`. An unknown `event` is ignored.
- **Privacy.** Clipboard text, call numbers and names, and link URLs are
  never written to logs on either platform.

## 4. Identity

- Every installation creates a long-term **ECDSA P-256 identity key**. It
  lives in the Keychain on the Mac and in the Android Keystore on the phone,
  and it never leaves the device.
- Public keys are encoded as the 65-byte uncompressed X9.63 point, in
  standard padded base64.
- The **device ID** is the first 16 bytes of SHA-256(public key), as 32
  lowercase hex characters.
- A device stores, for each paired peer: device ID, public key, name,
  platform, last seen, preferred flag and approved features. Nothing else.

## 5. Handshake and pairing — draft

Handshake messages are `control/handshake` frames holding a JSON object
with `"type": "handshake"` and a `step`.

### 5.1 Hello

1. **Phone → Mac:** `hello`, containing:
   - `versions` — array of supported protocol versions
   - `device` — `DeviceInfo` (§6)
   - `identityKey` — base64
   - `ephemeralKey` — a fresh P-256 public key, base64
   - `intent` — `connect`, or `pair` when the user chose "Add Mac"
2. **Mac → phone:** `hello`, with the same fields, plus:
   - `version` — the highest common version
   - `mode` — `authenticate` or `pair`
   - `commitment` (pair mode only) — base64 of
     HMAC-SHA256(key = `Ns`, message = `ephC ‖ ephS`), where `Ns` is a
     random 32-byte nonce the Mac keeps secret for now.

The Mac chooses `authenticate` when it trusts the phone's identity key and
the phone's intent is `connect`. It chooses `pair` when pairing is open on
the Mac; otherwise it answers with a `not_paired` error.

### 5.2 Key schedule

```
shared  = ECDH(own ephemeral private key, peer ephemeral public key)   -- 32 bytes
th      = SHA-256(phone hello payload bytes ‖ Mac hello payload bytes) -- exactly as sent
kPhone  = HKDF-SHA256(ikm = shared, salt = th, info = "conduit v1 phone->mac", 32)
kMac    = HKDF-SHA256(ikm = shared, salt = th, info = "conduit v1 mac->phone", 32)
```

The version lists and modes are both inside `th`, so a tampered negotiation
cannot survive authentication.

### 5.3 Authenticate

Each side sends `auth` with `signature`: the DER ECDSA-SHA256 signature over
`"conduit-auth-v1" ‖ role ‖ th`, where `role` is `phone` or `mac`. Each side
verifies it against the peer's stored identity key. The Mac then sends
`ready` with `session: { "epoch", "heartbeatSeconds" }`.

### 5.4 Sealed frames

- **Algorithm:** AES-256-GCM, with a separate key per direction.
- **Nonce:** 4 zero bytes followed by an 8-byte big-endian counter. The
  counter starts at 0 in each direction and increases by 1 per frame.
- **Associated data:** the frame's `channel` and `type` bytes.
- **Payload:** ciphertext followed by the 16-byte tag.
- **Failure:** any failure to open a sealed frame closes the connection.
- `auth`, `pair.*` and `ready` are the first sealed frames, so they also
  confirm both sides derived the same keys.

### 5.5 Pair

1. **Phone → Mac:** `pair.nonce` with `Nc`, a random 32 bytes.
2. **Mac → phone:** `pair.reveal` with `Ns`. The phone checks it against
   `commitment` and aborts on mismatch.
3. **Both devices** show the six-digit code:
   `SAS = u32(SHA-256("conduit-sas-v1" ‖ ephC ‖ ephS ‖ Nc ‖ Ns)[0..4]) mod 1 000 000`,
   zero-padded.
4. **After the user confirms the code on that device,** each side sends
   `pair.confirm` with a signature over
   `"conduit-pair-v1" ‖ role ‖ th ‖ Nc ‖ Ns`. A user who rejects sends
   `pair.reject`, and the connection closes.
5. **Once both confirmations are verified,** each side stores the peer's
   identity, and the Mac sends `ready`.

**Why the commitment.** The Mac commits to `Ns` before it sees `Nc`, and
the phone reveals `Nc` before it sees `Ns`. A man-in-the-middle must choose
one of the nonces blind, so it matches both codes with probability 10⁻⁶ per
attempt rather than by trial. This is the same structure as Bluetooth's
numeric comparison.

## 6. Message catalog, v1

Payload objects shared by several messages:

```text
DeviceInfo   { id, name, model?, manufacturer?, platform: "android" | "macos", osVersion?, appVersion? }
Battery      { level: 0–100, charging: Bool }
Network      { type: "wifi" | "cellular" | "ethernet" | "none" }
Snapshot     { device: DeviceInfo, battery?: Battery, network?: Network, locked?: Bool,
               features: { <featureID>: <availability> } }
```

**Feature IDs:** `mirroring`, `remoteInput`, `trackpad`, `clipboard`,
`camera`, `calls`, `links`, `audio`, `files`, `notifications`, `findMac`.

**Availability:** `available`, `active`, `requires_permission`,
`requires_setup`, `disabled`, `unsupported`, `planned`.

### Session

| Name | Kind | Direction | Payload | Response payload |
|---|---|---|---|---|
| `session.ping` | command | both | `{ sentAt }` | `{ sentAt }` (echoed, for round-trip time) |
| `session.bye` | event | both | `{ reason }` | — |
| `state.sync` | command | Mac → phone | `{}` | `Snapshot` |

### Device

| Name | Kind | Direction | Payload |
|---|---|---|---|
| `device.snapshot` | event | phone → Mac | `Snapshot` — sent after `ready` |
| `device.battery` | event | phone → Mac | `Battery` |
| `device.network` | event | phone → Mac | `Network` |
| `device.lock` | event | phone → Mac | `{ locked }` |
| `features.changed` | event | phone → Mac | `{ features }` |

### Features

| Name | Kind | Direction | Payload |
|---|---|---|---|
| `mirroring.request` | command | phone → Mac | `{}` — ask the Mac to start mirroring |
| `trackpad.start` / `trackpad.stop` | command | both | `{}` |
| `trackpad.state` | event | phone → Mac | `{ active, foreground }` |
| `trackpad.config` | event | phone → Mac | `{ sensitivity, naturalScrolling }` |
| `link.send` | command | both | `{ url, title? }` |
| `clipboard.set` | command | both | `{ text, sensitive }` |
| `call.incoming` | event | phone → Mac | `{ callID, number?, name? }` |
| `call.state` | event | phone → Mac | `{ callID, state: "ringing" \| "dialing" \| "active" \| "held" \| "ended", direction: "incoming" \| "outgoing" }` |
| `call.answer` / `call.decline` / `call.end` | command | Mac → phone | `{ callID }` |
| `call.dial` | command | Mac → phone | `{ number }` |
| `call.mute` | command | Mac → phone | `{ muted }` — may fail with `unsupported` |
| `mac.find` | command | phone → Mac | `{}` — the Mac plays a sound until dismissed |

## 7. Binary channels

Same layouts as the measured trackpad prototype.

**`input` (1), phone → Mac.** Movement is relative: the phone has no idea
how large the Mac's desktop is.

| Type | Name | Body |
|---|---|---|
| 0 | pointer move | `dx i16`, `dy i16` |
| 1 | pointer button | `button u8` (0 left, 1 right, 2 middle), `down u8` |
| 2 | scroll | `dx i16`, `dy i16` |
| 3 | key | `key u16` (0 volume up, 1 volume down), `down u8` |

Under backpressure, the phone drops pointer moves and scrolls, but never
button or key transitions — a lost button-up leaves the Mac holding a
stuck mouse button.

**`haptic` (3), Mac → phone.**

| Type | Name | Body |
|---|---|---|
| 0 | vibrate | `durationMs u16`, `amplitude u8` (1–255) |

## 8. Errors

| Code | Meaning |
|---|---|
| `invalid_request` | Malformed envelope or payload |
| `unsupported` | Unknown action, or a feature this device cannot provide |
| `permission_denied` | The OS or the user has not granted a required permission |
| `requires_setup` | A one-time setup step is missing (for example Wireless debugging) |
| `device_unavailable` | The target device is not connected |
| `phone_locked` | The action needs the phone unlocked |
| `timeout` | No response in time (reported locally by the sender) |
| `network_changed` | The connection moved networks mid-request |
| `peer_restarted` | The peer's epoch changed while the request was in flight |
| `duplicate_request` | Reserved; duplicates normally replay the cached response |
| `stale_event` | Reserved for diagnostics; stale events are dropped silently |
| `not_paired` | The peer's identity is not trusted |
| `version_mismatch` | No common protocol version |
| `busy` | The device is already doing this |
| `cancelled` | The user or the system cancelled the action |
| `internal` | Unexpected failure; the message says what happened |

Receivers must accept codes they do not know and treat them as `internal`.

## 8a. Hotspot request over Bluetooth LE

When the Mac has no network it cannot reach the phone over Conduit Link, so
it asks for the phone's hotspot over Bluetooth LE instead. Android does not
let an app turn its hotspot on, so the phone answers by showing a
notification that opens the hotspot switch.

- **Roles.** The phone is the peripheral: while it has a paired Mac and the
  person has not turned requests off, it advertises service
  `9D99F667-22A5-4207-B9F0-CF2A1F80D81B` and serves one writable
  characteristic, `A9FE1931-A845-4B54-811D-9095A568370A`. The Mac is the
  central: it scans only when it wants the hotspot.
- **The advert carries no identifier** beyond the service UUID. The phone's
  Bluetooth address rotates as Android's privacy rules require.
- **The request** is one write, big-endian:

```
┌─────────┬──────────┬────────────┬───────────────┬────────────┬───────────┐
│ version │ macID    │ phoneID    │ timestamp     │ nonce      │ signature │
│ u8 = 1  │ 16 bytes │ 16 bytes   │ u64 ms (Unix) │ 16 bytes   │ DER       │
└─────────┴──────────┴────────────┴───────────────┴────────────┴───────────┘
```

  `macID` and `phoneID` are the raw 16 bytes of each device ID (§4). The
  signature is ECDSA-SHA256 by the Mac's identity key over
  `"conduit-hotspot-v1" ‖ macID ‖ phoneID ‖ timestamp ‖ nonce`.
- **The phone acts only if** it is paired with `macID`, `phoneID` is its own,
  the signature verifies against the stored key, the timestamp is within two
  minutes of its own clock, and the nonce has not been seen in the last five
  minutes. Anything else is ignored without an answer.
- **The Mac** writes one request per paired phone, because it cannot tell
  from the advert which phone is which.

## 9. Versioning

- The version increases only when an existing layout or rule changes
  incompatibly.
- New actions, events, payload fields, feature IDs and error codes are
  additive and do not change the version.
- There is no silent fallback: the handshake negotiates the highest common
  version, or fails with `version_mismatch`.

## 10. Test vectors

| File | Contents |
|---|---|
| [`vectors/envelopes.json`](vectors/envelopes.json) | Valid envelopes that must decode and re-encode to the same JSON value, and invalid ones that must be rejected |
| [`vectors/frames.json`](vectors/frames.json) | Plaintext frames as hex, for the framing codec |
| [`vectors/handshake.json`](vectors/handshake.json) | The handshake's key schedule, signed statements, pairing code, device ID and sealed frames |
| [`vectors/hotspot.json`](vectors/hotspot.json) | A hotspot request from a fixed Mac key: its signed statement, wire bytes and a signature to verify |

Swift runs them in `ConduitProtocolTests`; Kotlin runs them in
`:core:testDebugUnitTest`. A change to this document without matching vector
updates is incomplete.
