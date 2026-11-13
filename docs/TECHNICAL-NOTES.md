# Technical notes

Implementation details, design decisions and measured behaviour behind Great
Display. For an overview and install instructions see the [README](../README.md).

## Source layout

```
Sources/
  GDCBridge/            Objective-C bridge to the CoreGraphics virtual display facility
  GDCore/               Display inventory, brightness, DDC/CI, virtual screens, OSD, input, persistence
  GreatDisplay/         App delegate, menu bar controller, SwiftUI popover and settings
Scripts/
  build_app.sh          Builds and signs dist/GreatDisplay.app (VERSION, ARCHS, SIGN_IDENTITY)
  package_release.sh    Packages the app into a DMG and ZIP with checksums
  release_notes.sh      Builds GitHub release notes from CHANGELOG.md
  ci_select_xcode.sh    Picks the newest Xcode on CI runners
  make_icon.swift       Renders the app icon
.github/workflows/
  ci.yml                Universal build + package on every push and pull request
  release.yml           Publishes a GitHub release for each vX.Y.Z tag
```

### Core pieces

- `DisplayManager` enumerates displays and applies configuration transactions
  (mode, origin, mirroring, rotation). It reacts to system reconfiguration callbacks.
- `BrightnessEngine` has three layers: the DisplayServices brightness client,
  DDC/CI, and gamma-table dimming. `applySoftwareDimming` captures the display's
  transfer table once and scales it.
- `DDCController` talks to external displays over `DCPAVServiceProxy` video
  services using standard DDC/CI Get VCP / Set VCP frames.
- `VirtualScreenManager` owns virtual display lifetimes through `GDCBridge`.
- `DisplayController` is the UI-facing facade that merges inventory with
  brightness/contrast/volume state.

## Resolution and HiDPI

The resolution picker lists the modes macOS exposes for the display, split into
**HiDPI** (pixel-doubled, `pixelWidth = 2 × width`) and **Low resolution**
entries. Applying a mode uses a CoreGraphics display-configuration transaction,
so a failure is reported instead of leaving a half-applied state.

The **HiDPI** button switches the current logical geometry between its
low-density and pixel-doubled variants and keeps the current refresh rate. The
density request is strict: if a display has no HiDPI variant for the requested
size, the change is refused rather than silently falling back to a
low-resolution mode.

```
GreatDisplay --set-resolution <displayID> 1920 1080 hidpi
GreatDisplay --set-resolution <displayID> 1920 1080 lodpi
GreatDisplay --toggle-hidpi <displayID>
```

With `--set-resolution`, the closest available refresh rate to the current one
is chosen (falling back to the highest), so restoring a resolution does not
silently drop a 120 Hz panel to 60 Hz.

### Smooth mode changes

Mode changes from the menu run the display-configuration transaction on a
background queue, so the menu keeps animating. The menu shows the requested mode
at once, and rapid slider moves collapse to the last one. Only the affected
display fades out and back in through its own colour table (Settings > Menu Bar can
turn this off). Software dimming and image adjustments are re-applied after any
mode change, including changes made in System Settings, because macOS resets the
colour table. `CGConfigureDisplayFadeEffect` is not used: with any explicit fade
the transaction fails with error 1006 on macOS 27.

## DDC/CI

A monitor counts as DDC-capable only after it answers a Get VCP request. A
matched video service that never replies (common behind docks) falls back to
software brightness. Slider and key writes are coalesced per display and VCP
code (only the latest value waits while one is on the wire) and take priority
over background reads. A read that started before a user change never moves
the slider back. Replies are checked against their checksum
(`0x50 ^ bytes`), and "unsupported" results are cached. Maximum values are
cached, so slider writes do not read first. Transactions are spaced at least
50 ms apart. Set VCP frames use the DDC/CI checksum over `0x6E ^ 0x51 ^ payload`.

```
GreatDisplay --ddc-read <displayID> [vcpHex…]
GreatDisplay --ddc-write <displayID> <vcpHex> <rawValue>
GreatDisplay --ddc-caps <displayID>
GreatDisplay --ddc-burst <displayID>     # 30 rapid brightness changes, reports settle time, restores
GreatDisplay --audio-output              # where volume keys go
```

### Brightness keys

The event tap runs on its own thread. On the main thread, any stall (display
reconfiguration, a slow DDC monitor) made macOS disable the tap for timing out.
Each display steps from its own brightness level. If MonitorControl or Lunar
is running, whichever app's tap sits first takes the
keys, so Settings > Keyboard & OSD and the menu show a conflict notice.
`open greatdisplay://key-test` posts one brightness-down/up pair through the
real event path, and `log show --predicate 'subsystem == "app.greatdisplay"'`
shows what the tap received.

## Permissions and signing

Accessibility (brightness keys) and Screen Recording (streaming) grants are
bound to the app's designated requirement. An ad-hoc signature defaults to a
cdhash requirement, which changes on every build. System Settings then keeps
showing the app as enabled, but the grant no longer applies. `build_app.sh`
signs with `SIGN_IDENTITY` (or the first valid signing identity), or else
ad-hoc with `designated => identifier "app.greatdisplay.GreatDisplay"`, so a
grant survives rebuilds. The app watches trust live and starts the
brightness-key tap as soon as access is granted. Settings > Keyboard & OSD has
**Reset Permission** for a stale entry.

## Mirroring a virtual screen

Two paths are available for putting a virtual screen onto a physical display.

**Mirror** (system-level, lowest overhead). The target becomes a mirror of the
source, so it adopts the source's timing:

```sh
GreatDisplay --mirror <sourceID> <targetID>
GreatDisplay --mirror <sourceID> off
```

Un-mirroring restores the target's previous mode, which is captured before the
mirror is applied. The virtual screen card's **Mirror** menu does the same, and
virtual screen configurations can select a permanent mirror target.

**Stream** (window-level). A ScreenCaptureKit capture of the source is shown in
a borderless window on the target. The target keeps its native resolution and
refresh rate, so a 1920×1080 HiDPI virtual screen can be displayed on a 4K panel
at that panel's own mode. Press **Esc** to stop, or use the display's **Stream**
menu.

Streaming requires Screen Recording permission for Great Display. Mirroring
does not.

## Verified behaviour

Measured on macOS 27.0.1 with three displays (two external monitors and one
DisplayLink output):

- Display inventory: 3 displays, 106-206 modes each, HiDPI modes detected.
- DDC/CI: brightness `85/100`, contrast `75/100`, volume `6/100` and input
  source `6939` read from a Dell S2725QC. Setting brightness to `84` was
  accepted and read back as `84/100`, then restored to `85/100`.
- Virtual displays: a 1920 x 1080 HiDPI screen is created as a 3840 x 2160
  panel with 24 modes and a 1920 x 1080 HiDPI desktop.
- Resolution switching on a Dell S2725QC: `2560 × 1440 HiDPI @120` →
  `1920 × 1080 HiDPI @120` → `1920 × 1080 @120` (low resolution) →
  restored to `2560 × 1440 HiDPI @120`.
- HiDPI toggle on the same display: `2560 × 1440 HiDPI @120` ↔
  `2560 × 1440 @120`, restored with the refresh rate intact. On the virtual
  screen, `800 × 600 HiDPI` ↔ `800 × 600` and back.
- Mirroring: a 1920 × 1080 HiDPI virtual screen mirrored onto a Dell U2723QE
  (`2560 × 1440 HiDPI @60`) changed the target to `1920 × 1080 HiDPI @60`,
  `mirrored=true`; un-mirroring restored `2560 × 1440 HiDPI @60`.
- Software dimming and the OSD run on all displays.
- Rotation: the DisplayLink output rotated to 90° (bounds `1680 × 1050` →
  `1050 × 1680`) and back to 0° with its origin kept. Virtual screens do not
  offer rotation.
- DDC/CI on the Dell S2725QC: capabilities read in 2.2 s (model S2725QC,
  MCCS 2.1, inputs USB-C/HDMI 1/HDMI 2, presets sRGB/6500 K/9300 K/User 1/2,
  picture modes Standard/Movie/Game). Sharpness written 60 and read back 60,
  then restored to 50 (the monitor rounds to steps of 10). `--ddc-burst`:
  30 brightness changes in 0.9 s; the monitor held the final value
  0.3–0.46 s after the last change (2.3 s before write priority). The U2723QE does not
  answer DDC and uses software dimming.
- Mode change on a virtual screen: the menu showed the target immediately,
  the main thread kept running (43 frames in 1.2 s), the display faded out
  and in, and 60 % software dimming was still applied afterwards.
- Streaming (`open greatdisplay://stream-self-test`, in the app): a self-stream
  with flip, 90° rotation, monochrome filter and 1.5× zoom showed 118 frames in
  2 s, and kept streaming after options changed live (30 fps cap applied).
- Interactive stream (`open greatdisplay://stream-route-test`, two temporary
  virtual screens): target→source→target mapping round-trips with 0.00 pt error
  at 0°, 90° flipped and 270°. The pointer entering the stream lands on the
  source, and pushing out of the source's edge leaves through the stream's edge.
- Associations (`open greatdisplay://association-test`, two temporary virtual
  screens): connected while the associated screen was offline, disconnected
  when it appeared, then auto-connected, turned portrait to follow it, and
  mirrored onto it.
- Virtual screen lifetime: a disconnected virtual screen is removed at once
  (checked from a fresh process). Before, an unbalanced alloc/init kept it
  connected until the app quit.
- Virtual screens: 38 sizes published for a 16:9 screen. A live resize to 21:9
  kept the display ID and published 21:9 modes. An associated screen connected
  by itself and matched the U2723QE's 16:9 aspect ratio.
- `--self-test` on a 1280 × 720 virtual screen: five slider sizes, a warm
  colour-temperature adjustment moved mid-grey to `r=0.502 b=0.251` and reset to
  neutral, and the screen went offline on disconnect and came back on reconnect.

`--self-test` creates a temporary virtual screen and checks the resolution
slider list, refresh rates, default-mode flags, rotation (where offered), image
adjustments and logical disconnect/reconnect without touching physical displays.
