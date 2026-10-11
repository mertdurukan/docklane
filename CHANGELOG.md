# Changelog

All notable changes to Docklane are listed here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and the project uses
[Semantic Versioning](https://semver.org/).

## [Unreleased]

### Changed

- The window switcher is only as wide as its cards, centred, with no empty columns
- The switcher's keyboard hint wraps to up to three lines, breaking only between shortcuts
- v0.1.0 is now signed with a Developer ID and notarized; no Open Anyway step

### Fixed

- A panel on the top edge opens every time the pointer is pushed to the top: the topmost
  pixels above the panel count too (the thin strip below the menu bar was easy to skip),
  after a 0.15 s pause so menus stay usable
- An app that stopped responding no longer freezes Docklane: focusing one of its windows
  gives up within half a second (measured 0.52 s) and app notifications use a short timeout
- The window switcher no longer gets stuck open when the ⌘ release is missed; it checks the
  key itself while open
- Q/H/W/M in the switcher only act while ⌘ is held; a key typed after a missed release
  switches and goes to the app instead of quitting or closing something
- Switcher shortcuts follow the keyboard layout: "/" search works on Turkish Q (⇧7), and
  Q/H/W/M are the real letters on AZERTY, Turkish F, Dvorak and while a Cyrillic layout is on
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
