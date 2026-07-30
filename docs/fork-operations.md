# Fork operations (karlorz/grok2api)

Operator runbook for this fork of [chenyme/grok2api](https://github.com/chenyme/grok2api).

## Version scheme

| Layer | Example |
|-------|---------|
| Upstream official release | `v3.0.11` |
| First fork cut on that base | `v3.0.11-0` |
| Fork-only revisions | `v3.0.11-1`, … |

`VERSION` at the repo root is the source of truth for About UI / ldflags (`APP_VERSION`).

## Sync latest upstream release → fork tag

Shared script (humans + CI):

```bash
# Plan only
make sync-upstream DRY_RUN=1
# Merge + commit locally
make sync-upstream
# Merge, push main, cut GitHub Release
make sync-upstream PUSH=1 RELEASE=1
```

Or call the script directly:

```bash
./scripts/sync-upstream-release.sh --push --release
```

Behavior:

- Reads latest release from `chenyme/grok2api`
- No-ops when fork `VERSION` already covers that base
- Merges the upstream release tag; auto-resolves **only** a sole `VERSION` conflict to `vX.Y.Z-0`
- Aborts cleanly on any other merge conflict (no force-resolve)
- Optional `--push` / `--release` (uses `scripts/fork-tag.sh --release`)

### Scheduled GitHub Action

Workflow: [`.github/workflows/sync-upstream-release.yml`](../.github/workflows/sync-upstream-release.yml)

- **Schedule:** daily `15 6 * * *` (06:15 UTC)
- **Manual:** Actions → “Sync upstream release” (`workflow_dispatch`)
  - `dry_run` — plan only
  - `skip_release` — push main without cutting a release
- **Permissions:** `contents: write`
- **Does not deploy to kr01** (no host SSH secrets in CI)

## Binary deploy on kr01

Target: ARM64 host `kr01`, install path `/opt/grok2api`, public health `https://grok2api.karldigi.dev/healthz`.

| Command | When |
|---------|------|
| `make deploy` | First install / full setup (config, systemd, Caddy) |
| `make update` | Routine rebuild + roll out |
| `make status` | Read-only SHA + health probe |
| `make upgrade-kr01` | Thin wrapper: pull + `update` + `status` (default `HOST=kr01`) |

### Curl one-liner (build host with SSH to kr01 + Go/pnpm)

```bash
curl -fsSL https://raw.githubusercontent.com/karlorz/grok2api/main/scripts/upgrade-kr01.sh | bash
```

Requires a machine that can **cross-compile** `linux/arm64` and SSH to `kr01`. It is not meant to run *on* kr01 without those toolchains.

Useful env:

```bash
HOST=kr01 FORCE=1 make update   # rebuild even if SHA matches
SKIP_BUILD=1 make update        # reuse ./dist
SYNC_UPSTREAM=1 make update     # also merge upstream/main (advanced)
DRY_RUN=1 ./scripts/upgrade-kr01.sh
```

## Make targets (fork)

```text
make version-next              # print next fork tag
make version-bump              # write next into VERSION
make version-bump BASE=v3.1.0  # start new series at v3.1.0-0
make version-release           # tag + GitHub Release from VERSION
make sync-upstream             # see above
make upgrade-kr01              # see above
make test-scripts              # fork_version + workflow wiring tests
```

## Related scripts

- `scripts/lib/fork_version.sh` — pure version helpers
- `scripts/sync-upstream-release.sh` — upstream release → fork VERSION/tag
- `scripts/fork-tag.sh` — fork tag / release
- `scripts/update.sh` / `scripts/deploy.sh` / `scripts/status.sh` / `scripts/common.sh`
- `scripts/upgrade-kr01.sh` — curl entry for kr01 upgrade
