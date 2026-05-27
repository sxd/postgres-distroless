#!/usr/bin/env bash
# Assemble the scratch rootfs from a PostgreSQL install tree and the minimum
# runtime files PostgreSQL/CNPG need.

set -euo pipefail

OUT_DIR="${OUT_DIR:-/out}"
ROOTFS="${ROOTFS:-/rootfs}"
STATIC_ROOTFS="${STATIC_ROOTFS:-/rootfs-static}"
: "${PG_MAJOR:?PG_MAJOR is required}"

PG_ROOT="${ROOTFS}/usr/lib/postgresql/${PG_MAJOR}"
PG_BIN_DIR="${PG_ROOT}/bin"
PG_LIB_DIR="${PG_ROOT}/lib"

copy_runtime_path() {
    local src="$1"
    local dst="${ROOTFS}${src}"

    if [[ ! -e "${src}" ]]; then
        echo "missing runtime path: ${src}" >&2
        exit 1
    fi

    mkdir -p "$(dirname "${dst}")"
    cp -aL "${src}" "${dst}"
}

mkdir -p "${ROOTFS}"

# Copy the PostgreSQL install tree as-is.
cp -a "${OUT_DIR}/usr" "${ROOTFS}/usr"

# Walk PostgreSQL binaries and shared libraries and collect their resolved
# runtime library paths.
# shellcheck disable=SC2016
find "${PG_BIN_DIR}" "${PG_LIB_DIR}" \
    -type f \( -executable -o -name '*.so*' \) -print0 \
    | xargs -0 -r -I{} sh -c 'ldd "$1" 2>/dev/null || true' _ {} \
    | awk '/=>/ && $3 ~ /^\// {print $3}' \
    | sort -u > /tmp/libs.list

while IFS= read -r lib; do
    [[ -f "${lib}" ]] || continue
    copy_runtime_path "${lib}"
done < /tmp/libs.list

# Copy the ELF interpreter requested by the built postgres binary. This avoids
# architecture-specific loader paths in the Dockerfile.
loader="$(
    readelf -l "${PG_BIN_DIR}/postgres" \
        | sed -n 's/.*interpreter: \(.*\)]/\1/p' \
        | head -n1
)"
if [[ -z "${loader}" ]]; then
    echo "unable to discover dynamic loader from ${PG_BIN_DIR}/postgres" >&2
    exit 1
fi
copy_runtime_path "${loader}"

# NSS modules for hostname-based pg_hba and replication DNS.
nss_files="$(find /lib /usr/lib -maxdepth 4 -name 'libnss_files.so.2' -type f | head -n1)"
if [[ -z "${nss_files}" ]]; then
    echo "unable to locate libnss_files.so.2" >&2
    exit 1
fi
nss_dir="$(dirname "${nss_files}")"
copy_runtime_path "${nss_dir}/libnss_files.so.2"
copy_runtime_path "${nss_dir}/libnss_dns.so.2"

# System timezone data.
mkdir -p "${ROOTFS}/usr/share/zoneinfo"
cp -a /usr/share/zoneinfo/. "${ROOTFS}/usr/share/zoneinfo/"

# /bin/sh is required by PostgreSQL tools that call popen()/system().
mkdir -p "${ROOTFS}/bin"
cp -aL /bin/dash "${ROOTFS}/bin/dash"
ln -sf dash "${ROOTFS}/bin/sh"

# Static identity/NSS configuration.
mkdir -p "${ROOTFS}/etc"
cp -a "${STATIC_ROOTFS}/etc/." "${ROOTFS}/etc/"

# Runtime directories with correct mode/owner.
install -d -m 0700 -o 26 -g 26 "${ROOTFS}/var/lib/postgresql/data"
install -d -m 0775 -o 26 -g 26 "${ROOTFS}/var/run/postgresql"
install -d -m 1777 "${ROOTFS}/tmp"

# Drop build-time-only and non-CNPG artifacts to keep the image flat.
rm -rf "${ROOTFS}/usr/include"
find "${PG_LIB_DIR}" -name '*.a' -delete
rm -rf "${PG_LIB_DIR}/pkgconfig"
rm -rf "${PG_LIB_DIR}/pgxs"

# ECPG is a client-side build tool, not part of the server runtime contract.
rm -f "${PG_BIN_DIR}/ecpg"
find "${PG_LIB_DIR}" -maxdepth 1 \
    \( -name 'libecpg*' -o -name 'libpgtypes*' \) -delete

# Misc utilities CNPG never invokes.
rm -f "${PG_BIN_DIR}/oid2name" \
      "${PG_BIN_DIR}/vacuumlo" \
      "${PG_BIN_DIR}/pgbench" \
      "${PG_BIN_DIR}/pg_test_fsync" \
      "${PG_BIN_DIR}/pg_test_timing"

# Doc tree contains extension examples and is not consulted at runtime.
rm -rf "${ROOTFS}/usr/share/postgresql/${PG_MAJOR}/doc"

# Strip anything meson --strip or install-time strip did not catch.
find "${PG_ROOT}" -type f \( -executable -o -name '*.so*' \) \
    -exec sh -c 'file -b "$1" | grep -q "not stripped" && strip --strip-unneeded "$1" || true' _ {} \;
