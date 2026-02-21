# Ready-to-Post — Scrib Desktop Open Source Announcement

Copy-paste these wherever you want. Edit as you see fit.

---

## Hacker News (Show HN) ← DO THIS FIRST, highest value

**Title:** Show HN: Scrib Desktop – Encrypted text editor for Windows (Flutter/Dart, GPL-3.0)

**Body:**

Scrib Desktop is a tabbed text editor for Windows with real AES-256 encryption built in. Plain text, rich text, and its own .scrb encrypted format — fully offline, no accounts, no telemetry.

Encryption details: AES-256-CBC + HMAC-SHA256 (Encrypt-then-MAC). PBKDF2-SHA256 key derivation with 100k iterations. Fresh IV + salt on every save. HMAC verified before decryption, so tampered files are rejected. Encryption runs in background isolates so the UI never blocks. Keys zeroed from memory after use.

The full encryption implementation is in one file (file_service.dart) if anyone wants to audit it.

Built with Flutter Desktop — which is still relatively young territory on Windows. Wanted to see how far it could go. Turned out: pretty far.

Built collaboratively with Claude Code (Anthropic's AI coding CLI). Architecture and UX decisions were mine; code execution was a genuine back-and-forth.

GPL-3.0. Source: https://github.com/beeswaxpat/scrib-desktop

---

## Reddit: r/FlutterDev

**Title:** I open-sourced my encrypted Windows desktop text editor — built entirely with Flutter

**Body:**

Just open-sourced Scrib Desktop, a tabbed text editor for Windows with AES-256 encryption built in. Wanted to share it here since Flutter Desktop is still relatively underrepresented.

**Stack:**
- Flutter 3.38 / Dart
- flutter_quill for rich text (Delta JSON)
- pointycastle for AES-256-CBC + HMAC-SHA256
- Hive for local settings persistence
- window_manager for window control + state persistence
- desktop_drop for drag & drop

**Some things I found interesting about Flutter Desktop:**
- Background isolates work great for crypto (PBKDF2 100k iterations never blocks the UI)
- window_manager gives you solid control over position/size persistence
- flutter_quill is solid but Delta ↔ RTF conversion required a custom converter
- Material 3 on desktop feels polished with the right theme tuning

Built with Claude Code (Anthropic's CLI). GPL-3.0.

GitHub: https://github.com/beeswaxpat/scrib-desktop

Happy to answer questions about the Flutter Desktop experience.

---

## Reddit: r/opensource

**Title:** Scrib Desktop — encrypted text editor for Windows, fully offline, GPL-3.0

**Body:**

Just open-sourced Scrib Desktop — a tabbed text editor for Windows with built-in AES-256 encryption.

I wanted a simple editor where I could write notes and lock them with a password. No cloud sync, no accounts, no tracking. Couldn't find one that wasn't bloated or sketchy, so I built one.

**What it does:**
- Plain text and rich text modes (switch per tab with Ctrl+M)
- AES-256-CBC + HMAC-SHA256, PBKDF2 key derivation (100k iterations)
- Saves to .txt, .rtf, or .scrb (encrypted)
- Opens .txt, .rtf, .md, .json, .xml, .yaml, .csv, .log, .ini, .cfg
- Multi-tab with per-tab colors, inline rename
- Portable — extract the zip and run, no installer needed

Built with Flutter/Dart. GPL-3.0.

https://github.com/beeswaxpat/scrib-desktop

---

## Reddit: r/privacy

**Title:** I built an offline encrypted text editor for Windows — no internet, no tracking, no accounts. Now open source.

**Body:**

Scrib Desktop is a tabbed text editor for Windows that encrypts your files locally with AES-256. Built it because I wanted somewhere to write notes that doesn't phone home.

**Encryption implementation:**
- AES-256-CBC + HMAC-SHA256 (Encrypt-then-MAC)
- PBKDF2-SHA256 key derivation, 100k iterations
- Unique IV + salt generated on every save
- HMAC verified before decryption — tampered files are rejected before anything is decrypted
- Keys zeroed from memory after use
- Runs in background isolate — UI never blocks during crypto operations
- Zero network permissions. No telemetry. No analytics.

Source code is GPL-3.0 so you can verify every line:
https://github.com/beeswaxpat/scrib-desktop

The full encryption implementation is in one file (file_service.dart) if you want to audit it.

---

## Reddit: r/windows

**Title:** I built a free encrypted Notepad/WordPad replacement for Windows — open source

**Body:**

Built and open-sourced Scrib Desktop — a tabbed text editor for Windows that combines plain text editing, rich text formatting, and AES-256 encryption in one lightweight app.

Think: Notepad + WordPad + encryption = Scrib Desktop.

**Features:**
- Multi-tab interface with per-tab colors
- Plain text mode (with line numbers) and rich text mode (bold, italic, headings, lists, 14 fonts, neon highlights)
- AES-256 encryption on any tab — saves as .scrb file
- Opens .txt, .rtf, .md, .json, .xml, .csv, .log and more
- Dark / Light / System themes
- Drag and drop, auto-save, portable (no installer needed)
- Fully offline — zero network access

Free. No ads. No accounts. GPL-3.0.

Download: https://github.com/beeswaxpat/scrib-desktop/releases
Source: https://github.com/beeswaxpat/scrib-desktop

---

## Reddit: r/programmingtools (or r/commandline)

**Title:** Scrib Desktop — open source encrypted text editor for Windows, built with Flutter

**Body:**

Open-sourced Scrib Desktop today. It's a tabbed text editor for Windows with real AES-256 encryption (not just password protection).

Built with Flutter Desktop + Dart. Full source on GitHub under GPL-3.0.

Supports .txt, .rtf, .md, .json, .xml, .yaml, .csv, .log, .ini, .cfg — opens and edits all of them. Saves to .txt, .rtf, or .scrb (encrypted).

https://github.com/beeswaxpat/scrib-desktop

---

## AlternativeTo.net — Listing Description

**App Name:** Scrib Desktop
**Alternatives to:** Notepad, WordPad, Notepad++, Notepad2

**Description:**
Scrib Desktop is a free, open-source encrypted text editor for Windows. It combines plain text editing, rich text formatting, and AES-256 file encryption in a single lightweight tabbed app — with no internet connection, no accounts, and no tracking.

Features include multi-tab editing with per-tab accent colors, plain and rich text modes (switchable per tab), AES-256-CBC encryption with PBKDF2 key derivation, RTF import/export, dark and light themes, drag and drop, and auto-save. Files are saved as .txt, .rtf, or .scrb (encrypted). Portable — no installer needed.

Free and open source under GPL-3.0.

**Submit at:** https://alternativeto.net/software/add/

---

## Product Hunt

**Tagline:** Notepad + WordPad + AES-256 Encryption = Scrib Desktop

**Description:**
Scrib Desktop is a free, open-source text editor for Windows that encrypts your files with real AES-256. Multi-tab, plain text + rich text, dark theme, fully offline.

No cloud. No tracking. No accounts. No installer needed — just extract and run.

Built with Flutter for Windows. GPL-3.0.

**First comment (maker comment):**
Hey PH — I'm Pat, the builder. I made Scrib Desktop because I wanted a simple place to write notes that I could actually lock. Every existing encrypted notepad I tried was either bloated, sketchy, or stopped being maintained.

The encryption is real: AES-256-CBC + HMAC-SHA256 with PBKDF2 (100k iterations). The source code is GPL-3.0 on GitHub so you can verify every line.

Built with Flutter Desktop + Claude Code. Happy to answer any questions.

---

## dev.to Article Outline

**Title:** I Built an Encrypted Text Editor with Flutter Desktop — Here's What I Learned

**Tags:** flutter, dart, encryption, opensource, windows

**Intro:**
Flutter on Windows Desktop is still relatively underexplored territory. Most Flutter developers are building mobile apps. I wanted to see how far Flutter could go on desktop — so I built Scrib Desktop, a full-featured encrypted text editor.

**Section 1: Why Flutter Desktop**
- Cross-platform foundation
- Material 3 on desktop
- What works well, what required workarounds

**Section 2: The Encryption Implementation**
- AES-256-CBC + HMAC-SHA256 (Encrypt-then-MAC)
- PBKDF2 with 100k iterations
- Running crypto in background isolates so the UI never freezes
- The .scrb file format (magic bytes, IV, salt, HMAC, ciphertext)

**Section 3: Rich Text with flutter_quill**
- Delta JSON format
- Custom Delta ↔ RTF bidirectional converter
- Detecting rich vs plain text content after decryption

**Section 4: Window State Persistence**
- window_manager package
- Debounced save on move/resize

**Section 5: What I'd Do Differently**
- Honest reflection

**CTA:** GitHub link, invite contributions

---

## awesome-flutter PR Description

**Repo:** https://github.com/Solido/awesome-flutter
**Section:** Desktop / Windows
**Entry to add:**

- [Scrib Desktop](https://github.com/beeswaxpat/scrib-desktop) - Encrypted text editor for Windows. Plain text, rich text, AES-256 encryption, multi-tab, fully offline. GPL-3.0.

**PR Title:** Add Scrib Desktop — encrypted Flutter Windows text editor

**PR Body:**
Adding Scrib Desktop, an open-source encrypted text editor for Windows built with Flutter. It supports plain text, rich text (flutter_quill), and AES-256 file encryption (pointycastle). Multi-tab interface, dark/light themes, RTF import/export, fully offline. GPL-3.0.

GitHub: https://github.com/beeswaxpat/scrib-desktop
