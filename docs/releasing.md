# Releasing mroom

A release is a git tag `vX.Y.Z` on `main` plus a GitHub release for it. `install.sh --version vX.Y.Z`
installs from that release's source tarball, and refuses it if the tarball's `VERSION` is not `X.Y.Z`.
The developer cuts releases by hand; no workflow and no agent creates tags or releases.

1. **Bump `VERSION`** in a pull request (for example `0.1.0` to `0.2.0`), and the plugin's
   `version` in `plugin/.claude-plugin/plugin.json` to match (`tests/guard-test.sh` checks), with a
   Conventional Commit title such as `chore: release 0.2.0`. Merge it once CI is green.
2. **Tag the merge commit on `main`** and push the tag:

   ```bash
   git switch main && git pull --ff-only
   test "v$(cat VERSION)" = v0.2.0          # the tag must match VERSION
   git tag -a v0.2.0 -m "mroom v0.2.0"
   git push origin v0.2.0
   ```

   CI runs on the tag too, and its lint job fails if the tag and `VERSION` disagree.
3. **Create the GitHub release** from the tag, with notes from the merged pull requests:

   ```bash
   gh release create v0.2.0 --repo milroyfraser/mroom --verify-tag --generate-notes --title "mroom v0.2.0"
   ```

4. **Check it installs** on a box:

   ```bash
   ./install.sh --version v0.2.0 && mroom version     # prints 0.2.0
   ```

`install.sh --version` downloads with `gh` when it is signed in; without it, a
public repository installs with plain `curl`.

Versions follow semver: while mroom is `0.x`, a minor bump may break `mroom.toml` or the CLI, and the
release notes say how. A broken release is fixed with a new patch release, never by moving a tag.
