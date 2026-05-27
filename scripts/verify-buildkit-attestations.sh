#!/usr/bin/env bash
# Verify that a published image digest has BuildKit SBOM and provenance attestations.

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

raw="$(docker buildx imagetools inspect --raw "${IMAGE_REF}")"
mapfile -t attestations < <(
    jq -r '
        .manifests[]?
        | select(.annotations["vnd.docker.reference.type"] == "attestation-manifest")
        | .digest
    ' <<< "${raw}"
)

if [[ "${#attestations[@]}" -eq 0 ]]; then
    echo "No BuildKit attestation manifests found for ${IMAGE_REF}" >&2
    exit 1
fi

tmp="$(mktemp)"
cleanup() {
    rm -f "${tmp}"
}
trap cleanup EXIT

for attestation in "${attestations[@]}"; do
    repository="${IMAGE_REF%@*}"
    docker buildx imagetools inspect --raw "${repository}@${attestation}" >> "${tmp}"
    printf '\n' >> "${tmp}"
done

jq -s -e '
    [.[].layers[]?.annotations["in-toto.io/predicate-type"] // empty] as $types
    | any($types[]; test("spdx"; "i"))
    and any($types[]; contains("slsa.dev/provenance"))
' "${tmp}" >/dev/null

echo "OK: verified BuildKit SBOM and provenance attestations for ${IMAGE_REF}"
