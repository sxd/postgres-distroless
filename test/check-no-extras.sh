#!/usr/bin/env bash
# check-no-extras.sh — assert the image's filesystem matches the allowlist exactly.
# Any file present in the image but not in test/expected-files.txt is a regression;
# any path in the allowlist that's missing from the image is also a regression.
#
# Usage:  ./check-no-extras.sh <image-ref> [path/to/expected-files.txt]
#
# This is how we enforce "as flat as possible" — every file must be justified.

set -euo pipefail

IMAGE="${1:?usage: $0 <image-ref> [expected-files.txt]}"
HERE="$(dirname "$(readlink -f "$0")")"
# shellcheck source=test/lib/common.sh
source "${HERE}/lib/common.sh"

PG_MAJOR="$(default_pg_major)"
PG_BIN_DIR="$(pg_bin_dir "${PG_MAJOR}")"
PG_SHARE_DIR="usr/share/postgresql/${PG_MAJOR}"

if [[ $# -ge 2 ]]; then
    EXPECTED="$2"
    expected_inputs=("${EXPECTED}")
else
    arch="$(docker image inspect --format '{{.Architecture}}' "${IMAGE}" 2>/dev/null | head -n1 || true)"
    case "${arch}" in
        arm64|aarch64)
            EXPECTED="${HERE}/expected-files.arm64.txt"
            ;;
        *)
            EXPECTED="${HERE}/expected-files.txt"
            ;;
    esac
    expected_inputs=("${EXPECTED}")
    PG_EXPECTED="${HERE}/expected-files.pg${PG_MAJOR}.txt"
    if [[ -f "${PG_EXPECTED}" ]]; then
        expected_inputs+=("${PG_EXPECTED}")
    fi
fi

[[ -f "${EXPECTED}" ]] || { echo "expected-files.txt not found: ${EXPECTED}" >&2; exit 2; }

create_args=()
case "${arch:-}" in
    amd64|arm64)
        create_args+=(--platform="linux/${arch}")
        ;;
esac

CID=""
ACTUAL="$(mktemp)"
EXPECTED_SORTED="$(mktemp)"
DIFF="$(mktemp)"

cleanup() {
    if [[ -n "${CID}" ]]; then
        docker rm -f "${CID}" >/dev/null
    fi
    rm -f "${ACTUAL}" "${EXPECTED_SORTED}" "${DIFF}"
}
trap cleanup EXIT

# Scratch image has no CMD/ENTRYPOINT — provide a dummy that's never executed.
CID=$(docker create "${create_args[@]}" --entrypoint="${PG_BIN_DIR}/postgres" "${IMAGE}" --version)

# Dump every non-directory path in the image. Directory presence is implicit from
# the files and symlinks they contain.
# tzdata is enormous (~600 files); we collapse it to a single line so the
# allowlist stays readable.
# Collapse large auto-generated trees into globs so the allowlist is reviewable.
# Anything outside these directories is enumerated individually.
docker export "${CID}" \
    | tar -t \
    | sed -E 's|^\./||' \
    | grep -v '/$' \
    | grep -vE '^(\.dockerenv|dev/console|etc/(hostname|hosts|mtab|resolv\.conf))$' \
    | sed -E "
        s|^usr/share/zoneinfo/.*|usr/share/zoneinfo/*|
        s|^${PG_SHARE_DIR}/timezone/.*|${PG_SHARE_DIR}/timezone/*|
        s|^${PG_SHARE_DIR}/timezonesets/.*|${PG_SHARE_DIR}/timezonesets/*|
        s|^${PG_SHARE_DIR}/tsearch_data/.*|${PG_SHARE_DIR}/tsearch_data/*|
        s|^${PG_SHARE_DIR}/extension/.*|${PG_SHARE_DIR}/extension/*|
      " \
    | sort -u > "${ACTUAL}"

sed "s|\${PG_MAJOR}|${PG_MAJOR}|g" "${expected_inputs[@]}" \
    | sort -u \
    | grep -v '^#' \
    | grep -v '^$' > "${EXPECTED_SORTED}"

if ! diff -u "${EXPECTED_SORTED}" "${ACTUAL}" > "${DIFF}"; then
    echo "FAIL: image filesystem does not match expected-files.txt" >&2
    echo "---" >&2
    cat "${DIFF}" >&2
    exit 1
fi

echo "OK: image contains exactly the files listed in $(basename "${EXPECTED}")"
