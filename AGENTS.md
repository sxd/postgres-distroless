# Agent Handoff

This file is for future LLM/code agents working on this repository. Read it
before changing the image.

## Project Shape

The repository builds scratch PostgreSQL 16, 17, and 18 runtime images for
CloudNativePG.
The important files are:

- `docker-bake.hcl`: source of truth for PostgreSQL versions, checksums, tags,
  target platforms, and build args. The `pg` target is a Bake matrix that
  expands to `pg-16`, `pg-17`, and `pg-18`.
- `Dockerfile`: three-stage build: compile PostgreSQL, collect runtime files,
  copy `/rootfs` into a scratch final image.
- `scripts/collect-rootfs.sh`: collector-stage logic that decides which files
  enter the scratch image.
- `scripts/bump-postgres.sh`: updates one PostgreSQL major's version and source
  tarball checksum in `docker-bake.hcl`.
- `scripts/verify-cosign-signature.sh` and
  `scripts/verify-buildkit-attestations.sh`: local/CI verification for published
  signatures and BuildKit attestations.
- `rootfs/etc/*`: static identity and NSS configuration copied into the image.
- `test/expected-files.txt`: common amd64 filesystem allowlist template.
- `test/expected-files.arm64.txt`: common arm64 filesystem allowlist template.
- `test/expected-files.pg*.txt`: small per-major filesystem allowlist fragments.
- `test/lib/common.sh`: shared PG-major, kind, and CNPG helpers for test scripts.
- `test/*.sh`: image contract and CloudNativePG integration tests.
- `.github/workflows/*.yml`: CI build, test, and publish flows.

## Non-Obvious Runtime Requirements

Do not remove these without replacing the behavior and updating tests:

- `/bin/sh` via `dash`: PostgreSQL tools use shell-backed `popen()`/`system()`.
- `libnss_files.so.2` and `libnss_dns.so.2`: hostname resolution inside CNPG.
- `/usr/share/zoneinfo`: PostgreSQL needs system timezone data.
- `/etc/passwd`, `/etc/group`, `/etc/nsswitch.conf`: postgres UID/GID and NSS.
- `pg_basebackup`, `pg_rewind`, `pg_ctl`, `psql`, and other binaries listed in
  `test/check-binaries.sh`: CNPG expects them.

The final image intentionally has no `ENTRYPOINT` or `CMD`; CNPG invokes
binaries directly.

## Change Guidance

Prefer narrow changes. The repo is a packaging contract, so accidental file
additions to the image are regressions.

When changing the PostgreSQL build flags or installed files:

1. Build a local amd64 image.
2. Run `PG_MAJOR=<major> test/check-binaries.sh localhost/postgres-distroless:<major>`.
3. Run `PG_MAJOR=<major> test/check-no-extras.sh localhost/postgres-distroless:<major>`.
4. If the filesystem diff is legitimate, update the common allowlist or the
   matching `test/expected-files.pg*.txt` fragment with a reviewed explanation.
5. Run at least `test/smoke.sh` before considering the change done.

When bumping PostgreSQL:

1. Run `scripts/bump-postgres.sh --major <major> <version>` or
   `make bump-postgres MAJOR=<major> VERSION=<version>`.
2. Rebuild and run the image contract checks.
3. Run the CNPG smoke tests if the image contract changed.

## Useful Commands

```sh
make print
make test-static
make build-local
make test-image
make test-cnpg
make test-backup-core
make test-backup-plugin
make bump-postgres MAJOR=18 VERSION=18.x
```

Docker/kind tests need access to the host Docker daemon.

## Current Known Gaps

- CI does not run a scheduled rebuild for Debian security refreshes.
- Red Hat/UBI targets are planned but not implemented yet.
