# Changelog

All notable changes to Docklane are listed here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and the project uses
[Semantic Versioning](https://semver.org/).

## [Unreleased]

### Added

- C in the window switcher minimizes every window of the selected app to the Dock (full-screen
  windows leave full screen first). H (hide) is gone
- Live pins: Pin Live Preview (panel menu) keeps a live, always-on-top copy of a window on every
  desktop (10 frames a second; once a second for a window on another desktop), up to four
- App rules (Settings → Workspaces): new windows of an app are placed as soon as they open
  (left / right / top / bottom half, center, fill); windows open when Docklane starts are left alone
- Arrange the front window from the keyboard: ⌃⌥←/→/↑/↓ halves, pressing again cycles to a
  third and two thirds; ⌃⌥↩ fill, ⌃⌥C center, ⌃⌥⌘←/→ to the other display (same place, scaled).
  Respects the strip a pinned panel keeps clear; ⌃⌥Z undoes; can be turned off
- Window memory. Workspaces get a shortcut each (⌃⌥⌘1–9), remember which display every
  window was on (and where on it, so they fit another resolution or the laptop screen), wait
  for apps they open to show their windows, and can hide every other app. Docklane also
  remembers the layout of each set of displays and puts windows back when a display is
  connected or disconnected. ⌃⌥Z undoes the last layout change (workspace, display change,
  Move & Resize). Moving windows to another desktop is not possible on current macOS
- Desktop switcher on ⌥Tab: every desktop and full-screen space as a miniature (wallpaper
  with its windows where they are, or the full-screen app), in Mission Control order. Hold ⌥,
  Tab to move, release to go; 1–9 jump straight to one. The first press selects the desktop
  used last, so a quick ⌥Tab toggles between two. Docklane lands on the window last used
  there; an empty desktop is reached with your own Mission Control shortcut (⌃1… or ⌃←/⌃→).
  ⌃⌥Tab when the window switcher uses ⌥Tab; can be turned off in Settings
- ⌘` / ⌘⇧` move through the switcher and ⌘. cancels it, as in the system switcher

### Changed

- No animation anywhere: hovering a tile enlarges it instantly (it used to ease in over 0.12 s)
- Lower background load: audio and Dock badges are read only while the panel or a switcher is
  on screen, the safety-net scan runs every 6 s instead of 2 s when nobody looks, focus changes
  no longer capture thumbnails in the background, and pointer movement away from the panel does
  no work. Measured over 15 s: 63 → 16 ms in scans, 42 → 0 ms audio, 13 → 0 ms badges,
  66 → 0 ms drawing, 15 → 1 ms pointer handling
- Minimizing a full-screen window is faster (0.66 → 0.47 s)
- The window and desktop switchers look like the panel: Liquid Glass on macOS 26 (frosted
  before), cards filled by the live thumbnail with the app icon on the corner and the title in a
  pill, a glowing ring for the selection, and a quieter key hint with the keys in bold
- Tiles sit 4 pt from the screen edge, like the Dock (was 16 pt); the far side keeps room
  for shadows, and the app icon's overhang is kept clear on the left and bottom edges
- In a full-screen space, where the menu bar is hidden, a top panel sits at the very top of
  the screen instead of below the empty menu bar area
- Search in the window switcher is now ⌘F (press F while holding ⌘), the macOS Find
  shortcut, on every keyboard layout; "/" still works
- The window switcher is only as wide as its cards, centred, with no empty columns
- The switcher's keyboard hint wraps to up to three lines, breaking only between shortcuts
- v0.1.0 is now signed with a Developer ID and notarized; no Open Anyway step

### Fixed

- M in the window switcher (and Minimize in the panel menu) works on full-screen windows:
  they leave full screen first, then go to the Dock (macOS won't minimize them directly)
- A panel on the top edge opens every time the pointer is pushed to the top: the topmost
  pixels above the panel count too (the thin strip below the menu bar was easy to skip),
  after a 0.15 s pause so menus stay usable
- An app that stopped responding no longer freezes Docklane: focusing one of its windows
  gives up within half a second (measured 0.52 s) and app notifications use a short timeout
- The window switcher no longer gets stuck open when the ⌘ release is missed; it checks the
  key itself while open
- Q/H/W/M in the switcher only act while ⌘ is held; a key typed after a missed release
  switches and goes to the app instead of quitting or closing something
- Switcher shortcuts follow the keyboard layout: Q/H/W/M are the real letters on AZERTY,
  Turkish F, Dvorak and while a Cyrillic layout is on
- Clicking another app while searching closes the switcher instead of keeping the keyboard
- Focusing and quitting from the switcher run after the key event is released to the system
- One ⌘Tab press now selects the next app; the window you are in is always first and is
  read live when the switcher opens
- Clicking a window sometimes brought only its app forward instead of that exact window;
  focus is now checked and retried once
- Clicking a window of a hidden app (⌘H) now unhides the app
- Choosing a window whose app has quit hands focus back instead of leaving it on Docklane
- Closed windows that the system still reports on no desktop no longer show as ghost tiles
- Windows with the same title (two "New Incognito Tab", two Terminal windows) on another
  desktop are no longer merged into one tile
- A window assigned to all desktops counts as being on the current one
- Thumbnails of apps that quit are released (memory no longer grows over time)
- Thumbnails are captured only as large as a tile or switcher card shows them, and
  CoreGraphics no longer keeps converted copies: memory stays flat after hundreds of windows
- `Scripts/build-app.sh` stops instead of installing an ad-hoc signed copy when the signing
  identity is missing (that broke permissions); `ADHOC=1` allows it

## [0.1.0] — 2026-10-11

First version.

### Added

- Edge panel with live thumbnails of every window on every desktop, including full-screen spaces;
  click to focus that exact window
- Keep apps in the panel, group by app, drag to reorder, rename windows, drop files on a thumbnail
- Dock badges, audio chip, desktop / full-screen chip, focus ring, dimmed minimized windows
- Right-click menu with New Window, Arrange (halves, center, fill), Minimize / Restore, Hide,
  Close, Quit
- Left, top, bottom or right edge, size slider, optional background, one panel per display
- Auto-hide, or keep the panel visible and move windows out of its way
- Large live preview on hover, "only this desktop" filter, keyboard navigation (⌃⌥K) and a
  show/hide shortcut (⌃⌥D)
- ⌘Tab (or ⌥Tab) window switcher in most-recently-used order with `/` search and Q / H / W / M
  actions
- Workspaces: save and restore the set of open windows
- Privacy blur, menu bar quick controls, launch at login, onboarding for permissions
- 11 languages with an in-app language choice: English, Chinese (Simplified), Hindi, Spanish,
  Arabic, French, Bengali, Portuguese, Russian, Indonesian and Turkish
- App icon and a matching menu bar glyph

[Unreleased]: https://github.com/mertdurukan/docklane/compare/v0.1.0...HEAD
[0.1.0]: https://github.com/mertdurukan/docklane/releases/tag/v0.1.0
