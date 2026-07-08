# VoiceOver Radar Kit

A drop-in Swift package that streams an iOS app's live `UIAccessibility` tree —
the same information VoiceOver consumes — over a tiny local HTTP server, so an
external tool (e.g. a Mac companion) can read the current screen, outline
elements, and drive accessibility actions.

## Install

Swift Package Manager:

```swift
.package(url: "https://github.com/akaDuality/VoiceOverRadarKit.git", from: "1.0.0")
```

## Use

In a DEBUG build, start it once at launch:

```swift
#if DEBUG
import VoiceOverRadarKit
// …
VoiceOverRadarKit.shared.start()   // serves on http://localhost:8765/
#endif
```

The stream runs on the **iOS Simulator only** — `start()` is a no-op on a
physical device. On the Simulator, `localhost` is shared with the Mac, so the
companion reads `http://localhost:8765/`.

## What it serves

`GET /` returns a JSON snapshot: app name, screen size, whether a modal is
presented, and the accessibility tree — each element with label, value, hint,
traits, frame (screen points), VoiceOver-style phrase, custom actions, and
custom content.

## Actions

`GET /action?type=…` performs an accessibility action inside the app and
returns the updated snapshot:

| type | params | effect |
|------|--------|--------|
| `increment` / `decrement` | `id` | adjust an `.adjustable` element |
| `custom` | `id`, `name` | invoke an `accessibilityCustomActions` entry |
| `escape` | — | VoiceOver scrub — dismiss the presented popover/sheet |
| `magictap` | — | VoiceOver magic tap — the app's primary action |

`id` is the per-element id from the snapshot.

> For development/debugging use. Ship it behind `#if DEBUG`.

## See also

- [VoiceOver Radar](https://github.com/akaDuality/VoiceOverRadar) —
  a macOS companion app that reads this stream: lists elements in VoiceOver
  order, outlines them on the Simulator, and drives taps, adjust, custom
  actions, and VoiceOver gestures.
