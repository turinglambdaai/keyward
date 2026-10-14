# Keyward

A local vault for the release-signing keys of self-updating desktop apps.

English | 中文见下方

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
  a pile of hand-run openssl commands.
- **Collect, don't scatter.** In-app keypair generation writes straight into
  the vault; PEM imports land as single-line base64 values. No stray key
  files, even momentarily.
- **Orphan detection.** Multi-line residue from a bad paste shows up as line
  numbers the moment the vault is opened.

The vault format is plain INI (`[product]` sections, `NAME = value`,
comments preserved) and stays the single source of truth — Keyward is a
discipline layer over it, not a lock-in.

## Status

M0 shipped: **v0.1.0 is out** — macOS installers (arm64 / x64, DMG + zip with
SHA256SUMS) on the [Releases page](https://github.com/turinglambdaai/keyward/releases/latest).
Windows (WinUI 3) and Linux (GTK4) hosts next. Roadmap: rotation workflow
(generate-next → promote, following the two-phase runbook), stray-key scanner
for working trees, Sparkle/Tauri key format import and export.

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
- Windows UI: `windows/` (M1) · Linux UI: `linux/` (M1)

## 中文简介

Keyward 是给"自己会更新的桌面应用"保管发布签名钥匙的本地保险库：私钥签
更新清单、公钥嵌在已装应用里验签——Sparkle、Tauri updater、electron-updater
全都是这一套，缺的从来都是私钥的日常托管。Keyward 建在自家 Rivet 线上
（Racket 引擎 + 原生壳），库文件就是你自己的同步盘里的明文 INI；它往上加
纪律：值永不显示只进剪贴板、每次改动先快照（防丢）、深度校验（解析/配对/
指纹，一条命令替代一堆手工 openssl）、生成即入库（杜绝散件）。安全模型
= 信任设备间的明文同步 + 各机全盘加密，引擎零网络代码。

## License

AGPL-3.0
