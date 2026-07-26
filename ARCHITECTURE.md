# Scrib Desktop Architecture

Contributor-facing map of the codebase: where things live, which invariants are
load-bearing, and how a document gets from memory to disk. Read this before
touching any save path or the encryption code.

## Module layout

```
lib/
  main.dart                  App entry: window_manager setup, Provider wiring,
                             crash recovery (AtomicWrite.recoverIfNeeded),
                             quit flow (saveAllSaveable backstop)
  constants.dart             Brand constants, .scrb magic bytes, crypto
                             parameters, UI constants
  providers/
    editor_provider.dart     Multi-tab state (EditorTab), background save
                             routing (_saveTabToDisk), tab locking, session
                             restore, word/char/line counts
  services/                  UI-free logic, unit-testable without a widget tree
    atomic_write.dart        Windows atomic rename via MoveFileExW (dart:ffi)
                             with crash-safe fallback and .scrib-bak recovery
    file_service.dart        .txt / .rtf / .scrb I/O; AES-256-CBC + HMAC-SHA256
                             (Encrypt-then-MAC, pointycastle)
    file_operations.dart     Manual save / save-as decision tree, including the
                             encryption-toggle extension swap
    rtf_service.dart         Delta JSON to RTF and back
    settings_service.dart    Hive-backed settings, session snapshot storage
    table_embed.dart         ScribTable model + JSON codec for table embeds
    image_embed_service.dart Image picking, normalization, data-URI codec,
                             bounded decode cache
    format_utils.dart        Link allowlist (normalizeLinkUrl, isSafeLaunchUrl),
                             list-toggle resolution
    calc_evaluator.dart      Calculator expression parser/evaluator
    fuzzy_matcher.dart       Command palette matching
  screens/
    main_screen.dart         Menu bar, keyboard shortcuts, drop target, close
                             and quit prompts
  widgets/
    editor_widget.dart       Plain TextField or QuillEditor per tab, keyed by
                             tab identity; launch-time link gate
    search_bar_widget.dart   Per-tab find and replace
    global_search_widget.dart Search across all open tabs
    tab_bar_widget.dart      Tab strip with rename, colors, scrollbar
    toolbar_widget.dart      File ops, mode toggle, fonts, theme
    formatting_toolbar_widget.dart Rich-text formatting buttons
    table_embed_builder.dart / image_embed_builder.dart Embed renderers
    command_palette.dart     Ctrl+Shift+P action palette
    status_bar_widget.dart   Counts, mode, encryption state, Ln/Col
  dialogs/                   Password, link, confirm, calculator, shortcuts,
                             about dialogs
  theme/                     Dark and light themes, ScribColors extension
```

Dependency direction: `widgets/screens -> providers -> services`. Services never
import widgets. One deliberate exception on providers: `file_operations.dart`
imports `EditorProvider`, because it drives the provider through the manual
save flow; every other service is provider-free.

## Load-bearing invariants

Breaking any of these corrupts or leaks user data. Each has regression tests,
with two known coverage gaps: the launch-time link gate is tested as a pure
function (`format_utils_test.dart`) but not at its call site in
`editor_widget.dart`, and no test asserts that `FileService` routes its writes
through `AtomicWrite` rather than writing files directly.

1. **Locked tabs are never written.** `EditorTab.isLocked` means the decrypted
   content and password are NOT in memory; the in-memory document is empty by
   design. Every save path must refuse a locked tab, otherwise an empty
   document overwrites the encrypted file on disk. Enforced in
   `EditorProvider._saveTabToDisk`, `saveActiveTab`, `saveActiveTabAs`,
   `markTabSavedAs`, `changeActivePassword`, `updateDeltaJson`,
   `EditorTab.markSaved`, and both `FileOperations` entry points. `markSaved`
   needs its own check because a lock can land while a write is still in
   flight, and the snapshot it would apply holds the decrypted note.

2. **All writes are atomic.** Every file write goes through
   `AtomicWrite` (write to `<path>.scrib-tmp`, backup to `<path>.scrib-bak`,
   MoveFileExW rename). A crash mid-save must never leave a truncated or
   half-encrypted file. Crash recovery restores stranded `.scrib-bak` files on
   launch and lazily on read. Only Scrib-namespaced suffixes are touched, so
   unrelated user `.tmp` / `.bak` files are never affected.

3. **Encrypted bytes only in .scrb; plaintext never in .scrb.** A `.scrb` file
   on disk contains ciphertext, always. The reachable danger state: Ctrl+E
   flips `EditorTab.isEncrypted` without touching `filePath`. Background saves
   (auto-save, save-all) must refuse any encryption/extension mismatch in
   either direction and leave the tab dirty. Only the manual save path
   performs the extension swap (`.scrb <-> .txt/.rtf`): `saveActive` for an
   in-place save, and `saveAs` when it forces a `.scrb` onto a path the user
   typed without one. Both ask before replacing an existing file at the
   destination, and `saveActive` notifies the user after the swap.

4. **Extension-mode matching in save routing.** A rich-text Delta must not be
   written verbatim into a `.txt` (the scrib_rich JSON envelope would corrupt
   it) and a plain-mode tab must not be written into a `.rtf` (a headerless
   file is rejected by Word/WordPad). A Delta that carries image or table
   embeds is never converted to RTF without explicit confirmation, because RTF
   conversion drops embeds; auto-save defers such writes.

5. **flutter_quill stays pinned at 11.5.0.** Embed mechanics (custom block
   embeds carrying JSON strings, `unknownEmbedBuilder`, the shortcut-collision
   workaround in `editor_widget.dart`, document change streams) are verified
   against this exact version. Quill upgrades have changed embed and shortcut
   behavior between minor versions; an upgrade requires re-running the full
   test suite plus manual verification of tables, images, links, and every
   documented shortcut inside a rich tab. `pubspec.yaml` declares the exact
   version (`flutter_quill: 11.5.0`, no caret), so the pin holds at resolution
   and not only in `pubspec.lock`, and `.github/dependabot.yml` ignores the
   package so no automated PR crosses it. The CI Flutter version is pinned in
   lockstep (see `.github/workflows/*.yml`).

6. **Link allowlist at BOTH ends.** Only `http`, `https`, and `mailto` URLs
   exist in Scrib documents. `normalizeLinkUrl` gates what the link dialog will
   store. `isSafeLaunchUrl` gates what Ctrl+click will launch, and it must
   stand alone because a crafted `.scrb` or `.rtf` can carry any link
   attribute without ever passing through the dialog. RTF import applies the
   same scheme restriction to HYPERLINK fields. Both gates reject raw
   whitespace and control characters anywhere in the URL.

7. **Note files stay backwards compatible.** `.scrb` v2 files (fixed 100k
   PBKDF2 iterations) still decrypt through the version-byte branch; new saves
   write v3 (KDF parameters in the header, authenticated by the HMAC, with an
   iteration ceiling against crafted headers). Plaintext files that older
   builds wrote with a scrib_rich envelope still hydrate as rich text.

## Save-path routing

There is no single write function. Note content reaches disk through four
writers (`_saveTabToDisk`, `saveActiveTabAs`, `changeActivePassword`, and the
Delta-to-RTF writes `FileOperations` makes directly), plus the two bookkeeping
calls that record what was written (`markSaved`, `markTabSavedAs`). Each one
carries a different part of the invariants above. Read this list before adding
a fifth writer.

**`EditorProvider._saveTabToDisk`** is the background writer: auto-save, the
quit backstop, the pre-lock save, and the in-place branch of the manual save
all go through it. When the tab's state and the path's extension disagree it
refuses (returns null, writes nothing) instead of adapting; changing the path
to fit is the manual path's job alone. It takes the content snapshot BEFORE
the first await and returns
that `SavedContent` on success, so every routing decision, the bytes written,
and what the tab is later marked clean against all agree with each other.

**`EditorTab.markSaved(written)`** records the snapshot a completed write put
on disk, not the live controller. It used to read the live content, so an edit
typed during a save (an encrypted write is an isolate spawn plus PBKDF2 plus
two flushed writes, well over 100ms) was marked clean and never reached disk:
no dirty marker, no quit prompt, no backup. It returns early on a locked tab,
because the snapshot holds the decrypted note and applying it would undo
`lock()`'s wipe.

**`EditorProvider.saveActiveTabAs`** writes to a path the caller chose, then
rebinds the tab's `filePath`, `fileName`, `isEncrypted` and `password` to that
write. The destination extension and any overwrite confirmation belong to the
caller (`FileOperations`, or the untitled branch of `MainScreen._renameTab`),
not to this method.

**`EditorProvider.markTabSavedAs`** performs no write of its own: it records a
write `FileOperations` already made through `FileService.writeRtfFile`, since
the Delta-to-RTF conversion lives in the caller. It takes the target tab as an
argument instead of reading `activeTab`, because the caller awaits dialogs and
the write itself and the user can switch tabs meanwhile; resolving the target
afterwards retargeted whichever tab happened to be active and dropped its
password.

**`EditorProvider.changeActivePassword`** re-encrypts in place through
`FileService.writeScrbFile`. It is the only `writeScrbFile` caller outside
`_saveTabToDisk`, so it repeats the `.scrb` path test itself (`hasScrbPath`),
and it assigns `EditorTab.password` only after the write succeeds: with the
old ordering, a failed write left the tab holding a password the UI had just
said was not applied, and the next save silently re-keyed the file.

**`FileOperations.saveActive` / `saveAs`** own the manual path. They are the
only code allowed to change a file's extension, and every swap goes through
the `confirmOverwrite` callback first, which fails closed: with no callback
wired, the swap is refused rather than replacing a file the user never chose.
Each swap branch also deletes the pre-swap original, so an unguarded swap
would destroy two files. `saveAs` re-asks when it retargets the picker's path
to `.scrb`, because the native replace prompt applied to a path that is no
longer the destination.

```
User action                     Route                              Refusal behavior
-----------------------------   --------------------------------   -----------------
Ctrl+S (manual save)            MainScreen._saveFile
                                  -> FileOperations.saveActive     Only path allowed to
                                     -> _saveTabToDisk (in place)   swap extensions; asks
                                     -> saveActiveTabAs (swap)      before replacing a
                                     -> writeRtfFile +              file and before a
                                        markTabSavedAs (RTF)        lossy Delta->RTF write

Ctrl+Shift+S (Save As)          MainScreen._saveFileAs
                                  -> FileOperations.saveAs         Reports failure
                                     -> saveActiveTabAs             instead of marking
                                     -> writeRtfFile +              the tab clean
                                        markTabSavedAs (RTF)

Auto-save timer                 EditorProvider._autoSaveAll
                                  -> _saveDirtyFileBackedTabs      Refuses mismatches;
                                     -> _saveTabToDisk              tab stays dirty and
                                                                    waits for manual save

Close tab (dirty, chose Save)   MainScreen._closeTabByIndex
                                  -> same flow as Ctrl+S           Tab stays open if
                                                                    the save is refused
                                                                    or canceled

Quit                            main.dart onWindowClose
                                  -> saveAllSaveable               Refuses to discard
                                     -> _saveTabToDisk per tab      dirty untitled or
                                                                    passwordless tabs;
                                                                    prompts instead

Lock tab (Ctrl+L / auto-lock)   EditorProvider.lockTab
                                  -> _saveTabToDisk first          Any save failure
                                                                    keeps the tab
                                                                    UNLOCKED so edits
                                                                    survive in memory;
                                                                    isDirty is re-checked
                                                                    AFTER that save, so
                                                                    text typed while it
                                                                    was in flight also
                                                                    blocks the lock

Change Password                 MainScreen._changePassword
                                  -> changeActivePassword         Refuses a non-.scrb
                                     -> FileService.writeScrbFile   path; keeps the old
                                                                    password when the
                                                                    write throws

Rename tab (file-backed)        MainScreen._renameTab
                                  -> File(old).rename(new)        Asks before replacing
                                     -> updateTabFile               an existing file

Rename tab (untitled)           MainScreen._renameTab
                                  -> saveActiveTabAs              Writes into the
                                                                    default save location
                                                                    under the new name
```

`_saveTabToDisk` (background writes) refuses: no path, locked tab, encrypted
without a password, encryption/extension mismatch, rich Delta over `.txt`,
plain mode over `.rtf`, and embed-carrying Delta over `.rtf`. Refused tabs stay
dirty so the quit backstop keeps refusing to discard them.

## .scrb format

See `CLAUDE.md` and `file_service.dart` for the byte layout. Summary: magic
`SCRB`, version byte, KDF id + iteration count (v3), IV, salt, HMAC-SHA256 over
the authenticated fields, then AES-256-CBC ciphertext. Encrypt-then-MAC with a
constant-time compare before any decryption. Key derivation is PBKDF2-SHA256
with a per-file work factor and a hard iteration ceiling on read.

## Testing conventions

- `flutter test` runs the whole suite; it must stay green and fast (well under
  a minute). CI runs analyze (fatal infos/warnings) + tests on every push/PR.
- Services are tested headless (plain `test`). Widget behavior is tested with
  `testWidgets` harnesses that mount the real `EditorProvider` +
  `SettingsService` via Provider (see `editor_widget_identity_test.dart`,
  `global_search_widget_test.dart` for the pattern).
- Settings/Hive tests use `SettingsService.initForTests(tempDir)` and close
  Hive in tearDown.
- Real file I/O inside `testWidgets` must run under `tester.runAsync` (the
  FakeAsync zone never completes real IO futures).
- Every invariant fix lands with a regression test that fails on the old code.
  Tests assert user-visible behavior (file bytes on disk, tab state), not
  implementation details.
- Hostile-input tests (crafted headers, huge embed dimensions, invalid UTF-8,
  scheme-smuggling URLs) live next to the codec they attack: see
  `crypto_v3_kdf_test.dart`, `table_embed_test.dart`, `format_utils_test.dart`.
