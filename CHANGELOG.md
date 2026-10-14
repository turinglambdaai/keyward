# Changelog

All notable changes to Keyward are documented here. Format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/); versioning is SemVer.

## [Unreleased]

Windows and Linux hosts — the three-platform installer matrix closes;
these entries land with the next release.

### Added

- **Windows host** (WinUI 3 / C++/WinRT): product sidebar with status
  dots and fingerprints, product detail with KV chips and entry cards,
  copy-to-clipboard (values never display), PEM import through the file
  picker, delete and key-generation confirmations, the snapshots dialog,
  and the Choose Vault / Deep Check / Snapshots / About menu
  (Ctrl+O / Ctrl+R / Ctrl+L).
- **Linux host** (GTK4): the same surface — a GAction menu with the same
  shortcuts, product list, entry rows with clipboard copy, the snapshots
  dialog, and an About dialog carrying `Keyward v<version>`, the
  AGPL-3.0 line and the project site.
- **Windows release leg**: MSI (WiX 5) + portable zip, with per-file
  SHA-256 sidecars; no update feed — a key vault does not update itself.
- **Linux release leg**: x64 + arm64 matrix building tar.gz + deb + rpm +
  AppImage + portable zip with a CycloneDX SBOM, plus stable direct-link
  aliases (keyward-windows-x64.msi, keyward-linux-x64.deb/AppImage).
- **Host CI**: `windows-host` (raco rivet build + launch smoke) and
  `linux-host` (GTK4 build + headless boot smoke under xvfb) jobs, so a
  release job is never the first place native source compiles.
- Linux AppImage branding: the 512 px vault-dial icon (`linux-icon`) and
  an explicit `linux-formats` selection in rivet.rktd.

- **Help ▸ About**: an About sheet carrying the `Keyward v<version>`
  line (bundle version, falling back to the generated Rivet config), the
  product line ("local by design"), the AGPL-3.0 license line, the site
  (keyward.jrtx.site) and a Report-an-Issue link to the GitHub tracker —
  a bug report starts one click from the failure it describes.
- **GitHub issue templates** (bug report + feature request) so feedback
  lands structured and safe: the bug form asks for the vault location
  shape and names what must never be pasted — key values and section
  bodies — while pointing at fingerprints as the shareable identifier.

### Fixed

- The 0.1.0 entry's date now reads 2026-10-14, the day the release
  actually shipped.

## 0.1.0 - 2026-10-14

### Added

- **Keyward M0**: a local vault app for the release-signing keys of
  self-updating desktop apps, built on the family Rivet line (Racket
  engine + native hosts).
- Store engine for the family `secrets.ini` format: comment-preserving
  parse/write, single-line value enforcement, kebab-case/UPPER_SNAKE
  naming guards, orphan-line detection (line numbers only — residue is
  often key material).
- **Loss protection**: every mutation writes an append-only snapshot into
  `<folder>/.history/keyward/` before the store changes; the snapshots
  folder syncs with the store itself, so any bad write is one restore
  away on every synced device. Writes are atomic and permissions are
  tightened to 600.
- **Deep check**: parses every private key (Ed25519 and RSA PKCS#8, in
  base64-DER, base64-PEM and bare-PEM forms), derives the public key,
  computes the family fingerprint (sha256 of public DER, first 16 hex),
  and pairs it against stored public material — including `*_FPR`
  fingerprint entries. Cross-validated against a 14-product production
  vault.
- In-app Ed25519 keypair generation collected straight into the store
  under the rivet-family update-key names — no stray key file exists,
  even momentarily.
- PEM import into single-line base64 values; copy-value-to-clipboard as
  the only path to a key's value (never displayed in the UI).
- macOS SwiftUI host (M0); Windows WinUI3 and Linux GTK4 hosts queued
  for M1.

## Unreleased — changed

- The vault location is user-chosen and remembered across launches
  (`~/.keyward/config.json` stores the path — nothing else). The
  `~/Sync/Keys/secrets.ini` family layout remains the zero-config default
  when it exists; `KEYWARD_STORE` still overrides for CI.

## Unreleased — changed

- **macOS host redesigned to the taskly-grade design language**: custom
  window chrome (280px sidebar + content pane + 28px status bar), semantic
  design tokens in warm vault tones with live light/dark tracking, summary
  tiles, quiet selection/hover fills, hover-revealed copy buttons, and
  keyboard shortcuts (⌘O choose vault · ⌘R deep check · ⌘L snapshots).
- Brand app icon — the vault dial + key on the family warm gradient —
  wired via `macos-icon`; the generator script lives at
  `scripts/gen-icon.swift`.
- The vault location is user-chosen and remembered across launches
  (`~/.keyward/config.json` stores the path — nothing else). The
  `~/Sync/Keys/secrets.ini` family layout remains the zero-config default
  when it exists; `KEYWARD_STORE` still overrides for CI.
