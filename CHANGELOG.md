# Changelog

All notable changes to Scrib Desktop are documented here.
The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/).

## [1.2.0] — 2026-04-17 — Hardening pass

This release is a correctness / safety / maintainability pass. **The `.scrb`
file format and Hive settings schema are unchanged** — existing encrypted
files decrypt identically, and all your settings (window position, recent
files, fonts, theme) survive the upgrade.

### Added
- **Windows-atomic file saves** via `MoveFileExW(MOVEFILE_REPLACE_EXISTING | MOVEFILE_WRITE_THROUGH)`.
  Saves can no longer leave orphaned `.tmp` files or fail silently over existing files.
- **Crash recovery**: any `.bak` / `.tmp` files from an interrupted save are
  cleaned up or restored automatically on next launch.
- **Mode-toggle revert**: switching Plain ↔ Rich shows a SnackBar with a
  **Revert** action that restores the previous content in one click (within
  the current session, until the tab is saved).
- **Extension-change notification**: toggling encryption now surfaces a
  SnackBar whenever it causes a rename (`.scrb` ↔ `.txt`/`.rtf`) instead of
  silently moving files.
- **Overwrite confirmation** when renaming a tab onto an existing file.
- **Accessibility**: `Semantics` widgets on all icon-only buttons (toolbar,
  search, tab close, formatting, new-tab) for Windows Narrator.
- **65 unit tests** covering AES round-trip, HMAC tamper detection,
  atomic-write crash recovery, RTF conversion, tab management, mode revert,
  and settings persistence.
- **GitHub Actions CI** (`.github/workflows/flutter.yml`) runs analyze +
  test + Windows release build on every push and PR.
- **Threat-model section** in the README covering what Scrib does and does
  not defend against.

### Changed
- **Find & Replace preserves undo history** — Replace / Replace All now use
  `TextEditingValue` instead of overwriting `controller.text`, so Ctrl+Z
  undoes each replacement individually.
- **Theme memoization**: `ScribTheme.darkTheme` / `lightTheme` are cached by
  accent index, removing per-keystroke `ThemeData` allocations.
- **Colors** centralized into a `ScribColors` theme extension (removes ~8
  hex literals duplicated across widgets).
- `main_screen.dart` slimmed from 1,256 → 574 lines — dialogs moved to
  `lib/dialogs/`, save/save-as decision tree moved to
  `lib/services/file_operations.dart`.
- `RtfService` is now stateless with static methods (no need to instantiate
  per save).
- Exception messages in SnackBars no longer expose internal library
  exception details.

### Fixed
- **`setState` after `await`** is now `mounted`-guarded everywhere, preventing
  crashes when the window closes during an encrypt/decrypt operation.
- **Tab-index staleness** after async rename / close: every such operation
  re-looks-up the tab by identity instead of by the (possibly-shifted) index
  it captured at the start.
- Auto-save failures are now logged in debug builds (still silent in release
  — behavior unchanged for users).

### Removed
- `encrypt` package (used `pointycastle` directly — byte format identical).
- Unused `hive_generator` and `build_runner` dev dependencies.

### Security
- Version byte sourced from `scrbVersionV2` constant rather than a magic
  number, reducing the risk of a future version bump forgetting to update
  the HMAC-auth construction.

## [1.1.0] — 2026-02-16

Initial open-source release.
