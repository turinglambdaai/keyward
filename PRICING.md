# Keyward product and pricing plan

**English** · [简体中文](PRICING.zh-CN.md)

## Launch status and implementation boundaries

- Policy version: `2026-10-v2`, 2026-10-23. The owner confirmed that every product is still in development and has no actual users. This document replaces conflicting previous pricing, early-bird and Pro proposals; there is no existing customer cohort to migrate. **Prices are launch targets, not live offers or claims that the listed features are implemented.**
- Entitlements cover delivered platforms only. New commercial plans do not change the LICENSE of released source. Source use, modification and redistribution rights are separate from official products, updates and services.
- Security fixes and reading, backing up or exporting your own data must not require another purchase. BYOK keys, payment-provider secrets and issuer private keys have different owners. Native hosts do not collect payment or issue credentials directly.

## Decision

**Free security and release infrastructure**

Launch target: **¥0 / US$0**. CNY and USD are independently set regional targets, not a live exchange-rate conversion.

Keep billing and support complexity out of small tools. Build community trust through usable products and concentrate revenue work on a few paid products.

## Free and paid scope

Free / evaluation: Local key management, validation, release assistance and diagnostics are free. Do not charge by key count, for security fixes or for export; do not expand this product into cloud key custody. AGPL rights remain unchanged.

Paid: No paid tier is planned. Do not integrate Commerce or add Permit product gates.

## Next gate before sales

Complete delivery/maintenance gates in #3 first. Free pricing does not reduce signed-update, recovery or privacy requirements.

Execution entry: [issue #3](https://github.com/turinglambdaai/keyward/issues/3). Complete this bounded slice before expanding commercial features.

Portfolio role and shared boundaries: [PORTFOLIO](https://github.com/turinglambdaai/turinglambdaai.github.io/blob/master/PORTFOLIO.md).
