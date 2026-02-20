# Scrib Desktop

**The encrypted desktop editor.** Plain text, rich text, and `.scrb` — all fully offline, zero tracking.

Built by [Beeswax Pat](https://scrib.cfd/) &middot; Copyright &copy; 2026 Beeswax Pat &middot; Licensed under the [GNU GPL v3](LICENSE)

---

## Features

- **Plain text & rich text** — switch per-tab at any time
- **AES-256-CBC encryption** with PBKDF2 (100,000 iterations) + HMAC-SHA256 authentication
- **`.scrb` file format** — Scrib's own encrypted container; open only with the right password
- **RTF import/export** — open `.rtf` files from Word or LibreOffice; export back
- **Multi-tab editing** — tabs with per-tab accent colors, inline rename, middle-click close
- **Find & Replace** — works in both plain text and rich text mode
- **Auto-save** — silently saves all dirty tabs on a configurable timer (View > Auto-Save)
- **Rich text formatting** — bold, italic, underline, strikethrough, font family/size, text/highlight colors, headings, bullet & numbered lists, block quotes, alignment, indent
- **Line numbers** — optional gutter for plain text mode
- **Drag & drop** — drop files directly onto the window to open them
- **Dark, light, and system themes** with accent color selection
- **Persistent window geometry** — remembers size and position between sessions
- **No cloud. No accounts. No telemetry. Your files stay on your machine.**

---

## Supported File Types

| Extension | Description |
|-----------|-------------|
| `.scrb`   | Scrib encrypted format (AES-256 + HMAC) |
| `.txt`    | Plain text |
| `.rtf`    | Rich Text Format (import/export) |
| `.md`, `.log`, `.csv`, `.json`, `.xml`, `.yaml`, `.ini`, `.cfg` | Open as plain text |

---

## Building from Source

### Requirements

- [Flutter](https://flutter.dev/) 3.7 or later (tested on 3.38.6)
- Windows 10 or later
- Visual Studio 2022 with the **Desktop development with C++** workload

### Build

```bash
# Clone the repo
git clone https://github.com/beeswaxpat/scrib-desktop.git
cd scrib-desktop

# Get dependencies
flutter pub get

# Run in debug mode
flutter run -d windows

# Build a release executable
flutter build windows --release
```

The release binary will be at:

```
build\windows\x64\runner\Release\scrib_desktop.exe
```

---

## Project Structure

```
lib/
  main.dart                         # App entry point, window management
  constants.dart                    # App-wide constants, color palettes
  providers/
    editor_provider.dart            # All tab state + file operations
  screens/
    main_screen.dart                # Main UI: menu bar, toolbar, editor layout
  services/
    file_service.dart               # Disk I/O, AES-256 encryption/decryption
    settings_service.dart           # Settings persistence via Hive
    rtf_service.dart                # Quill Delta <-> RTF converter
  widgets/
    editor_widget.dart              # Plain text (TextField) + rich text (QuillEditor)
    formatting_toolbar_widget.dart  # Rich text formatting toolbar
    toolbar_widget.dart             # Quick-action toolbar
    tab_bar_widget.dart             # Tab bar with rename and color support
    search_bar_widget.dart          # Find & Replace bar
    status_bar_widget.dart          # Word/char/line count, encryption status
  theme/
    desktop_theme.dart              # Dark and light Material 3 themes
```

---

## Encryption Details

Scrib uses **Encrypt-then-MAC** (authenticated encryption):

| Component       | Algorithm |
|-----------------|-----------|
| Key derivation  | PBKDF2-SHA256, 100,000 iterations, 64-byte output |
| Encryption      | AES-256-CBC with PKCS7 padding |
| Authentication  | HMAC-SHA256 over (version, IV, salt, ciphertext) |
| IV              | 16 bytes, cryptographically random per save |
| Salt            | 32 bytes, cryptographically random per save |

`.scrb` v2 file layout:

```
[0:4]   Magic bytes: SCRB
[4:5]   Version: 0x02
[5:21]  IV (16 bytes)
[21:53] Salt (32 bytes)
[53:85] HMAC-SHA256 (32 bytes)
[85:]   Ciphertext (AES-256-CBC)
```

Keys are zeroed from memory immediately after use. PBKDF2 runs in a background isolate so the UI stays responsive during encryption/decryption.

---

## Dependencies

| Package | Purpose |
|---------|---------|
| `flutter_quill` | Rich text editor (Quill Delta format) |
| `provider` | State management |
| `hive` | Local settings persistence |
| `encrypt` | AES encryption |
| `pointycastle` | PBKDF2 / HMAC-SHA256 |
| `window_manager` | Desktop window lifecycle |
| `file_picker` | Open/save dialogs |
| `desktop_drop` | Drag & drop file support |
| `path_provider` | App data directory |

---

## License

Scrib Desktop is free software: you can redistribute it and/or modify it under the terms of the **GNU General Public License v3** as published by the Free Software Foundation.

See [LICENSE](LICENSE) for the full text.

---

## Contributing

Pull requests are welcome. For major changes, open an issue first to discuss what you would like to change.

Please make sure your contributions:
- Do not introduce tracking, analytics, or network calls
- Do not weaken the encryption or key derivation
- Follow the existing code style (minimal, focused, no premature abstraction)

---

*Built with Flutter. Privacy-first. No tracking. No cloud.*
