# Changelog

All notable changes to Great Display are recorded here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and the project uses
[Semantic Versioning](https://semver.org/).

Each release's notes on GitHub are taken from its section below, so add your
change under **Unreleased** in the same pull request.

## [Unreleased]

## [1.4.0] - 2026-11-23

Physical displays and virtual screens now support custom HiDPI resolutions beyond
the limited set macOS exposes by default.

### Added

- **Custom HiDPI resolutions for physical displays.** Each physical display's
  **Picture** tab in Settings now includes a **Custom HiDPI Resolutions** card
  that writes macOS `scale-resolutions` display override plists to
  `/Library/Displays/Contents/Resources/Overrides/` (preserving existing
  override keys). Add any custom `width × height` resolution (aspect-locked or
  free), or click **Add HiDPI Presets** to load a full aspect-matched HiDPI
  preset pack for 16:9, 16:10, 21:9, 32:9, portrait and other panels. Reconnect
  the display or restart macOS to load newly installed modes, and remove the
  override anytime with one click.
- **Custom resolutions & denser HiDPI ladder for virtual screens.** Virtual
  screens now publish a 56-step flexible HiDPI ladder spanning the full
  framebuffer ceiling (up to 3840 wide HiDPI, or 7680 wide with over-8K
  enabled) instead of capping at 1.5× the default size. Each virtual screen's
  settings page also adds a **Custom Resolutions** card to publish exact
  logical sizes live without reconnecting.
- **CLI support:** `--hidpi-override <displayID> <list|presets|add <WxH[:lodpi]>…|remove>`
  inspects, installs and removes physical display HiDPI overrides from the
  command line.

## [1.3.0] - 2026-11-21

Great Display now updates itself, and monitors behind a DisplayLink dock can
switch inputs through an experimental bridge.

### Added

- **Automatic updates.** Great Display checks GitHub for a new release every
  time it starts and once a day. When one is out, a window shows its release
  notes with **Install Update**, **Later** and **Skip This Version**. Install
  Update downloads the release's zip, checks it against the published
  `SHA256SUMS.txt`, verifies the app's code signature, bundle identifier and
  version, then replaces the app and restarts it. The menu shows an
  **Update** badge while a release is waiting, **Tools › Check for Updates…**
  checks on demand, and Settings › About has a Software Update section with
  a switch for the automatic checks.
- **Experimental (beta):** input source switching for monitors behind a
  DisplayLink dock, off by default. Turn it on under Settings › General ›
  Experimental › DisplayLink input switching. It needs a patched open-source
  build of DisplayLink's DDC bridge (`libdlmddc.dylib`) loaded into DisplayLink
  Manager; stock DisplayLink Manager cannot change inputs. The menu then shows
  "Input Source (Beta)" for DisplayLink monitors that macOS cannot reach over
  DDC/CI, and `--displaylink-probe` reports the bridge and each monitor's input.

## [1.2.0] - 2026-11-19

Monitors that refuse DDC/CI on the video cable, such as the Dell U2723QE, can
now be controlled over their USB connection, so brightness, contrast and input
source work on them instead of falling back to software dimming.

### Added

- Monitors that refuse DDC/CI on the video cable are now driven over their USB
  upstream connection. Brightness, contrast, input source and the capabilities
  string all take the same path, so the controls behave the same as on a
  monitor that answers over the cable. Two bridges are supported: Realtek
  vendor HID reports, and Dell's control-transfer protocol through the monitor
  SDK that Dell Display and Peripheral Manager installs.

  **Dell Display and Peripheral Manager (DDPM) is required for the monitors
  that use Dell's control-transfer protocol**, including the Dell U2723QE.
  Great Display loads the SDK that DDPM ships at `/Applications/DDPM/DDPM.app`;
  DDPM does not have to be running, and Great Display never launches it or its
  command-line tool. Without DDPM installed, those monitors fall back to
  software dimming. The monitor's USB cable has to be connected to the Mac
  either way. Monitors with a Realtek HID bridge, and monitors that answer
  DDC/CI on the video cable normally, need neither.
- Settings and the display menu say when a monitor is being controlled over
  USB, and a monitor that refuses DDC/CI with no usable bridge now points at
  the monitor's OSD › DDC/CI setting and at DDPM instead of only reporting that
  it is unresponsive.
- `--usb-probe <displayID> <vcpHex>` prints the raw USB reply for a VCP code.

### Fixed

- A Dell monitor that returns the DDC/CI Null Message (`6E 80 BE`) on its video
  cable no longer falls back to software brightness and an unknown input. The
  Null Message is recognised as a refusal rather than a broken reply, and it is
  cached so background refreshes do not keep probing a monitor that has already
  said no. Brightness, contrast, input source and capabilities work on a Dell
  U2723QE, while monitors that answer over the video cable keep using the
  native path.
- `--ddc-diag` reports whether each port returned the Null Message and names
  the matching USB bridge.

## [1.1.1] - 2026-11-12

A reliability release. DDC controls now reach the right monitor when two are
connected, streams, mirroring and saved configurations behave across sleep,
reconnects and port changes, and the command line reports real results.

### Changed

- The development test links (`greatdisplay://stream-self-test`,
  `stream-route-test`, `association-test`, `key-test`, `probe`) are ignored
  unless switched on with
  `defaults write app.greatdisplay.GreatDisplay GDTestLinks -bool YES`. Any app
  or web page could open them, and they create virtual screens, move the
  pointer and post key presses.
- A virtual screen that connects through its association rule can no longer be
  connected or disconnected by hand (the rule undid that moments later); the
  switch and the menu item are disabled and say why.
- With combined brightness on, Settings no longer shows a separate software
  dimming slider. Moving it made the brightness slider jump, and the next touch
  dropped the backlight.
- Virtual screen sizes are scaled as a whole to the 8K/16K ceiling. The 32:9
  preset and "match a display" used to be clamped per side, which distorted
  them.
- **Reset All Saved Settings** says what it resets (everything, including
  application, menu and keyboard preferences), disconnects virtual screens and
  stops streams, and keeps track of displays that are still disconnected.
- An unknown command line option prints the list of commands and exits with
  status 2 instead of starting a second copy of the app. `--help` is new.
- `--set-brightness` only reports success when the hardware accepted the value.

### Fixed

- A DDC capabilities read could use a released service when another thread
  invalidated the monitor binding between reply fragments.
- Turning off Launch at login while approval was pending did not unregister it.
- A display ID reused by another monitor could inherit its old gamma table
  and software dimming.
- `--create-virtual` rejects non-finite or malformed hold durations before
  creating a display. Connection CLI commands refuse to run alongside the GUI
  to avoid overwriting each other's saved disconnect state.
- With two external monitors, brightness and other DDC controls could drive
  the other monitor, and the one shown got no reply. Each display's DDC channel
  was chosen by its unit number, which does not always follow the port order.
  It is now chosen by the monitor's EDID vendor, product and serial, which the
  port's framebuffer reports; the unit number only decides between ports that
  report no monitor. `--ddc-diag` shows the monitor found on each port.
- A stream that the system ended (sleep, the stop-sharing control) left its
  window over the display showing the last frame; the stream is now removed.
- Esc did not stop a stream, because the stream window could not receive key
  presses.
- "Resume on Connect" and auto-streaming restarted a stream the user had just
  stopped on any display change. A manual stop now holds until a display
  reconnects.
- A stream kept its old capture size and crop after the source changed mode in
  place (rotation, HiDPI toggle).
- A virtual screen could be bound to a real monitor's DDC/CI channel and then
  drive that monitor's brightness, volume and input. DDC services are now
  claimed per registry entry, released when unused, and freed when a monitor is
  unplugged.
- A crash when stepping the resolution of a virtual screen whose custom ratio
  had rounded one side to zero, or when `inf` was typed into a ratio field.
- A failed display configuration could be cancelled after it had already been
  completed, and reported error 0.
- Moving a mirror to another display left the previous target mirrored with no
  way to release it. Mirroring started by `--mirror` or an earlier launch can
  be stopped again (`--mirror <id> off` and the menu did nothing).
- Saved display configurations were restored to the display ID they were saved
  with, not the display they belong to, so they were skipped or applied to the
  wrong monitor after a reboot or port change.
- The brightness keys were swallowed with no effect while displays were
  mirrored or keyboard control was off for every display; they now go to macOS.
- Dimming and image adjustments are applied again after a display reconnects
  or wakes, and a colour profile changed after a resolution change is no
  longer overwritten.
- Software brightness set with the slider was not saved with the display's
  configuration; **Reset Brightness and Dimming** was not saved and could stall
  the menu on a slow monitor.
- A refused live resize of a virtual screen was treated as success.
- Deep links that launch the app (`greatdisplay://settings`) were dropped.
- Quitting through `kill` or Ctrl-C skipped reconnecting displays and
  restoring colour tables.
- Raw VCP writes of reset, input and power codes ask first, validate the value
  and refresh the controls; **Discard Virtual Screen** in the menu and
  disconnecting the main display from Settings ask first, like their
  counterparts.
- **Launch at login** showed On after registration failed.
- Command line: `--rotate` and `--stream-test` no longer crash on out-of-range
  numbers; `--ddc-write` and `--ddc-read` accept `0x` codes and reject bad
  ones; `--hdr`, `--system-colors` and `--adjust` reject invalid values and
  report failures; `--audio-output` and `--ddc-burst` no longer connect saved
  virtual screens or save test values; `--disconnect` is remembered on the
  app's next launch (the GUI must remain closed while the command runs).
- Release builds fail when the app's code signature does not verify, instead
  of being packaged anyway. CI now launches the built app.

## [1.1.0] - 2026-11-12

### Added

- **Website** at https://thienduc12311.github.io/Great-display/ with an
  interactive demo of the menu, a short product film and release notes built
  from this changelog, published to GitHub Pages by the Website workflow.

### Changed

- **Redesigned Settings window.** The sidebar now lists every display and
  virtual screen directly, with a live thumbnail, current mode and a Main
  badge, plus a search field that jumps straight to any setting. All Displays
  shows a clickable map of the desktop arrangement, quick brightness sliders
  and notices for anything that needs attention. Each display page is split
  into Picture, Color, Monitor and Options tabs, with "Looks like" resolution
  tiles and one-click color presets (Cool, Warm, Evening, Reading). Menu Bar
  settings show a live preview of the menu, Keyboard & OSD has step-size
  presets and an OSD preview, and explanations can move behind ⓘ buttons
  (General › Show explanations).

## [1.0.0] - 2026-11-12

First public release.

### Added

- **Menu bar app** with a collapsible section per display: connect switch,
  combined brightness and resolution sliders, and a "more options" level with
  feature panels. Option-click opens Settings, right-click opens a quick menu.
- **Resolutions and HiDPI**: resolution slider with Default/Native markers, a
  Display Mode list with HiDPI/LoDPI, refresh-rate and aspect-ratio filters,
  and a strict HiDPI toggle that keeps the refresh rate. Mode changes run off
  the main thread with a per-display fade.
- **Brightness** through native panel brightness on Apple displays, DDC/CI on
  external monitors and gamma-table dimming everywhere, combined into a single
  slider.
- **DDC/CI device control**: contrast, volume and mute, input source, picture
  modes, colour presets, hardware RGB gain, sharpness, standby and restore
  actions, read from the monitor's capabilities string. Raw VCP read/write in
  Settings.
- **Image adjustments** per display: gamma, colour temperature, software
  contrast, RGB gain, invert, suspend and reset.
- **Virtual screens** from aspect-ratio presets, custom ratios or a matched
  display, with about 40 sizes per ratio, live resize, optional 16K ceiling,
  mirror target, auto-start and associations with physical displays
  (auto-connect, enforced mirroring, auto-stream, orientation following).
- **Streaming** a display full-screen onto another display or onto itself, with
  pointer, scaling, crop, flip, rotation, zoom, underscan and FPS options, and
  an interactive mode that routes the pointer and keyboard through the stream.
- **Mirroring**, main display assignment, rotation, HDR toggle, logical
  connect/disconnect and display arrangement.
- **System colours**: Dark Mode, Night Shift and True Tone toggles; Prevent
  Sleep.
- **Keyboard**: brightness keys (and F14/F15) with OSD, and volume keys routed
  to DDC volume when audio goes to a DisplayPort/HDMI monitor.
- **Glass-style OSD** for brightness, contrast, volume and errors.
- **Settings window** with a Displays overview, a page per display, Virtual
  Screens, Application, Menu, Keyboard and About pages; launch at login.
- **Command line interface** (`--probe`, `--set-resolution`, `--ddc-read`,
  `--mirror`, `--self-test` and more) and `greatdisplay://` deep links.
- Universal (Apple Silicon and Intel) DMG and ZIP builds published by GitHub
  Actions.

[Unreleased]: https://github.com/thienduc12311/Great-display/compare/v1.4.0...HEAD
[1.4.0]: https://github.com/thienduc12311/Great-display/compare/v1.3.0...v1.4.0
[1.3.0]: https://github.com/thienduc12311/Great-display/compare/v1.2.0...v1.3.0
[1.2.0]: https://github.com/thienduc12311/Great-display/compare/v1.1.1...v1.2.0
[1.1.1]: https://github.com/thienduc12311/Great-display/compare/v1.1.0...v1.1.1
[1.1.0]: https://github.com/thienduc12311/Great-display/compare/v1.0.0...v1.1.0
[1.0.0]: https://github.com/thienduc12311/Great-display/releases/tag/v1.0.0
