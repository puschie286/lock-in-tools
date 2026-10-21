# Releasing

Update `## Version` in `LockInTools.toc` to a new `major.minor.patch` version, commit it with the addon changes, and push or merge to the repository's default branch (currently `master`). No manual tag or additional secret is needed: the **Release addon** GitHub Actions workflow uses the repository's built-in token with `contents: write` permission.

The workflow compares the manifest before and after the entire push. Changes to other manifest fields do not publish a release. Feature branches and pull requests do not publish releases. If several versions are included in one push, only the final version is released.

The workflow packages the addon and creates tag `v<version>` at the exact source commit and a GitHub release with generated notes and `LockInTools-<version>.zip`. Versions such as `0.4.0-beta.1` publish as prereleases. Release automation does not install Lua or run tests.

The ZIP extracts into one `LockInTools/` folder, ready to place in `Interface/AddOns/`. It includes the manifest, Lua/XML, media and all bundled library sources and notices. `git archive` packages committed files; root `.gitattributes` rules exclude development files. Keep new development-only paths excluded there, and preserve notices under `Libs/`.

For the first release without a version bump, or to recover a failed run, open **Actions → Release addon → Run workflow** and select the default branch. A manual run releases the version in that branch even when it has not changed. Rerunning the original failed run preserves its source commit. Complete releases can be retried without replacing their ZIP; incomplete drafts can be resumed. A version tag already pointing at another commit causes a failure: use a new version rather than moving the tag or replacing an existing release. GitHub may prevent adding missing assets to an immutable published release.

GitHub Actions must be enabled for the repository, and repository or organization policies must allow the workflow's write permission. No external distribution service is configured.

## Verification

Offline addon verification remains available separately through `.\tools\verify.ps1`; it is not part of the release workflow. After a workflow change, confirm the hosted run and download its ZIP. To use updated workflow code after a failure, start a new **Run workflow** on the default branch after pushing the fix; rerunning the old run uses its original commit.
