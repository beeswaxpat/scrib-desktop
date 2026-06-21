# Security Policy

Scrib Desktop is an offline, encrypted text editor. We take reports about the
encryption, file handling, and data integrity seriously.

## Supported versions

| Version | Supported |
|---------|-----------|
| 1.3.x   | ✅ |
| 1.2.x   | ⚠️ Critical fixes only |
| < 1.2   | ❌ |

## Reporting a vulnerability

**Please do not open a public GitHub issue for security vulnerabilities.**

Instead, use GitHub's private vulnerability reporting:

1. Go to the **Security** tab of this repository.
2. Click **Report a vulnerability**.
3. Describe the issue, the affected version, and steps to reproduce.

If private reporting is unavailable, contact the maintainer through the contact
details on <https://scrib.cfd/>.

We aim to acknowledge a report within 7 days and to provide a remediation plan
or fix timeline within 30 days.

## Scope and threat model

What Scrib defends against, and what it explicitly does **not**, is documented
in the [Threat model](README.md#threat-model) section of the README. In short:

- `.scrb` files use AES-256-CBC with HMAC-SHA256 (Encrypt-then-MAC), PBKDF2-SHA256
  key derivation, and authenticated, self-describing KDF parameters (v3 format).
- The HMAC is verified before any decryption, and it covers the version byte,
  the KDF parameters, the IV, the salt, and the ciphertext.
- Scrib does **not** defend against a compromised machine (key-logger, RAM dump,
  malicious build) or brute-forcing a weak password.

Reports that fall outside the documented threat model (for example, "the
password is recoverable from a memory dump") are already acknowledged as
limitations and are not treated as vulnerabilities, though concrete
improvements are always welcome.

## What to include in a report

- The Scrib Desktop version and your OS version.
- A minimal proof of concept or reproduction steps.
- The impact you believe the issue has.
- Whether the issue affects existing `.scrb` files on disk.
