# Changelog

All notable changes to Keyward are documented here. Format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/); versioning is SemVer.

## [Unreleased]

### Added

- **Per-entry purpose hints** (all three hosts): every known entry name now
  carries a one-line consumer note — CI manifest signing, Racket-side
  updater, macOS host `UpdateService`, update-manifest key id, Deep Check
  pairing anchor, commercial-signing lifecycle. Unknown names get an
  explicit "confirm what reads it before deleting" line, so the app itself
  answers "can I delete this?" instead of silence. The delete confirmation
  shows the same purpose line.
- **Clipboard handling that tells the truth**: a copy reports that the raw
  value is on the system clipboard where any app can read it, and auto-clears
  after 30 s — only while the clipboard still holds Keyward's copy (change
  count on macOS, a non-secret marker title on Windows, an ownership-marker
  mime on Linux), so a later unrelated copy by the user is never erased.
  Clipboard history/sync stays disclosed as out of Keyward's control.
- **Plaintext custody stated in the app**: the intro, no-vault, snapshots
  and About surfaces on all three hosts now say plainly that the vault file
  and its snapshots are plain text on disk — not OS-encrypted custody — and
  that the synced folder must be trusted.

### Fixed

- Rapidly selecting two products could leave rows and the copy target
  bound to different sections: entry-list completions and copies are now
  generation-guarded and bound to the product on screen; a stale copy is
  skipped instead of landing a secret under a different header. A store
  switch invalidates in-flight completions the same way.

### Fixed

- Deep check now evaluates every private entry and all public anchors within its purpose. A valid update key no longer hides a corrupt or mismatched license key; multiple safe fingerprints remain labelled within the existing RPC row layout. Empty private entries are reported as unreadable. Regression coverage uses generated temporary keys only.


### Fixed
- The summary-tile count could wrap under width pressure: "Products 15"
  folded into a vertical "1/5" that read as two mystery numbers. Counts
  are now single-line, fixed-size and monospaced, taking layout priority
  over the label.

- **The vault failed to load on every launch when a default path resolved.**
  The `store-path` RPC ran the active store through `path->string`, and
  Racket 9.3 tightened it to reject strings outright — so any user whose
  default chain (persisted choice → `KEYWARD_STORE` →
  `~/Sync/Keys/secrets.ini`) produced the string form saw "No vault
  selected" plus a `path->string: contract violation` backend error
  instead of their products. The active store is now kept as a plain
  string end to end, and `store-open` normalizes the `simple-form-path`
  output before it enters `current-store`.

## 0.2.0 - 2026-10-15

Windows and Linux hosts — the three-platform installer matrix closes.

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
  AGPL-3.0 line and a Report-an-Issue link.
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

### Changed

- The win/linux hosts consume Rivet as the package library (rivet#238):
  the Linux build add_subdirectories the rivet platform and links
  `rivet::platform`, and the Windows project references the rivet-host
  static library (forwarding the hybrid-CRT RuntimeLibrary choice) — no
  host project ClCompiles rivet sources anymore, so rivet adding a
  translation unit needs no downstream change.

### Fixed

- The 0.1.0 entry's date now reads 2026-10-14, the day the release
  actually shipped.
- The Windows sidebar Snapshots tile shows the real snapshot count —
  refreshed with every product refresh and after snapshot-taking
  mutations — where it previously read a constant "·".
- The Linux About dialog's website row points at the GitHub issue
  tracker ("Report an Issue"), the same one-click bug-report surface as
  the macOS and Windows About sheets.
- The Windows exe and MSI carry the vault-dial icon: `windows-icon`
  (assets/branding/app.ico, generated by scripts/gen-icon.swift) joins
  rivet.rktd — an iconless MSI shortcut was a silent defect.

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
