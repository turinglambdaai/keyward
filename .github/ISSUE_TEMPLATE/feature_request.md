---
name: Feature request
about: Suggest a capability or improvement for Keyward
title: ''
labels: enhancement
assignees: ''
---

**Is your feature about the vault engine, the macOS app, or the
not-yet-shipped Windows/Linux hosts?**

Keyward is one Racket engine over the synced `secrets.ini` plus native
hosts — saying which layer helps triage. 中文描述完全没问题。

**Problem you're trying to solve**

What are you trying to do with your signing keys that Keyward doesn't
let you (or makes hard)?

**Proposed solution**

What you'd expect. Note the invariants any proposal must keep: values
travel to the clipboard only (never rendered, never logged), every
mutation snapshots first, writes end at permission 600, and the engine
never touches the network.

**Alternatives you've considered**

How do you work around it today?
