#!/usr/bin/env bash
# Update one PostgreSQL major entry in docker-bake.hcl.

set -euo pipefail

usage() {
    cat >&2 <<'USAGE'
usage: scripts/bump-postgres.sh --major <major> <postgres-version>
example: scripts/bump-postgres.sh --major 18 18.4
USAGE
    exit 2
}

MAJOR=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --major)
            [[ $# -ge 2 ]] || usage
            MAJOR="$2"
            shift 2
            ;;
        -h|--help)
            usage
            ;;
        --)
            shift
            break
            ;;
        -*)
            echo "unknown option: $1" >&2
            usage
            ;;
        *)
            break
            ;;
    esac
done

VERSION="${1:-}"
[[ $# -eq 1 ]] || usage
[[ -n "${MAJOR}" && -n "${VERSION}" ]] || usage

if [[ ! "${MAJOR}" =~ ^[0-9]+$ ]]; then
    echo "invalid PostgreSQL major: ${MAJOR}" >&2
    exit 2
fi

if [[ ! "${VERSION}" =~ ^[0-9]+(\.[0-9]+)+$ ]]; then
    echo "invalid PostgreSQL stable version: ${VERSION}" >&2
    exit 2
fi

if [[ "${VERSION%%.*}" != "${MAJOR}" ]]; then
    echo "version ${VERSION} does not match major ${MAJOR}" >&2
    exit 2
fi

BAKE_FILE="${BAKE_FILE:-docker-bake.hcl}"
SHA_URL="https://ftp.postgresql.org/pub/source/v${VERSION}/postgresql-${VERSION}.tar.gz.sha256"

if [[ ! -f "${BAKE_FILE}" ]]; then
    echo "bake file not found: ${BAKE_FILE}" >&2
    exit 2
fi

echo ">> fetching ${SHA_URL}"
SHA="$(curl -fsSL "${SHA_URL}" | awk '{print $1; exit}')"
if [[ ! "${SHA}" =~ ^[0-9a-f]{64}$ ]]; then
    echo "invalid sha256 from ${SHA_URL}: ${SHA}" >&2
    exit 1
fi

VERSION="${VERSION}" MAJOR="${MAJOR}" SHA="${SHA}" perl -0pi -e '
    my $version = $ENV{"VERSION"};
    my $major = $ENV{"MAJOR"};
    my $sha = $ENV{"SHA"};
    my $version_re = qr/"\Q$major\E\.[^"]+"/;

    s/(postgresVersions\s*=\s*\[\s*)(.*?)(\s*\])/
        my ($prefix, $body, $suffix) = ($1, $2, $3);
        $body =~ s($version_re)("$version")
            or die "major $major not found in postgresVersions\n";
        $prefix . $body . $suffix;
    /sex or die "postgresVersions not found\n";

    s/(\n\s*")\Q$major\E\.[^"]+("\s*=\s*")[0-9a-f]{64}(")/
        $1 . $version . $2 . $sha . $3
    /sex or die "major $major not found in postgresSha256\n";
' "${BAKE_FILE}"

echo ">> updated ${BAKE_FILE}"
echo "PG_VERSION=${VERSION}"
echo "PG_MAJOR=${MAJOR}"
echo "PG_TARBALL_SHA256=${SHA}"
