# Changelog

All notable changes to Keyward are documented here. Format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/); versioning is SemVer.

## Unreleased

## 0.1.0 - 2026-10-13

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
