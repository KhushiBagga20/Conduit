# Conduit design system

One brand across Conduit for Android, the menu bar and the workspace —
without making three platforms look like one web page.

## What is shared

[`tokens.json`](tokens.json) is the source of truth for:

| Token | Used for |
|---|---|
| `color` | Accent, the "flow" highlight, surfaces, text, and the four status colours, each with a light and a dark value |
| `radius` | Corner radii, with separate Mac and Android scales |
| `spacing` | One spacing scale for both platforms |
| `type` | Six type roles, sized separately for each platform |
| `motion` | Three durations for small, meaningful animation |
| `features` | Feature names and their icons (SF Symbols on Mac, Material Symbols Rounded on Android) |
| `availability` | Labels for feature states: *Planned*, *Requires permission*, *Needs setup*, *Not supported on this device* |
| `terms` | Shared wording for connection states and quick actions |

Run `python3 Shared/Design/generate.py` after editing it. That writes:

- `Shared/ConduitKit/Sources/ConduitDesign/Generated/DesignTokens.swift`
- `Android/core/src/main/java/com/khushi/conduit/core/design/DesignTokens.kt`

`generate.py --check` fails when either is stale; `Scripts/preflight.sh`
runs it.

## What stays native

| | Mac | Android |
|---|---|---|
| Surfaces | System materials and window backgrounds; tokens for cards and status | Material 3 surfaces built from the tokens; dynamic colour off so the brand holds |
| Type | SF Pro via the six roles | Roboto via the Material 3 type scale, mapped to the same roles |
| Icons | SF Symbols | Material Symbols Rounded |
| Navigation | Sidebar, toolbar, menu bar popover | Navigation bar, top app bar |

## Status language

| State | Colour | Wording |
|---|---|---|
| Connected | `statusConnected` | Connected |
| In progress | `statusWorking` | Connecting… / Reconnecting… / Pairing… |
| Failed | `statusError` | A sentence saying what happened and what to do |
| Idle | `statusIdle` | Not connected |

A feature that is not built says **Planned**. One that needs something from
the user says so plainly — never a button that silently does nothing.
