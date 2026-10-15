# Groups

One account-wide key identifies your friends across all features. Open settings with `/lit` or `/lit options`; `/lit help` lists commands, `/lit status` shows the public fingerprint and feature state, and `/lit welcome on|off` controls the login message.

## Setup

1. Open `/lit` and click **Create group** to prepare a selected key such as `otter-4827`.
2. Click **Use key** to save it; creating a key alone keeps the current group.
3. Share it with friends, who enter the same key and click **Use key**. Configure each feature separately.

## Key management

- **Show key** reveals the field for Ctrl+C. Closing settings clears and masks the field; the saved key remains.
- Switching groups and **Leave group** require confirmation and affect every feature. [Leaving chat](shared-chat.md) keeps your group.
- Custom keys: 3–40 ASCII letters/digits, with single hyphens between them. Case and surrounding whitespace are ignored. The reserved `lit1-` prefix supports legacy codes without changing their identity or credentials.
- Generated keys use ordinary randomness and are guessable. All holders have equal authority; change keys to remove access. Keys persist in `LockInToolsDB`, readable on disk and by other addons.

## Implementation and settings

`Group.lua` generates/validates keys; `Crypto.lua` uses distinct versioned HKDF-SHA256 labels for the fingerprint, channel/password and authentication root/feature-specific HMAC keys. Keys are not broadcast; fingerprints compare groups without authenticating peers.

Signing helpers cover exact payload bytes without encryption. Future protocols must define serialization, sender identity, freshness and replay protection.

`Core.lua` loads schema 3 settings on `ADDON_LOADED`, then derives the group. Reload/logout persists settings. Migration preserves welcome/autojoin and unrelated fields; old channel names remain stored but unused (enter a key). Newer schemas remain intact with temporary defaults and saved edits blocked. `Options.lua`/`Commands.lua` expose controls.

## In-game checks

- Compare fingerprints after entering the same key with different case/whitespace; reload, relog and change characters. Existing `LIT1-` groups must retain their fingerprint and channel.
- Verify create versus save, copy/masking, switch/leave confirmations, help/status/welcome, and unsaved fields surviving notices. Switching/leaving groups must leave the previous group channel, including restored membership, while preserving unrelated channels.
