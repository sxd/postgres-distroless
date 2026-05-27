#!/usr/bin/env bash
# smoke.sh — end-to-end test: spin a kind cluster, install CNPG, deploy a
# single-instance Cluster using the locally-built distroless PostgreSQL image,
# wait for primary readiness, run SELECT version().
#
# Designed to run on dorothy (or any host with docker + kind + kubectl).
# Does NOT clean up the cluster on success — use `kind delete cluster --name pg-distroless`
# when you're done poking at it.

set -euo pipefail

HERE="$(dirname "$(readlink -f "$0")")"
# shellcheck source=test/lib/common.sh
source "${HERE}/lib/common.sh"

PG_MAJOR="$(default_pg_major)"
PG_BIN_DIR="$(pg_bin_dir "${PG_MAJOR}")"
IMAGE="${IMAGE:-$(default_image "${PG_MAJOR}")}"
KIND_CLUSTER="${KIND_CLUSTER:-pg-distroless}"
CLUSTER_NAME="${CLUSTER_NAME:-pg-distroless-smoke}"
NAMESPACE="${NAMESPACE:-default}"
CNPG_VERSION="${CNPG_VERSION:-1.29.0}"

PATH="${HOME}/.local/bin:${PATH}"
export PATH

require_command docker
require_command kind
require_command kubectl

ensure_kind_cluster "${KIND_CLUSTER}"
load_image_into_kind "${KIND_CLUSTER}" "${IMAGE}"
install_cnpg_operator "${CNPG_VERSION}"

echo ">> applying Cluster CR"
MANIFEST="$(mktemp)"
trap 'rm -f "${MANIFEST}"' EXIT
render_template "${HERE}/cnpg-cluster.yaml" "${MANIFEST}" "${IMAGE}" "${CLUSTER_NAME}" "${NAMESPACE}"
kubectl -n "${NAMESPACE}" apply -f "${MANIFEST}"

echo ">> waiting for primary to become ready (up to 5 min)"
kubectl -n "${NAMESPACE}" wait --for=condition=Ready "cluster/${CLUSTER_NAME}" --timeout=300s

echo ">> running SELECT version() against the primary"
PRIMARY_POD="$(primary_pod "${NAMESPACE}" "${CLUSTER_NAME}")"
kubectl -n "${NAMESPACE}" exec "${PRIMARY_POD}" -c postgres -- \
    "${PG_BIN_DIR}/psql" -U postgres -d app -c 'SELECT version();'

echo "OK: distroless PostgreSQL ${PG_MAJOR} image runs under CNPG"
