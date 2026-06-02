# Agent Instructions

- Make atomic commits: each commit should contain one coherent change.
- Read `CLAUDE.md` before making repository changes and follow its project notes.
- Review staged changes before every commit with `git diff --staged`.
- Run `git diff --staged --check` before committing to catch whitespace and patch issues.
- Do not stage unrelated work unless the user explicitly asks to commit the current workspace checkpoint.
- **Never bypass git hooks** — do not use `git commit --no-verify` / `-n` (or
  `git push --no-verify`). The HA repo's pre-commit hook validates YAML with a
  HA-aware loader (`scripts/ha_validate_yaml.sh`, handles `!include`/`!secret`/
  `!input`), so a failure is a REAL error, not a false positive — fix the YAML
  instead of skipping the hook. A bad config has put HA into recovery mode
  before (2026-05-19); the hook exists to prevent exactly that.

## Updating forked / locally-patched submodules

Several HA integrations under `/home/ultra/homeassistant/submodules/` are git
submodules pinned to **forks or local patches** that fix bugs upstream doesn't
(e.g. YandexStation has a local "manual local speaker IP fallback for Docker
networks" commit; dataplicity is on `fix/dataplicity-modern-api`;
home-generative-agent is on a `tv-noise-filter` fork branch). **Never update
these by replacing them with upstream** — that reintroduces the exact bugs the
fork fixes.

To update a forked/patched submodule: **rebase the local branch onto the latest
upstream**, preserving the local commits on top. Fetch upstream, rebase the
fork branch onto upstream's release tag/HEAD, resolve conflicts, then restart
HA and verify the patched behavior still works. Only plain-upstream pinned
submodules (no local commits) may be fast-forwarded directly.
