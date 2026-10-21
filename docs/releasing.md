# Releasing

Update `## Version` in `LockInTools.toc` to a new `major.minor.patch` version, commit it with the addon changes, and push or merge to the repository's default branch (currently `master`). No manual tag or additional secret is needed: the **Release addon** GitHub Actions workflow uses the repository's built-in token with `contents: write` permission.

The workflow compares the manifest before and after the entire push. Changes to other manifest fields do not publish a release. Feature branches and pull requests do not publish releases. If several versions are included in one push, only the final version is released.

Before publishing, it installs the pinned local Lua 5.1 runtime and runs `tools/verify.ps1`. A failed check prevents publication. It then creates tag `v<version>` at the exact checked commit and a GitHub release with generated notes and `LockInTools-<version>.zip`. Versions such as `0.4.0-beta.1` publish as prereleases.

The ZIP extracts into one `LockInTools/` folder, ready to place in `Interface/AddOns/`. It includes the manifest, Lua/XML, media and all bundled library sources and notices. `git archive` packages committed files; root `.gitattributes` rules exclude development files. Keep new development-only paths excluded there, and preserve notices under `Libs/`.

For the first release without a version bump, or to recover a failed run, open **Actions → Release addon → Run workflow** and select the default branch. A manual run releases the version in that branch even when it has not changed. Rerunning the original failed run preserves its source commit. Complete releases can be retried without replacing their ZIP; incomplete drafts can be resumed. A version tag already pointing at another commit causes a failure: use a new version rather than moving the tag or replacing an existing release. GitHub may prevent adding missing assets to an immutable published release.

GitHub Actions must be enabled for the repository, and repository or organization policies must allow the workflow's write permission. No external distribution service is configured.

## Verification

Run `.\tools\verify.ps1` for offline addon verification. The packaging step also checks every manifest entry, every bundled library/media file, the addon folder layout and development-file exclusions before any upload. A successful local check does not validate GitHub's token policies or an actual hosted release; confirm the first hosted run and download its ZIP after the workflow reaches the default branch.
