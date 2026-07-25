# Contributing to Scrib Desktop

Thanks for your interest in Scrib Desktop. PRs are welcome.

## Ground Rules

- **No tracking, analytics, or network calls.** Scrib is fully offline by design.
- **No weakening encryption or key derivation.** The AES-256 / PBKDF2 parameters are intentional.
- **Respect the load-bearing invariants.** Read [ARCHITECTURE.md](ARCHITECTURE.md)
  before touching any save path, the encryption code, or the link handling. It
  documents the invariants (locked tabs are never written, atomic writes,
  plaintext never lands in a `.scrb`, the http/https/mailto link allowlist)
  and the save-path routing.
- **Follow existing code style.** Two-space indentation, no trailing whitespace, Dart conventions.
- For major changes, open an issue first so we can discuss the approach.

## Getting Started

```bash
git clone https://github.com/beeswaxpat/scrib-desktop.git
cd scrib-desktop
flutter pub get
flutter run -d windows        # debug
flutter build windows --release
```

**Requirements:** Flutter stable (CI pins 3.38.6; use that version for
reproducible results), Windows 10+, Visual Studio 2022 with the Desktop C++
workload. The `flutter_quill` dependency is declared as an exact version in
`pubspec.yaml` (`11.5.0`, no caret) and is excluded from Dependabot; see
ARCHITECTURE.md for why upgrades need extra verification.

## Before Submitting a PR

1. `flutter analyze` must report **0 issues** (CI runs it with
   `--fatal-infos --fatal-warnings`)
2. `flutter test` must pass, and every behavior fix lands with a regression
   test that fails on the old code
3. `flutter build windows --release` must produce a clean build
4. Keep commits focused: one logical change per PR

The pull request template repeats the load-bearing invariants as a checklist;
work through it rather than ticking it.

## Built With

Scrib Desktop was built by [Beeswax Pat](https://scrib.cfd/) with
[Claude Code](https://claude.com/claude-code).

If you're using Claude Code to contribute, that works here too. Just make sure
the output meets the same quality bar as any hand-written code: clean, tested,
and no unnecessary changes.

## License

By contributing, you agree that your contributions will be licensed under the
[GNU GPL v3](LICENSE).
