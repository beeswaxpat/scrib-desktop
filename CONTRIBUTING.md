# Contributing to Scrib Desktop

Thanks for your interest in Scrib Desktop. PRs are welcome.

## Ground Rules

- **No tracking, analytics, or network calls.** Scrib is fully offline by design.
- **No weakening encryption or key derivation.** The AES-256 / PBKDF2 parameters are intentional.
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

**Requirements:** Flutter 3.7+ (tested on 3.38.6), Windows 10+, Visual Studio 2022 with the Desktop C++ workload.

## Before Submitting a PR

1. `flutter analyze` must report **0 issues**
2. `flutter test` must pass
3. `flutter build windows --release` must produce a clean build
4. Keep commits focused — one logical change per PR

## Built With

Scrib Desktop was built by [Beeswax Pat](https://scrib.cfd/) with
[Claude Code](https://claude.ai/claude-code) (Opus 4.6 & Sonnet 4.6).

If you're using Claude Code to contribute, that's great — just make sure the
output meets the same quality bar as any hand-written code: clean, tested, and
no unnecessary changes.

## License

By contributing, you agree that your contributions will be licensed under the
[GNU GPL v3](LICENSE).
