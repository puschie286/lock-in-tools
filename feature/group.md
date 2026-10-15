# Groups

One account-wide key identifies your friends across all features. Open the welcome screen with `/lit` or `/lit welcome`, and settings with `/lit options`. `/lit help` lists commands, `/lit status` shows the public fingerprint and feature state, and `/lit welcome on|off` controls the login message and automatic initial welcome screen.

## Setup

1. On your first login, the welcome screen creates and saves a key such as `otter-4827`. Existing groups keep their key. Reopen the screen anytime with `/lit`.
2. Your saved key is visible under **Your secret key**. Click **Select key**, then press Ctrl+C to copy and share it.
3. To use a friend's key instead, enter it under **Have a friend's key?**, click **Join friend**, then **Confirm switch** to replace your current group. Your displayed key updates to the shared key. Shared chat joins automatically when autojoin is enabled.
4. Click **Done** to close, or **More options** for group management and feature settings.

## Key management

- The welcome screen shows your saved key in a selectable field that cannot change the saved key. Closing clears both displayed keys; the saved key remains.
- In `/lit options`, **Create group** prepares a new key; **Use key** saves it. **Show key** reveals the field for Ctrl+C. Closing settings clears and masks the field.
- Switching groups and **Leave group** require confirmation and affect every feature. [Leaving chat](shared-chat.md) keeps your group.
- Custom keys: 3–40 ASCII letters/digits, with single hyphens between them. Case and surrounding whitespace are ignored. The reserved `lit1-` prefix supports legacy codes without changing their identity or credentials.
- Generated keys use ordinary randomness and are guessable. All holders have equal authority; change keys to remove access. Keys persist in `LockInToolsDB`, readable on disk and by other addons.

## Implementation and settings

`Group.lua` generates/validates keys; `Crypto.lua` uses distinct versioned HKDF-SHA256 labels for the fingerprint, channel/password and authentication root/feature-specific HMAC keys. Keys are not broadcast; fingerprints compare groups without authenticating peers.

Signing helpers cover exact payload bytes without encryption. Future protocols must define serialization, sender identity, freshness and replay protection.

`Core.lua` loads schema 3 settings on `ADDON_LOADED`, then derives the group. At login, an unconfigured player with welcome enabled sees the welcome screen. Opening it creates a key only when no key is saved; invalid saved keys stay intact for correction. Reload/logout persists settings. Migration preserves welcome/autojoin and unrelated fields; old channel names remain stored but unused. Newer schemas remain intact with temporary defaults and saved edits blocked. `Options.lua`/`Commands.lua` expose controls.

## In-game checks

- Compare fingerprints after entering the same key with different case/whitespace; reload, relog and change characters. Existing `LIT1-` groups must retain their fingerprint and channel.
- On a fresh install, check that welcome opens once with a visible saved key and shared chat begins joining. Copy the key, reload and reopen `/lit`; it must stay the same. Join a friend's key and verify confirmation, the updated displayed key and the new chat channel. Check layout at different UI scales, Escape/close cleanup, and **More options**.
- Verify create versus save, copy/masking, switch/leave confirmations, help/status/welcome, and unsaved fields surviving notices. Switching/leaving groups must leave the previous group channel, including restored membership, while preserving unrelated channels.
