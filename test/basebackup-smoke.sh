#!/usr/bin/env bash
# basebackup-smoke.sh - create a physical backup without any CNPG backup plugin.
#
# This checks the no-plugin path that this image is expected to support: the
# core PostgreSQL pg_basebackup binary can create a tar backup from a CNPG-managed
# primary. It intentionally does not exercise CNPG's deprecated in-tree
# barmanObjectStore path, which requires barman-cli-cloud in the PostgreSQL image.

set -euo pipefail

HERE="$(dirname "$(readlink -f "$0")")"
# shellcheck source=test/lib/common.sh
source "${HERE}/lib/common.sh"

PG_MAJOR="$(default_pg_major)"
IMAGE="${IMAGE:-$(default_image "${PG_MAJOR}")}"
KIND_CLUSTER="${KIND_CLUSTER:-pg-distroless}"
CNPG_VERSION="${CNPG_VERSION:-1.29.0}"
NAMESPACE="${NAMESPACE:-default}"
CLUSTER_NAME="${CLUSTER_NAME:-pg-distroless-basebackup}"
BACKUP_DIR="${BACKUP_DIR:-/controller/tmp/basebackup-smoke-$(date +%s)}"

PATH="${HOME}/.local/bin:${PATH}"
export PATH

require_command docker
require_command kind
require_command kubectl

echo ">> ensuring kind cluster ${KIND_CLUSTER}"
ensure_kind_cluster "${KIND_CLUSTER}"
load_image_into_kind "${KIND_CLUSTER}" "${IMAGE}"
install_cnpg_operator "${CNPG_VERSION}"

echo ">> creating no-plugin CNPG cluster ${CLUSTER_NAME}"
kubectl -n "${NAMESPACE}" apply -f - <<YAML
apiVersion: postgresql.cnpg.io/v1
kind: Cluster
metadata:
  name: ${CLUSTER_NAME}
spec:
  instances: 1
  imageName: ${IMAGE}
  imagePullPolicy: Never

  postgresql:
    pg_hba:
      - local replication postgres trust
    parameters:
      shared_buffers: "128MB"
      max_connections: "20"

  bootstrap:
    initdb:
      database: app
      owner: app
      encoding: UTF8
      locale: C
      localeProvider: icu
      icuLocale: en-US-x-icu

  storage:
    size: 1Gi
YAML

echo ">> waiting for ${CLUSTER_NAME} to become ready"
kubectl -n "${NAMESPACE}" wait --for=condition=Ready "cluster/${CLUSTER_NAME}" --timeout=600s

PRIMARY_POD="$(primary_pod "${NAMESPACE}" "${CLUSTER_NAME}")"

echo ">> writing a small row before pg_basebackup"
kubectl -n "${NAMESPACE}" exec "${PRIMARY_POD}" -c postgres -- \
    psql -U postgres -d app -v ON_ERROR_STOP=1 \
    -c "CREATE TABLE IF NOT EXISTS basebackup_smoke(id integer PRIMARY KEY, note text, created_at timestamptz DEFAULT now());" \
    -c "INSERT INTO basebackup_smoke(id, note) VALUES (1, 'basebackup smoke') ON CONFLICT (id) DO UPDATE SET note = EXCLUDED.note, created_at = now();"

echo ">> running pg_basebackup into ${BACKUP_DIR}"
kubectl -n "${NAMESPACE}" exec "${PRIMARY_POD}" -c postgres -- \
    /bin/sh -ec "pg_basebackup -D '${BACKUP_DIR}' -Ft -z -X stream -c fast -v -U postgres && test -s '${BACKUP_DIR}/base.tar.gz' && test -s '${BACKUP_DIR}/pg_wal.tar.gz'"

echo "OK: pg_basebackup created base.tar.gz and pg_wal.tar.gz without a CNPG backup plugin"
