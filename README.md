# Keyward

**English** · [中文](README.zh-CN.md)

A local vault for the release-signing keys of self-updating desktop apps.

[![CI](https://github.com/turinglambdaai/keyward/actions/workflows/ci.yml/badge.svg)](https://github.com/turinglambdaai/keyward/actions/workflows/ci.yml)
[![Release](https://img.shields.io/github/v/release/turinglambdaai/keyward)](https://github.com/turinglambdaai/keyward/releases)
[![License: AGPL-3.0](https://img.shields.io/badge/license-AGPL--3.0-blue)](LICENSE)

Every app that updates itself over the network eventually relies on the same
trust model: a **private key signs the update manifest**, and a **public key
embedded in the installed app** verifies it. Sparkle, Tauri's updater,
electron-updater, WinSparkle, Google Omaha — the scheme is universal. What
nobody hands you is custody for the private half: where it lives, how it
reaches CI, when it rotates, and how you notice a stray copy before it
rotates *you*.

> 📖 **New to update signing?** Read the bilingual handbook —
> **[使用手册 / Handbook](https://keyward.jrtx.site/guide.html)** (中文原文，
> with an idiomatic English translation; switchable per language) —
> or the [source markdown](docs/GUIDE.zh-CN.md): install, connect a vault,
> every daily operation, wiring CI, shipping updates, and key rotation,
> written for complete beginners.

Keyward is a small desktop app that guards those keys. Built on the family
Rivet line — a Racket engine with native hosts — it keeps the vault file in
your own synced folder and adds the discipline a plaintext store lacks:

- **Never displayed, copy-only.** Key values are only ever returned by an
  explicit copy-to-clipboard action.
- **Loss protection.** Every mutation snapshots the store first (append-only,
  inside the synced folder); writes are atomic and permissions are tightened.
- **Deep check.** Parses each key (Ed25519 / RSA PKCS#8, base64-DER,
  base64-PEM or bare PEM), derives the public half, computes the fingerprint,
  and pairs it against the stored public material — the audit that used to be
  a pile of hand-run openssl commands. Every private entry is checked against
  all public anchors of the same purpose; a section passes only when every
  private key passes, with each fingerprint labelled in multi-key sections.
- **Collect, don't scatter.** In-app keypair generation writes straight into
  the vault; PEM imports land as single-line base64 values. No stray key
  files, even momentarily.
- **Orphan detection.** Multi-line residue from a bad paste shows up as line
  numbers the moment the vault is opened.

The vault format is plain INI (`[product]` sections, `NAME = value`,
comments preserved) and stays the single source of truth — Keyward is a
discipline layer over it, not a lock-in.

## Status

**v0.2.0 is out** — installers for all three desktops on the
[Releases page](https://github.com/turinglambdaai/keyward/releases/latest):
macOS (arm64 / x64, DMG + zip), Windows (x64, MSI + zip) and Linux (x64 /
arm64, deb + rpm + AppImage + tar.gz + zip), each with a SHA-256 sidecar.
The Windows (WinUI 3) and Linux (GTK4) hosts are built and CI-covered.
Roadmap: rotation workflow (generate-next → promote, following the
two-phase runbook), stray-key scanner for working trees, Sparkle/Tauri key
format import and export.

## Security model

The vault is plaintext **by design** — it lives in a private sync between
your own trusted devices, and the budget goes to full-disk encryption on
each device instead. Keyward never sends a key anywhere: there is no
network code in the engine. See `AGENTS.md` for the operating rules
(never print values, never commit the vault, collect strays immediately).

## Development

```bash
raco rivet dev        # build backend + macOS host, run the app
raco test tests/      # engine tests (store + key metadata)
raco rivet package    # distributable
```

- Shared engine: `app/backend.rkt` + `app/core/` (RVT1 contract — the
  wire surface shared by every future host)
- macOS UI: `macos-host/Sources/RivetHost/`
- Windows UI: `windows/` · Linux UI: `linux/`

## License

AGPL-3.0

## Delivery priorities (2026-10-23)

The current product review issue linked from AGENTS owns the next bounded slice and its acceptance scenarios. Follow the existing product specification and the [family delivery standard](https://github.com/turinglambdaai/turinglambdaai.github.io/blob/master/docs/PRODUCT-STANDARD.md). Hardware, native-platform and live-payment gates remain explicit; this documentation update does not claim they passed.

## Feedback and diagnostics

Report reproducible bugs and feature requests through [GitHub Issues](https://github.com/turinglambdaai/keyward/issues). Include the release, OS/architecture and steps; inspect and redact diagnostics before sharing. Do not post API keys, license files, vault contents or private documents. For sensitive security reports, follow SECURITY.md when present; otherwise request a private contact route without disclosing sensitive details. Nothing is uploaded automatically.

## Product policy

Keyward is free security and release infrastructure. No paid tier or charge by key count is planned. Read the full [English policy](PRICING.md) or [简体中文](PRICING.zh-CN.md); source-license rights remain unchanged.
