# Rivet agent contract

## Authorization decision before implementation

Decision `2026-10-auth-1`: No commercial Permit credentials, Commerce checkout or licensing account. Read the complete [local authorization decision](PRICING.md#authorization-decision-for-implementation) and its Chinese counterpart before commercial, trial, update-eligibility or credential work. Record this decision revision and the source/policy SHAs actually read in the PR/handoff. Refresh at each bounded slice; existing agent conversations do not receive this change automatically. Follow the existing product contract and implementation issue; do not activate a payment gate merely because a plan exists.

## Required policy discovery at each slice

Before starting the next bounded slice, refresh remote state safely and re-read
this root AGENTS file, the repository's canonical implementation handoff, and
the current [family delivery standard](https://github.com/turinglambdaai/turinglambdaai.github.io/blob/master/docs/PRODUCT-STANDARD.md),
[documentation language policy](https://github.com/turinglambdaai/turinglambdaai.github.io/blob/master/docs/DOCUMENTATION-LANGUAGES.md)
and [portfolio decisions](https://github.com/turinglambdaai/turinglambdaai.github.io/blob/master/PORTFOLIO.md).
Follow the corresponding Chinese links when preferred; both public user paths
must express the same promises. Product-specific plans and technical protocol
owners remain in their owning repositories.

Record the repository starting SHA and the central-policy commit/revision
actually read in the PR or handoff. A link's presence is not an acknowledgement
that an agent has read it. Existing conversations and stale checkouts do not
receive policy updates automatically: refresh these inputs at slice boundaries.
Preserve other agents' dirty worktrees; use an isolated checkout when needed,
without stashing, resetting or overwriting their work. Missing/offline policy
inputs must be reported as unverified, not silently claimed current.


Human-first. Agent-native. Local by design.

## Start every task here

```bash
raco rivet inspect --json
raco rivet doctor --json
```

`inspect` is the machine-readable project map. It identifies the shared Racket
backend, each native UI edit point, platform maturity, generated directories,
and safe lifecycle commands. `doctor` reports the exact local toolchain and
returns a failing exit status when the current host is not usable.

## Architecture boundary

- Keep shared application and domain logic in `app/backend.rkt`.
- Keep Windows UI native in WinUI 3 / C++/WinRT under `windows/`.
- Keep macOS UI native in SwiftUI/AppKit under `macos-host/`.
- Keep Linux UI native in GTK4 under `linux/`.
- Do not introduce a cross-platform UI DSL or bypass RVT1 with an ad-hoc IPC.
- iOS/iPadOS/watchOS and Android are foundation targets until their
  generated app, embedding, packaging, signing, and device workflows exist.

## Capability sourcing

When a feature is not already present, do not reject Racket or add another
runtime by reflex. Read `capability-sourcing` from `inspect --json`, then choose
the narrowest boundary that fits:

1. Prefer a Racket built-in or maintained package. Discover candidates with
   `raco docs <term>`, `raco pkg show`, and
   `raco pkg catalog-show --all --only-names`; inspect a candidate with
   `raco pkg catalog-show --modules <package>`.
2. Put UI, lifecycle, accessibility, notification, device, and other
   platform-owned behavior in the first-party native host.
3. Use FFI for a stable C ABI that needs frequent, low-latency in-process
   calls. Hide `ffi/unsafe` behind a small safe module with explicit ownership,
   callback, thread, ABI, and native-library packaging rules.
4. Use `subprocess` or `system*` for a mature executable doing coarse-grained
   work. Pass an executable and argv directly; never construct a shell command.
   Add a version probe, timeout, bounded/concurrently drained output, exit-code
   handling, cancellation, packaging, and license checks.
5. Use a sidecar only for a persistent runtime, streaming workload, unstable
   ABI, or required crash isolation. Own authentication, protocol versioning,
   resource limits, restart/shutdown, packaging, and offline behavior.
6. Implement the capability only when it is small or security-critical and
   owning it is cheaper than owning the dependency boundary.

For every choice, verify Racket 9.0 CS support, license/redistribution terms,
all target OS/architectures, upstream maintenance, reproducible installation,
failure behavior, packaged dependency closure, and a clean-machine smoke test.

## Ownership

Source you may edit:

- `app/`
- `windows/`
- `macos-host/`
- `linux/`
- `rivet.rktd`
- `rivet-schema.json` when an API compatibility break is intentional
- declared application resources

Generated output you should not hand-edit:

- `windows/GeneratedBackend.hpp`
- `macos-host/Sources/RivetHost/GeneratedBackend.swift`
- `linux/GeneratedBackend.hpp`
- `.rivet/`
- `build/`
- `dist/`
- `windows/Generated Files/`
- `windows/obj/`
- `windows/RivetHost/`
- `macos-host/.build/`

`raco rivet build` regenerates the typed clients. Use `raco rivet clean` to
remove transient build output while keeping the generated client sources that
make the native API reviewable.

## Verification loop

This project includes a source-controlled `rivet-schema.json` API baseline.
Refresh it only after deliberately changing the public backend schema:

```bash
raco rivet schema --output rivet-schema.json
```

Before accepting later API changes, run the compatibility gate. Adding a new
RPC, Event, State, Record, or Enum type is compatible; removing one or changing
a type, argument order, result, Record field/order, or an existing Enum's
cases/order is breaking:

```bash
raco rivet schema check rivet-schema.json --json
```

```bash
raco rivet build
raco rivet dev
raco rivet package
raco rivet verify
```

Pull-request CI must run `raco rivet build` for the Windows, macOS, and Linux
hosts on the same runner image classes used for release. A release job must not
be the first place native source is compiled. Follow Rivet's native-host CI
guide: https://github.com/turinglambdaai/rivet/blob/main/docs/ci.md

After changing RPC, Event, State, Record, or Enum declarations, run the
compatibility gate and rebuild before editing code that consumes generated native APIs.
Update the baseline only when a breaking change is intentional and governed by
the application's release policy. Preserve the first `rivet: error:` line and
nearby compiler output when diagnosing a failure.
## Keyward operating rules (product-specific, override nothing above)

- **Never print a key value.** Values travel backend → clipboard only
  (`entry-get` exists for that single purpose). Listing/check RPCs carry
  names, counts, and fingerprints exclusively — keep it that way; a
  `~a` of the wrong struct in a log line is an incident.
- **The vault is the user's synced INI file.** Keyward is a discipline
  layer over `~/Sync/Keys/secrets.ini`, not a new format and not a
  service. No network code in the engine, ever.
- **Every mutation snapshots first** (`store-snapshot!` before any write);
  writes are atomic (tmp + rename) and end at permission 600.
- **Single-line values are a hard invariant.** `store-set-entry!` rejects
  newlines; multi-line residue must surface as orphan line numbers.
- **Collect, don't scatter.** Generation/import paths write into the vault
  directly; a key file may exist transiently only inside the generation
  call frame.
- The Keys folder itself has its own manual (`~/Sync/Keys/AGENTS.md`) —
  boundary there: product signing keys only, no API tokens.

## 组合定位（Portfolio placement）

- 轨道与授权：轨道 4 社区引流；授权形态：AGPL-3.0；商业归属：永久免费（安全工具开源即信任；家族发布基础设施）。
- 组合归属唯一权威：[PORTFOLIO.md](https://github.com/turinglambdaai/turinglambdaai.github.io/blob/master/PORTFOLIO.md)（turinglambdaai.github.io 仓库）。改归属/授权先改权威档，再同步本节。
- 纪律：价格只进本仓 `PRICING.md`，且收费开始时才发布；README 与产品站不做价格预告。

## 产品交付与下一步（2026-10-23）

- 家族[交付标准](https://github.com/turinglambdaai/turinglambdaai.github.io/blob/master/docs/PRODUCT-STANDARD.md)与[组合策略](https://github.com/turinglambdaai/turinglambdaai.github.io/blob/master/PORTFOLIO.md)是共用政策；本仓具体行为以 `README.md` 为准，不复制五库依赖图。
- 当前执行入口：[产品审查 issue](https://github.com/turinglambdaai/keyward/issues/3)。先保证每个私钥都有独立解析/配对结果，不能用一个正确 key 掩盖同节其他坏 key。维持明文可逃生格式和引擎零网络；用合成临时密钥验证。
- 开工先检查干净工作树与远端，以 fast-forward-only 更新并记录 SHA；共享文件一次一个写入者，保留其他 checkout 的未提交工作。
- 每次只完成一个可验收切片，记录 owned files、依赖 pin、命令/平台/产物证据和回滚。已实现、已发布、实机验收分别陈述；不修改 requirements 或复用旧证据来制造通过。

## Public product documentation

The paired `docs/USER-GUIDE.md` / `docs/USER-GUIDE.zh-CN.md` own the public installation, first-use, data/recovery, privacy and availability path. Keep the homepage and both README entry points aligned with them when behavior changes. Detailed technical contracts and the current implementation queue retain their existing owners. Do not publish target prices, a purchase link or a ready/secure/platform claim before its release evidence exists.
