#!/usr/bin/env bash
# check-binaries.sh — assert the image contains every binary CNPG requires
# and that each one's dynamic linker resolves cleanly inside the image.
#
# Usage:  ./check-binaries.sh <image-ref>
#
# Exits non-zero on any missing binary, missing library, or unresolved symbol.

set -euo pipefail

HERE="$(dirname "$(readlink -f "$0")")"
# shellcheck source=test/lib/common.sh
source "${HERE}/lib/common.sh"

IMAGE="${1:?usage: $0 <image-ref>}"
PG_MAJOR="$(default_pg_major)"
BIN_DIR="$(pg_bin_dir "${PG_MAJOR}")"

# CNPG instance manager invokes this exact set. If any are missing the operator
# will fail to manage the cluster.
REQUIRED_BINARIES=(
    postgres
    initdb
    pg_ctl
    pg_basebackup
    pg_rewind
    pg_controldata
    pg_resetwal
    pg_archivecleanup
    pg_waldump
    pg_dump
    pg_restore
    pg_isready
    psql
)

# 'scratch' images have no shell or CMD, so we pass a dummy command (never
# executed — docker export only reads the filesystem layers) and mount the
# extracted rootfs into a debian helper that does have ldd.
CID=$(docker create --entrypoint="${BIN_DIR}/postgres" "${IMAGE}" --version)
trap 'docker rm -f "${CID}" >/dev/null' EXIT

WORK=$(mktemp -d)
trap 'docker rm -f "${CID}" >/dev/null; rm -rf "${WORK}"' EXIT
docker export "${CID}" | tar -x -C "${WORK}"

fail=0

for bin in "${REQUIRED_BINARIES[@]}"; do
    path="${WORK}${BIN_DIR}/${bin}"
    if [[ ! -x "${path}" ]]; then
        echo "MISSING binary: ${BIN_DIR}/${bin}" >&2
        fail=1
        continue
    fi
done

# Use a debian helper to ldd each binary against the staged rootfs.
# Bind-mount the extracted rootfs at /target and point ldd at every library
# directory inside it. Running plain `ldd /target/...` would resolve against
# the helper container, not the image filesystem under test.
docker run --rm \
    -v "${WORK}:/target:ro" \
    -e BIN_DIR="${BIN_DIR}" \
    -e REQUIRED_BINARIES="${REQUIRED_BINARIES[*]}" \
    debian:trixie-slim \
    bash -c '
        set -e
        fail=0
        pg_root="${BIN_DIR%/bin}"
        libpath="$(
            find /target/lib /target/usr/lib "/target${pg_root}/lib" \
                -type f \( -name "*.so" -o -name "*.so.*" \) \
                -printf "%h\n" 2>/dev/null \
                | sort -u \
                | paste -sd: -
        )"
        for bin in ${REQUIRED_BINARIES}; do
            path="/target${BIN_DIR}/${bin}"
            [ -x "${path}" ] || continue
            if LD_LIBRARY_PATH="${libpath}" ldd "${path}" 2>&1 | grep -q "not found"; then
                echo "UNRESOLVED libs in ${bin}:"
                LD_LIBRARY_PATH="${libpath}" ldd "${path}" | grep "not found"
                fail=1
            fi
        done
        exit $fail
    ' || fail=1

if (( fail )); then
    echo "FAIL: image is missing required binaries or has unresolved libraries" >&2
    exit 1
fi

echo "OK: all ${#REQUIRED_BINARIES[@]} CNPG-required binaries present with resolved libs"
