# What this PR does

<!-- One or two sentences. Link the issue if there is one. -->

## Checklist

- [ ] `flutter analyze` reports 0 issues
- [ ] `flutter test` passes (full suite)
- [ ] `flutter build windows --release` builds cleanly
- [ ] Load-bearing invariants respected (see [ARCHITECTURE.md](../ARCHITECTURE.md)):
  - [ ] Locked tabs are refused by every save path
  - [ ] All file writes go through `AtomicWrite`
  - [ ] Plaintext can never land in a `.scrb`; ciphertext never in `.txt`/`.rtf`
  - [ ] Link handling keeps the http/https/mailto allowlist at dialog AND launch
- [ ] Existing note files (`.scrb` v2/v3, `.txt`, `.rtf`) still open unchanged
- [ ] New behavior has tests; fixed bugs have a regression test
- [ ] No new dependencies (or the PR explains why one is required)
