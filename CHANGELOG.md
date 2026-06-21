# Changelog

All notable changes to Scrib Desktop are documented here.
The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/).

## [1.3.0] — 2026-06-20 — Data-integrity & format hardening

A correctness / safety pass focused on data loss, an encryption-downgrade bug,
RTF fidelity, and a self-describing encrypted-file format. **Every existing
`.scrb` file still decrypts** — v2 files are read by a preserved v2 code path.
Files saved by 1.3.0 use the new v3 format and require 1.3.0 or later to open.

### Security / data integrity
- **Encryption-downgrade fix.** Reopening an already-open encrypted tab no
  longer leaves it flagged as plaintext, which previously could cause the next
  save to write the decrypted contents to disk **unencrypted**. Now covered by
  a regression test.
- **Crash-recovery no longer touches your files.** Recovery previously deleted
  *any* `*.tmp` and rewrote *any* `*.bak` in the save folder. Staging/backup
  files now use Scrib-specific suffixes (`.scrib-tmp` / `.scrib-bak`), and a
  backup is kept (not discarded) when the primary looks truncated.
- **`.scrb` v3 format with self-describing, authenticated KDF parameters.** The
  PBKDF2 iteration count and KDF id are now stored in the header and covered by
  the HMAC, so the work factor can be raised in a future release without
  breaking any existing file and a tampered parameter is rejected before key
  derivation is trusted. (The default count is unchanged for now; raising it is
  a one-line change once per-session key caching lands.)
- **Per-destination write serialization.** Overlapping saves to the same file
  (rapid Ctrl+S, auto-save racing a manual save) can no longer interleave.

### Fixed
- **Auto-save no longer corrupts `.rtf` files.** Rich-text `.rtf` tabs are now
  auto-saved as real RTF instead of having the internal `scrib_rich` JSON
  envelope written into them.
- **RTF non-ASCII round-trip.** `\uN` escapes are now emitted as signed 16-bit
  values (so CJK and astral characters such as emoji are no longer corrupted),
  surrogate pairs are handled, `\uN` is decoded on import, `\ul0` is honored as
  "underline off", and `\'XX` bytes are mapped through the Windows-1252 table.
- **Malformed Delta no longer throws** during RTF export — it falls back to
  escaped plain text.

### UX
- **Save & Quit.** Closing the window with unsaved changes now offers to save
  everything first; it refuses to quit if any tab still needs a filename or
  password rather than silently discarding work.
- **Dirty untitled tabs prompt before closing** instead of being dropped
  silently.
- Drag-and-drop now filters unsupported files and folders with a clear message.

### Internal / quality
- Password dialogs are now `StatefulWidget`s that own and dispose their
  controllers and focus nodes (no per-keystroke `FocusNode` leak).
- `MoveFileExW` pointers are freed with the matching allocator.
- Font-size limits and the custom-size dialog are unified on the shared
  constants; the duplicate toolbar dialog was removed.
- **Test suite grown from 65 to 200+** covering the v2/v3 crypto matrix,
  atomic-write recovery (including false-positive guards), RTF fidelity, the
  save/save-as decision tree, settings, and widget behavior.
- Added `SECURITY.md` with a private vulnerability-disclosure policy.

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
