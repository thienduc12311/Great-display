# Changelog

All notable changes to Great Display are recorded here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and the project uses
[Semantic Versioning](https://semver.org/).

Each release's notes on GitHub are taken from its section below, so add your
change under **Unreleased** in the same pull request.

## [Unreleased]

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

[Unreleased]: https://github.com/thienduc12311/Great-display/compare/v1.1.0...HEAD
[1.1.0]: https://github.com/thienduc12311/Great-display/compare/v1.0.0...v1.1.0
[1.0.0]: https://github.com/thienduc12311/Great-display/releases/tag/v1.0.0
