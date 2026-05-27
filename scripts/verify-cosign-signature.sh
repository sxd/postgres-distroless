#!/usr/bin/env bash
# Verify the keyless Cosign signature for a published image digest.

set -euo pipefail

usage() {
    echo "usage: $0 <image@sha256:digest>" >&2
    echo "or set IMAGE and DIGEST in the environment" >&2
}

IMAGE_REF="${1:-}"
if [[ -z "${IMAGE_REF}" && -n "${IMAGE:-}" && -n "${DIGEST:-}" ]]; then
    IMAGE_REF="${IMAGE}@${DIGEST}"
fi
if [[ -z "${IMAGE_REF}" ]]; then
    usage
    exit 2
fi

REPOSITORY="${REPOSITORY:-${GITHUB_REPOSITORY:-}}"
if [[ -z "${REPOSITORY}" ]]; then
    echo "REPOSITORY or GITHUB_REPOSITORY is required, for example sxd/postgres-distroless" >&2
    exit 2
fi

OIDC_ISSUER="${COSIGN_OIDC_ISSUER:-https://token.actions.githubusercontent.com}"
IDENTITY_REGEXP="${COSIGN_CERTIFICATE_IDENTITY_REGEXP:-https://github.com/${REPOSITORY}/\\.github/workflows/publish(-version)?\\.yml@refs/(heads/main|tags/v.*)}"
OUTPUT="${COSIGN_VERIFY_OUTPUT:-cosign-verify.json}"

cosign verify \
    --certificate-identity-regexp "${IDENTITY_REGEXP}" \
    --certificate-oidc-issuer "${OIDC_ISSUER}" \
    "${IMAGE_REF}" \
    > "${OUTPUT}"

jq -e 'length > 0' "${OUTPUT}" >/dev/null
echo "OK: verified Cosign signature for ${IMAGE_REF}"
