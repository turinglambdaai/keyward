---
name: Bug report
about: Something in Keyward is broken or behaves differently from the handbook
title: ''
labels: bug
assignees: ''
---

**Describe the bug**

A clear description of what happened and what you expected instead.
中文描述完全没问题 — 写清楚即可。

**To reproduce**

Steps that trigger the behavior (which operation: open vault, deep
check, snapshot restore, entry set/copy, import, keypair generation):

```
command / menu path / the vault section involved
```

**Environment**

- Platform: macOS (version) — Windows/Linux builds exist in-tree but do
  not ship yet; say so explicitly if you built one yourself
- Keyward version: (Help ▸ About, or the release tag)
- Vault location: default family path or user-chosen (path itself is
  fine to share — the contents are not)

**Security note — redact key material**

Never paste a key value, a private key, or a vault section body.
Fingerprints (`*_FPR`, the sha256-derived first-16-hex form) and section
names are safe and are exactly what the maintainer needs.

**Screenshots / logs**

If applicable, add screenshots or console output (redacted per above).
