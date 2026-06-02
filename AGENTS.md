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

**Never conclude "upstream superseded the fork" from a diff alone — verify at
runtime.** Concrete burn (2026-06-02): dataplicity's fork
`fix/dataplicity-modern-api` looked like upstream v1.3.0 had merged the same
provisioning fix, so it was switched to clean v1.3.0. But v1.3.0 reintroduces
the `api.dataplicity.com` **403** (agent disk-poll/sync rejected) — the fork's
`install_package` pins `lomond==0.3.3` with `--no-deps`, which v1.3.0 lacks.
Keep dataplicity on the fork. If you must change a fork, restart HA and confirm
the feature actually works before declaring the upstream equivalent.

## Updating HACS-tracked integrations — the ONLY correct procedure

These submodule integrations are ALSO tracked by HACS (HACS shows them under
"installed" with an `update.<name>_update` entity). The two systems fight:

1. **NEVER update via HACS** — not the HACS UI "Update", not the
   `update.install` service on `update.<name>_update`. HACS downloads the repo's
   upstream release and overwrites the submodule working tree, **destroying the
   fork/patch** (e.g. dataplicity's 403 fix, YandexStation's local-IP fix).
2. **Update via git only** (per the rebase rules above): rebase the fork branch
   onto upstream / fast-forward a plain submodule, bump `manifest.json` `version`
   if upstream did, restart HA, verify the feature works.
3. **After a git update, HACS still shows a phantom "update available"** because
   HACS keeps its own `version_installed` (set the last time it installed via
   HACS) and does NOT re-read it from the updated submodule. You must sync it.

**Syncing HACS so HA sees the integration as up to date** (clears the phantom):
edit `.storage/hacs.repositories` — for the repo (match `full_name`), set
`version_installed` = `last_version` and `installed_commit` = `last_commit`.

Tooling for that edit (`.storage` is **root-owned**; the host user has **no
passwordless sudo**; and HA **rewrites `.storage` on graceful shutdown**, so a
normal restart loses hand-edits):
- Edit from inside the container as root: `docker exec <ha-container> python3`
  (json load → set fields → json dump to `/config/.storage/hacs.repositories`),
  validate the JSON.
- Apply WITHOUT a graceful shutdown: `docker kill <ha-container> && docker start
  <ha-container>` (SIGKILL skips the shutdown write, so HA reads your edit on
  next boot). A plain `homeassistant.restart` would overwrite it.
- Verify `update.<name>_update` flips to `off` (state `on` = still pending).

The same `.storage`-edit-then-kill+start pattern is the only way to hand-edit
any root-owned `.storage` file (entity_registry, config_entries, hacs.*) without
sudo. For entity renames prefer the WS API (`config/entity_registry/update`,
`new_entity_id`) — HA writes it itself, no kill needed.
