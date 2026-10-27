# Keyward user guide

**English** · [简体中文](USER-GUIDE.zh-CN.md)

Organize and check desktop release-signing keys in a local vault.

## Availability

Free release-infrastructure tool under AGPL-3.0; no commercial activation.

## Platforms and installation

Desktop previews for macOS, Windows and Linux. Use a synthetic disposable vault before connecting real release credentials.

Use [official Releases](https://github.com/turinglambdaai/keyward/releases), select an explicitly listed OS/architecture asset, read its release notes and check supplied checksums. An absent asset/platform is not a delivery promise. Preview builds may lack publisher signing or notarization; do not disable system-wide security protections to install them.

## Your first successful session

1. Create a temporary test vault; inspect entry names and fingerprints rather than displaying private values.
2. Validate each key pair and inspect every reported failure separately. One valid key does not validate all keys in a section.
3. Rehearse backup and a two-stage rotation on test keys before changing the key used by installed applications.

## Data, backup and recovery

The vault is a plaintext INI file; file permissions and snapshots do not encrypt it. Keep encrypted offline backups of the vault and snapshots, with the decryption material separately protected. Do not place a real vault in screenshots, issues or this repository.

## Network, keys and privacy

The vault engine has no network operations. Copy-to-clipboard is the only path a value takes out of the app: the status line says so at each copy, notes that any application can read the clipboard, and auto-clears Keyward's copy after 30 s — a later unrelated copy of your own is never erased. What the app cannot control (OS clipboard history or cross-device clipboard sync) stays disclosed as out of scope. Any user-chosen folder sync creates additional exposure. Keyward is not an HSM, OS keychain or protection from an already compromised user session.

## Known limits

Multi-key validation was corrected in #4. In-app disclosure of plaintext custody, per-entry purpose hints, copy-consequence messaging, selection-bound copies and the 30 s clipboard auto-clear have landed in source (#3); packaged three-platform release evidence for that slice is still pending. Backup/restore and rotation workflow work remains tracked in #3; do not infer a security certification.

## Updates and removal

Back up data and read the destination release notes first. An in-app update check does not necessarily install an update for your channel; follow the manual for portable, installer and source paths. Never bypass a failed signature check or replace the program with an untrusted artifact. On failure, preserve data and the error, then recover with a trusted release. Removing the program does not necessarily erase its separate data directory; verify your backup before deleting personal data.

## Get help

Report problems in [GitHub Issues](https://github.com/turinglambdaai/keyward/issues), in English or Chinese. Include the version, OS/architecture, installation channel, steps, expected result and actual result. Reproduce with synthetic input first; do not attach keys, credentials, databases, private source documents or complete logs. Public support has no guaranteed response time.

## Further reading

- [Vault handbook](../site/guide.html)
- [Chinese handbook source](../docs/GUIDE.zh-CN.md)
- [Project overview and development](../README.md)
- [Current licence](../LICENSE)
