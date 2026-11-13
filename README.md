<p align="center">
  <img src="docs/images/icon.png" width="128" height="128" alt="Great Display icon">
</p>

<h1 align="center">Great Display</h1>

<p align="center">
  A free, open-source menu bar display manager for macOS.<br>
  Resolutions, HiDPI, brightness, DDC/CI, virtual screens, mirroring and streaming in one popover.
</p>

<p align="center">
  <a href="https://thienduc12311.github.io/Great-display/"><b>Website</b></a> ·
  <a href="https://thienduc12311.github.io/Great-display/#demo">Try the demo</a> ·
  <a href="https://thienduc12311.github.io/Great-display/release-notes.html">Release notes</a>
</p>

<p align="center">
  <a href="https://github.com/thienduc12311/Great-display/releases/latest"><img alt="Latest release" src="https://img.shields.io/github/v/release/thienduc12311/Great-display?sort=semver"></a>
  <a href="https://github.com/thienduc12311/Great-display/actions/workflows/ci.yml"><img alt="CI" src="https://github.com/thienduc12311/Great-display/actions/workflows/ci.yml/badge.svg"></a>
  <img alt="macOS 14+" src="https://img.shields.io/badge/macOS-14%2B-blue">
  <img alt="Universal" src="https://img.shields.io/badge/arch-Apple%20Silicon%20%7C%20Intel-lightgrey">
  <a href="LICENSE"><img alt="MIT License" src="https://img.shields.io/badge/license-MIT-green"></a>
</p>

---

Great Display controls resolutions, HiDPI modes, brightness, contrast, volume,
mirroring and virtual screens from a single menu bar popover, with a small
command line interface for scripting and diagnostics. It is written in Swift
with AppKit and SwiftUI and has no third-party dependencies.

## Install

### Download

1. Download the latest **`GreatDisplay-<version>.dmg`** from the
   [Releases page](https://github.com/thienduc12311/Great-display/releases/latest).
2. Open the disk image and drag **GreatDisplay** into **Applications**.
3. Launch it. Great Display is a menu bar app, so look for the display icon in
   the menu bar; it has no Dock icon.

Requires **macOS 14 Sonoma or later**. Builds are universal (Apple Silicon and
Intel).

> [!NOTE]
> Release builds are not notarized by Apple yet, so macOS blocks the first
> launch. Open **System Settings → Privacy & Security**, scroll down and click
> **Open Anyway** next to the Great Display message. Or remove the quarantine
> flag from Terminal:
>
> ```sh
> xattr -dr com.apple.quarantine /Applications/GreatDisplay.app
> ```

Each release lists its changes in the release notes and in
[CHANGELOG.md](CHANGELOG.md), and ships a `SHA256SUMS.txt` to verify the
download (`shasum -a 256 -c SHA256SUMS.txt`).

### Permissions

| Permission | Needed for |
| --- | --- |
| Accessibility | Brightness and volume keys |
| Screen Recording | Streaming a display onto another display |

Everything else, including DDC/CI, mirroring and virtual screens, works without
extra permissions. macOS asks the first time a feature needs one.

### Build from source

You need a recent Xcode with the macOS SDK (the project is developed with
Xcode 27; full Xcode rather than only the Command Line Tools is needed for
universal builds).

```sh
git clone https://github.com/thienduc12311/Great-display.git
cd Great-display
make            # builds dist/GreatDisplay.app for this Mac
make run        # builds and opens it
make package    # universal build + DMG and ZIP in dist/
```

See [Building](#building) for options.

## Features

| Area | Behaviour |
| --- | --- |
| Display inventory | Enumerates online displays, modes, pixel sizes, rotation, main/mirror state, vendor/model/serial identity |
| App menu | Collapsible section per display with a connect switch, combined brightness and resolution sliders on the first level, and a "more options" level with feature panels |
| Resolutions | Resolution slider (one step per size, Default/Native markers, applies on release) and a Display Mode list with HiDPI/LoDPI, refresh-rate and aspect-ratio filters |
| Refresh rate | Rates available for the current size and density |
| HiDPI | Toggles between the low-density and pixel-doubled mode of the current geometry |
| Virtual screens | Created from an aspect-ratio preset, a custom ratio, or matched to a display; a flexible resolution ladder (≈40 sizes) per aspect ratio; size, aspect ratio, density and refresh rate change live without reconnecting; optional over-8K ceiling (16K); mirror target and auto-start |
| Associated displays | A virtual screen can be associated with several displays (including disconnected ones). Options: auto-connect while an associated display is online, or while all are offline; enforce mirroring; auto-start full-screen streaming; follow the associated display's orientation |
| Brightness | Native panel brightness on Apple displays, DDC/CI on external displays, gamma-table dimming everywhere |
| Combined brightness | One knob: hardware above the "Min HW" marker, gamma dimming below it |
| Image adjustments | Gamma, colour temperature, software contrast, red/green/blue gain, invert, suspend and reset — per display, through the colour table |
| Input source | DDC/CI VCP 0x60 switching, listing the inputs the monitor reports |
| Rotation | 0°, 90°, 180°, 270° through the MonitorPanel display manager |
| HDR | Toggles the display's HDR preference where the display offers HDR modes |
| Connect / disconnect | Removes a display from the desktop without cutting power (session-scoped, reconnected on quit) |
| System colors | Dark Mode, Night Shift and True Tone toggles |
| Prevent Sleep | Power assertion that keeps the displays awake |
| Identify / arrange | Full-screen highlight of a display; place a display left/right/above/below the main one |
| Contrast / volume | DDC/CI VCP 0x12 and 0x62 where the monitor supports them; mute through 0x8D (1 = muted, 2 = unmuted) |
| Device control (DDC/CI) | Reads the monitor's capabilities string, then offers its own input list, picture modes (0xDC), colour presets (0x14), hardware RGB gain (0x16/0x18/0x1A), sharpness (0x87), standby (0xD6) and restore actions (0x04/0x05/0x08); raw VCP read/write in Settings |
| Brightness keys | Event tap for the brightness keys (and F14/F15 on PC keyboards), with step size and OSD; starts as soon as Accessibility is granted |
| Volume keys | Routed to the monitor's DDC volume/mute when macOS sends audio to a DisplayPort/HDMI monitor it cannot set the volume of |
| On-screen display | Glass-style HUD for brightness, contrast, volume and errors |
| Main display / mirroring | Main display assignment and mirroring onto another display |
| Stream a display | Full-screen stream onto another display or onto itself (self-stream with video filters); per-source options for pointer, 1:1 pixel mapping, integer scaling, free aspect ratio, cropping, flip, rotation, alignment, zoom, underscan, alpha and target FPS, applied live; resume on connect; interactive mode ("Use Like a Normal Screen") moves the pointer onto the source display when it enters the stream, so clicks, typing, scrolling and the source's menu bar work through the stream |
| Persistence | Settings and per-display configuration stored by display identity |
| Login item | Optional launch at login through `SMAppService` |
| Settings window | Searchable sidebar listing every display and virtual screen; a visual arrangement overview with quick brightness controls; per-display Picture, Color, Monitor and Options tabs; General, Menu Bar (with live preview), Keyboard & OSD and About |
| Menu bar icon | Click opens the menu, Option-click opens Settings, right-click opens a quick menu |
| Deep links | `greatdisplay://settings`, `greatdisplay://display/<id>`, `greatdisplay://brighten` |

## Usage

- **Click** the menu bar icon to open the display menu.
- **Option-click** opens Settings; **right-click** opens a quick menu.
- Brightness keys (and F14/F15 on PC keyboards) control display brightness
  once Accessibility access is granted; step size and OSD are set in
  Settings → Keyboard.
- `greatdisplay://settings`, `greatdisplay://display/<id>` and
  `greatdisplay://brighten` open the app from scripts, Shortcuts or a browser.

### Command line

The executable inside the bundle doubles as a command line tool:

```sh
alias greatdisplay=/Applications/GreatDisplay.app/Contents/MacOS/GreatDisplay
greatdisplay --probe            # display inventory as JSON
```

```
GreatDisplay --probe
GreatDisplay --set-brightness <displayID> <0..1>
GreatDisplay --set-resolution <displayID> <width> <height> [hidpi]
GreatDisplay --toggle-hidpi <displayID>
GreatDisplay --create-virtual <width> <height>
GreatDisplay --ddc-read <displayID>
GreatDisplay --ddc-write <displayID> <vcpHex> <rawValue>
GreatDisplay --ddc-diag <displayID>
GreatDisplay --ddc-caps <displayID>
GreatDisplay --mirror <sourceID> <targetID|off>
GreatDisplay --mirror-demo <targetID> [seconds]
GreatDisplay --stream-check
GreatDisplay --stream-test <width> <targetID> [seconds]
GreatDisplay --rotate <displayID> <0|90|180|270>
GreatDisplay --hdr <displayID> on|off
GreatDisplay --disconnect <displayID> [reconnectAfterSeconds]
GreatDisplay --reconnect <displayID>
GreatDisplay --system-colors [dark|nightshift|truetone on|off]
GreatDisplay --adjust <displayID> gamma=1.2 temperature=0.3 red=1 green=1 blue=0.9 [holdSeconds]
GreatDisplay --self-test
```

`--probe` is the quickest way to confirm the app sees the same displays as the
system, and `--ddc-diag` prints the raw reply frames from each video service.

## Building

`Scripts/build_app.sh` builds, assembles and signs `dist/GreatDisplay.app`.
It reads these environment variables:

| Variable | Default | Meaning |
| --- | --- | --- |
| `VERSION` | latest git tag, else `0.0.0` | `CFBundleShortVersionString` |
| `BUILD_NUMBER` | commit count | `CFBundleVersion` |
| `ARCHS` | host architecture | `"arm64 x86_64"` builds a universal binary |
| `SIGN_IDENTITY` | first valid identity, else ad-hoc | Code signing identity; `-` forces ad-hoc |

```sh
VERSION=1.2.0 ARCHS="arm64 x86_64" ./Scripts/build_app.sh
VERSION=1.2.0 ./Scripts/package_release.sh      # dist/GreatDisplay-1.2.0.dmg / .zip
```

Ad-hoc builds are signed with an identifier-based designated requirement, so
Accessibility and Screen Recording grants survive rebuilds. See
[docs/TECHNICAL-NOTES.md](docs/TECHNICAL-NOTES.md#permissions-and-signing).

### Continuous integration and releases

- [`ci.yml`](.github/workflows/ci.yml) builds and packages a universal app on
  every push to `main` and every pull request. The DMG is attached to the
  workflow run as an artifact.
- [`release.yml`](.github/workflows/release.yml) runs when a `vX.Y.Z` tag is
  pushed. It builds the app, publishes a GitHub release with the DMG, ZIP and
  checksums, and writes the release notes from the matching
  [CHANGELOG.md](CHANGELOG.md) section plus the merged pull requests.
  Developer ID signing and notarization switch on when the signing secrets are
  configured.
- [`pages.yml`](.github/workflows/pages.yml) publishes the website in
  [`website/`](website) to GitHub Pages whenever it, `CHANGELOG.md` or the icon
  changes on `main`, and after each release. The release notes page is built
  from `CHANGELOG.md`. Preview it locally with `make site-preview`; regenerate
  the product film with `make promo-video`
  ([`Scripts/make_promo_video.swift`](Scripts/make_promo_video.swift)).

The release process is described in [docs/RELEASING.md](docs/RELEASING.md).

## How it works

```
Sources/
  GDCBridge/      Objective-C bridge to CoreGraphics virtual displays and system toggles
  GDCore/         Display inventory, brightness, DDC/CI, virtual screens, streaming, OSD, input, persistence
  GreatDisplay/   App delegate, menu bar controller, SwiftUI menu and Settings
```

- `DisplayManager` enumerates displays and applies configuration transactions
  (mode, origin, mirroring, rotation).
- `BrightnessEngine` layers native brightness, DDC/CI and gamma-table dimming.
- `DDCController` speaks DDC/CI (Get/Set VCP) to external monitors.
- `VirtualScreenManager` owns virtual display lifetimes through `GDCBridge`.
- `FullScreenStreamController` streams a display with ScreenCaptureKit.

Design decisions, DDC/CI timing, the HiDPI rules and measured behaviour on real
hardware are in [docs/TECHNICAL-NOTES.md](docs/TECHNICAL-NOTES.md).

## Limitations

- The virtual display, DisplayServices brightness client and video-service DDC
  paths are system-private interfaces. They are resolved at runtime and can
  change between macOS releases. The app degrades to software dimming rather
  than failing when a path is unavailable.
- Software dimming scales the gamma table and can clip HDR content.
- Some monitors, docks and hubs do not tunnel DDC/CI. The U2723QE in the test
  setup reported "unsupported" on its video service while the S2725QC worked.
- Screen streaming requires Screen Recording permission (granted once; the
  build keeps a stable signing requirement so it survives rebuilds).
- EDID override writing, HDR/XDR brightness upscaling, picture-in-picture and
  window streaming, TV/AVR integrations and the software audio engine are not
  part of this implementation.

## Contributing

Bug reports, display compatibility reports and pull requests are welcome. Read
[CONTRIBUTING.md](CONTRIBUTING.md) first; it covers the build, the code layout
and how to add a changelog entry. Please follow the
[Code of Conduct](CODE_OF_CONDUCT.md). Security issues go through
[SECURITY.md](SECURITY.md), not public issues.

When reporting a display problem, include the output of
`GreatDisplay --probe` (and `--ddc-caps <displayID>` for DDC issues).

## License

Great Display is released under the [MIT License](LICENSE).

macOS, Apple Silicon, Night Shift and True Tone are trademarks of Apple Inc.
Great Display is an independent project and is not affiliated with Apple or with
any monitor vendor.
