```
 ___  ___ ___ ___ ___
/ __|/ __| _ \_ _| _ )
\__ \ (__|   /| || _ \
|___/\___|_|_\___|___/
      DESKTOP
```

# Scrib Desktop

[![License: GPL v3](https://img.shields.io/badge/License-GPLv3-blue.svg)](LICENSE)
[![Platform: Windows](https://img.shields.io/badge/Platform-Windows_10+-0078D6?logo=windows&logoColor=white)](https://github.com/beeswaxpat/scrib-desktop/releases)
[![Release](https://img.shields.io/github/v/release/beeswaxpat/scrib-desktop?color=green)](https://github.com/beeswaxpat/scrib-desktop/releases)
[![Built with Flutter](https://img.shields.io/badge/Built_with-Flutter-02569B?logo=flutter&logoColor=white)](https://flutter.dev/)

A tabbed text editor for Windows that encrypts files with AES-256. Plain text, rich text, and its own `.scrb` format. Fully offline: no network code, no telemetry, no accounts.

Built by [Beeswax Pat](https://scrib.cfd/) with [Claude](https://claude.ai) · [GNU GPL v3](LICENSE)

**[Download](https://github.com/beeswaxpat/scrib-desktop/releases)** · **[Changelog](CHANGELOG.md)** · **[Architecture](ARCHITECTURE.md)** · **[Security](SECURITY.md)**

---

![Scrib Desktop: multi-tab, rich text, encrypted. Three tabs open with encryption active.](screenshot.png)

![Scrib Desktop: rich text mode with dark theme, showing formatted notes in the editor.](screenshot-richtext.png)

---

## Features

**Editing.** Plain text and rich text per tab (`Ctrl+M`). Bold, italic, underline, strikethrough, sub/superscript, headings, bullet and numbered lists, checklists, block quotes, alignment, indent, text colors and highlights. 14 system fonts, sizes 8 to 72.

**Embeds.** Insert images (PNG, JPEG, GIF, WebP, BMP, SVG, TIFF, TGA, ICO, PSD and more) and tables up to 8 by 10. Both are stored inside the note, so in a `.scrb` they are encrypted with the text. Images sit inline: type beside them, align them, resize on hover.

**Tabs.** Multi-tab with inline rename, per-tab accent colors, middle-click close, right-click menu (Close Others, Close to the Right, Close All), full-path tooltips, `Ctrl+1` to `Ctrl+9` jumps, and reopen-closed (`Ctrl+Shift+T`).

**Search.** Find (`Ctrl+F`) with match-case and whole-word. Find and Replace (`Ctrl+H`) operates on exact document positions, so notes containing images or tables are not corrupted. Search across all open tabs (`Ctrl+Shift+F`), including table cell text. Go to line (`Ctrl+G`).

**Files.** Open `.txt`, `.scrb`, `.rtf`, `.md`, `.log`, `.csv`, `.json`, `.xml`, `.yaml`, `.yml`, `.ini`, `.cfg`. Save as `.txt`, `.scrb`, `.rtf`. Drag and drop from Explorer, including multi-file drops. RTF import and export round-trips bold, italic, colors, fonts, sizes, lists, checklists, headers, quotes, links, and sub/superscript through Word and WordPad.

**Save safety.** Writes are atomic, so a crash mid-save cannot truncate a file. Scrib asks before replacing a file you did not pick, before overwriting a file another program changed while it was open, and before writing over a note another tab already has open. A save that is refused leaves the tab unsaved rather than reporting success.

**Encryption.** Toggle per tab with `Ctrl+E`. Lock a tab (`Ctrl+L`) to save it and wipe the decrypted content and password from the tab. Optional auto-lock after 1, 5, or 15 minutes idle (off by default). Change Password re-encrypts in place. Key derivation runs in a background isolate.

**Workspace.** Session restore reopens last session's tabs at launch, with encrypted files restored locked so startup never prompts for a password. Command palette (`Ctrl+Shift+P`). Auto-save every 30 seconds. Dark, light, and system themes. Built-in calculator that uses a hand-written parser, not `eval`.

Press `F1` in the app for the full keyboard shortcut reference.

---

## Keyboard Shortcuts

| Shortcut | Action | Shortcut | Action |
|---|---|---|---|
| `Ctrl+N` / `Ctrl+O` | New tab / Open | `Ctrl+F` / `Ctrl+H` | Find / Replace |
| `Ctrl+S` / `Ctrl+Shift+S` | Save / Save As | `Ctrl+Shift+F` | Search all tabs |
| `Ctrl+W` / `Ctrl+Shift+T` | Close / Reopen tab | `F3` / `Shift+F3` | Find next / previous |
| `Ctrl+Tab` / `Ctrl+Shift+Tab` | Next / Previous tab | `Ctrl+G` | Go to line |
| `Ctrl+1`..`Ctrl+8` / `Ctrl+9` | Go to tab / last tab | `Ctrl+E` / `Ctrl+L` | Encrypt / Lock |
| `Ctrl+M` | Plain / rich text | `Ctrl+Shift+P` | Command palette |
| `Ctrl+B` / `Ctrl+I` / `Ctrl+U` | Bold / Italic / Underline | `Ctrl+K` | Insert or edit link |
| `Ctrl+Shift+8` / `7` / `9` | Bullet / Numbered / Checklist | `Ctrl+=` / `Ctrl+-` / `Ctrl+0` | Text size |

---

## Building from Source

Requires [Flutter](https://flutter.dev/) 3.38.6 (the version CI builds and releases on), Windows 10 or later, and Visual Studio 2022 with the **Desktop development with C++** workload.

```bash
git clone https://github.com/beeswaxpat/scrib-desktop.git
cd scrib-desktop
flutter pub get
flutter run -d windows                    # debug
flutter build windows --release           # release
```

Output: `build\windows\x64\runner\Release\scrib_desktop.exe`

32 Dart files, roughly 14,500 lines, covered by 613 tests. See [ARCHITECTURE.md](ARCHITECTURE.md) for the module map, the load-bearing invariants, and save-path routing.

---

## Encryption

Encrypt-then-MAC with AES-256-CBC and HMAC-SHA256.

| Component | Detail |
|---|---|
| Key derivation | PBKDF2-SHA256, 64-byte output (32 encryption + 32 MAC). v2: fixed 100,000 iterations. v3: iteration count stored per file, so it can be raised later without breaking existing files. |
| IV / salt | 16 and 32 bytes, from `Random.secure()`, regenerated on every save |
| HMAC | SHA-256 over `version ‖ KDF params ‖ IV ‖ salt ‖ ciphertext`, verified before any decryption. Because the KDF parameters are authenticated, a downgrade is rejected. |
| Atomic writes | `MoveFileExW` on Windows, so a crash during a save cannot corrupt the file |

```
v3 (current): [SCRB 4B][version=3 1B][kdfId 1B][iterations u32-BE 4B][IV 16B][salt 32B][HMAC 32B][ciphertext...]
v2 (legacy):  [SCRB 4B][version=2 1B][IV 16B][salt 32B][HMAC 32B][ciphertext...]
```

New files are written as v3. Every v2 file is still read through a preserved code path, so upgrading never strands a file.

### Threat model

**Scrib defends against:**

- Someone reading your `.scrb` files without the password
- Tampering: the HMAC covers the version byte, KDF parameters, IV, salt, and ciphertext
- Corruption during a save, via atomic rename
- Crafted `.scrb` headers: the per-file iteration count is capped at 2,000,000 on read, so a hostile file cannot stall the app with an arbitrary work factor

**Scrib does not defend against:**

- **A compromised machine.** A key-logger, RAM dump, or malicious build can recover the password while a file is open. Passwords are held as Dart `String`s, which are immutable and cannot be securely zeroed, so a password may remain in the heap until garbage collection. Windows hibernation and paging can write that memory to disk.
- **Weak passwords.** PBKDF2 at 100,000 iterations raises the cost of an offline guess but does not make one infeasible. Use a long, high-entropy password.
- **Filename and path disclosure.** Recent files, session state, window position, and default save location are stored in a plaintext Hive database under `%APPDATA%`. Your note contents are encrypted; their names and paths are not. Hive appends rather than rewrites, so clearing recent files does not immediately erase earlier entries from that database.
- **Recovery of a plaintext file you later encrypted.** Encrypting an existing `.txt` or `.rtf` writes the `.scrb`, overwrites the original's bytes, and then deletes it (1.10.0 and later; earlier versions deleted without overwriting, which left the plaintext readable in free space). Overwriting is best effort by nature: on an SSD the controller may write elsewhere, and a backup, filesystem snapshot, or synced folder can hold a copy Scrib never sees. For notes that must never exist in plaintext, create the note encrypted rather than converting one.
- **A substituted download.** Release binaries are not code-signed, and the published SHA-256 is generated by the same workflow that builds the artifact, so it detects transfer corruption but not a compromised release. Build from source if you need stronger assurance.
- **Hostile note files.** Opening a `.scrb`, `.rtf`, or other document supplied by someone else parses untrusted input. There is no sandbox around that parsing.

---

## Contributing

PRs welcome. See [CONTRIBUTING.md](CONTRIBUTING.md).

Ground rules: no tracking or network calls, no weakening the encryption or key derivation, and read [ARCHITECTURE.md](ARCHITECTURE.md) before touching a save path. `flutter analyze` must report zero issues and `flutter test` must pass.

Report security issues privately through the repository's Security tab. See [SECURITY.md](SECURITY.md).

## License

GNU General Public License v3.0, see [LICENSE](LICENSE). You may use, modify, and distribute this software under the terms of the GPL. Modified versions you distribute must also be open source under the GPL.

---

*No tracking. No cloud. Just notes.*
