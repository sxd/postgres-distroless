#!/usr/bin/env bash
# backup-smoke.sh - create a CNPG physical backup through the Barman Cloud plugin.
#
# This deliberately keeps backup tooling out of the PostgreSQL image. The backup
# runs through the CNPG-I Barman Cloud sidecar and writes to an in-cluster MinIO
# bucket created only for this smoke test.

set -euo pipefail

HERE="$(dirname "$(readlink -f "$0")")"
# shellcheck source=test/lib/common.sh
source "${HERE}/lib/common.sh"

PG_MAJOR="$(default_pg_major)"
IMAGE="${IMAGE:-$(default_image "${PG_MAJOR}")}"
KIND_CLUSTER="${KIND_CLUSTER:-pg-distroless}"
CNPG_VERSION="${CNPG_VERSION:-1.29.0}"
CERT_MANAGER_VERSION="${CERT_MANAGER_VERSION:-v1.20.2}"
BARMAN_PLUGIN_VERSION="${BARMAN_PLUGIN_VERSION:-v0.12.0}"
BARMAN_SIDECAR_IMAGE="${BARMAN_SIDECAR_IMAGE:-ghcr.io/cloudnative-pg/plugin-barman-cloud-sidecar:${BARMAN_PLUGIN_VERSION}}"
MINIO_IMAGE="${MINIO_IMAGE:-quay.io/minio/minio:RELEASE.2025-09-07T16-13-09Z}"
MC_IMAGE="${MC_IMAGE:-minio/mc@sha256:a7fe349ef4bd8521fb8497f55c6042871b2ae640607cf99d9bede5e9bdf11727}"

NAMESPACE="${NAMESPACE:-default}"
CLUSTER_NAME="${CLUSTER_NAME:-pg-distroless-backup}"
OBJECT_STORE_NAME="${OBJECT_STORE_NAME:-pg-distroless-backup-store}"
BACKUP_NAME="${BACKUP_NAME:-pg-distroless-backup-$(date +%s)}"
MINIO_SECRET="${MINIO_SECRET:-minio}"
MINIO_BUCKET="${MINIO_BUCKET:-backups}"
MINIO_ACCESS_KEY="${MINIO_ACCESS_KEY:-minioadmin}"
MINIO_SECRET_KEY="${MINIO_SECRET_KEY:-minioadmin}"

PATH="${HOME}/.local/bin:${PATH}"
export PATH

require_command docker
require_command kind
require_command kubectl

echo ">> ensuring kind cluster ${KIND_CLUSTER}"
ensure_kind_cluster "${KIND_CLUSTER}"
load_image_into_kind "${KIND_CLUSTER}" "${IMAGE}"
install_cnpg_operator "${CNPG_VERSION}"

echo ">> installing cert-manager (${CERT_MANAGER_VERSION})"
kubectl apply -f \
    "https://github.com/cert-manager/cert-manager/releases/download/${CERT_MANAGER_VERSION}/cert-manager.yaml"
kubectl -n cert-manager rollout status deploy/cert-manager --timeout=180s
kubectl -n cert-manager rollout status deploy/cert-manager-cainjector --timeout=180s
kubectl -n cert-manager rollout status deploy/cert-manager-webhook --timeout=180s

echo ">> installing Barman Cloud plugin (${BARMAN_PLUGIN_VERSION})"
kubectl apply -f \
    "https://github.com/cloudnative-pg/plugin-barman-cloud/releases/download/${BARMAN_PLUGIN_VERSION}/manifest.yaml"
kubectl -n cnpg-system rollout status deploy/barman-cloud --timeout=180s

echo ">> loading Barman Cloud sidecar ${BARMAN_SIDECAR_IMAGE} into kind"
docker pull "${BARMAN_SIDECAR_IMAGE}"
kind load docker-image --name "${KIND_CLUSTER}" "${BARMAN_SIDECAR_IMAGE}"

echo ">> deploying MinIO object store"
kubectl -n "${NAMESPACE}" apply -f - <<YAML
apiVersion: v1
kind: Secret
metadata:
  name: ${MINIO_SECRET}
type: Opaque
stringData:
  ACCESS_KEY_ID: ${MINIO_ACCESS_KEY}
  ACCESS_SECRET_KEY: ${MINIO_SECRET_KEY}
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: minio
spec:
  replicas: 1
  selector:
    matchLabels:
      app: minio
  template:
    metadata:
      labels:
        app: minio
    spec:
      containers:
        - name: minio
          image: ${MINIO_IMAGE}
          args:
            - server
            - /data
            - --console-address
            - :9001
          env:
            - name: MINIO_ROOT_USER
              valueFrom:
                secretKeyRef:
                  name: ${MINIO_SECRET}
                  key: ACCESS_KEY_ID
            - name: MINIO_ROOT_PASSWORD
              valueFrom:
                secretKeyRef:
                  name: ${MINIO_SECRET}
                  key: ACCESS_SECRET_KEY
          ports:
            - name: api
              containerPort: 9000
            - name: console
              containerPort: 9001
          readinessProbe:
            httpGet:
              path: /minio/health/ready
              port: api
            initialDelaySeconds: 3
            periodSeconds: 2
          volumeMounts:
            - name: data
              mountPath: /data
      volumes:
        - name: data
          emptyDir: {}
---
apiVersion: v1
kind: Service
metadata:
  name: minio
spec:
  selector:
    app: minio
  ports:
    - name: api
      port: 9000
      targetPort: api
    - name: console
      port: 9001
      targetPort: console
YAML
kubectl -n "${NAMESPACE}" rollout status deploy/minio --timeout=180s

echo ">> creating MinIO bucket ${MINIO_BUCKET}"
kubectl -n "${NAMESPACE}" delete job minio-create-bucket --ignore-not-found
kubectl -n "${NAMESPACE}" apply -f - <<YAML
apiVersion: batch/v1
kind: Job
metadata:
  name: minio-create-bucket
spec:
  backoffLimit: 6
  template:
    spec:
      restartPolicy: OnFailure
      containers:
        - name: mc
          image: ${MC_IMAGE}
          command: ["/bin/sh", "-ec"]
          args:
            - |
              mc alias set local http://minio:9000 "\${MINIO_ROOT_USER}" "\${MINIO_ROOT_PASSWORD}"
              mc mb --ignore-existing "local/${MINIO_BUCKET}"
              mc ls "local/${MINIO_BUCKET}"
          env:
            - name: MINIO_ROOT_USER
              valueFrom:
                secretKeyRef:
                  name: ${MINIO_SECRET}
                  key: ACCESS_KEY_ID
            - name: MINIO_ROOT_PASSWORD
              valueFrom:
                secretKeyRef:
                  name: ${MINIO_SECRET}
                  key: ACCESS_SECRET_KEY
YAML
kubectl -n "${NAMESPACE}" wait --for=condition=complete job/minio-create-bucket --timeout=180s

echo ">> configuring Barman ObjectStore ${OBJECT_STORE_NAME}"
kubectl -n "${NAMESPACE}" apply -f - <<YAML
apiVersion: barmancloud.cnpg.io/v1
kind: ObjectStore
metadata:
  name: ${OBJECT_STORE_NAME}
spec:
  configuration:
    destinationPath: s3://${MINIO_BUCKET}/${CLUSTER_NAME}
    endpointURL: http://minio:9000
    s3Credentials:
      accessKeyId:
        name: ${MINIO_SECRET}
        key: ACCESS_KEY_ID
      secretAccessKey:
        name: ${MINIO_SECRET}
        key: ACCESS_SECRET_KEY
    wal:
      compression: gzip
    data:
      compression: gzip
  instanceSidecarConfiguration:
    env:
      - name: AWS_REQUEST_CHECKSUM_CALCULATION
        value: when_required
      - name: AWS_RESPONSE_CHECKSUM_VALIDATION
        value: when_required
YAML

echo ">> creating plugin-enabled CNPG cluster ${CLUSTER_NAME}"
kubectl -n "${NAMESPACE}" apply -f - <<YAML
apiVersion: postgresql.cnpg.io/v1
kind: Cluster
metadata:
  name: ${CLUSTER_NAME}
spec:
  instances: 1
  imageName: ${IMAGE}
  imagePullPolicy: Never

  plugins:
    - name: barman-cloud.cloudnative-pg.io
      isWALArchiver: true
      parameters:
        barmanObjectName: ${OBJECT_STORE_NAME}

  postgresql:
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

echo ">> writing a small row before backup"
PRIMARY_POD="$(primary_pod "${NAMESPACE}" "${CLUSTER_NAME}")"
kubectl -n "${NAMESPACE}" exec "${PRIMARY_POD}" -c postgres -- \
    psql -U postgres -d app -v ON_ERROR_STOP=1 \
    -c "CREATE TABLE IF NOT EXISTS backup_smoke(id integer PRIMARY KEY, note text, created_at timestamptz DEFAULT now());" \
    -c "INSERT INTO backup_smoke(id, note) VALUES (1, 'backup smoke') ON CONFLICT (id) DO UPDATE SET note = EXCLUDED.note, created_at = now();" \
    -c "SELECT pg_switch_wal();"

echo ">> creating Backup ${BACKUP_NAME}"
kubectl -n "${NAMESPACE}" apply -f - <<YAML
apiVersion: postgresql.cnpg.io/v1
kind: Backup
metadata:
  name: ${BACKUP_NAME}
spec:
  cluster:
    name: ${CLUSTER_NAME}
  method: plugin
  target: primary
  online: true
  onlineConfiguration:
    immediateCheckpoint: true
    waitForArchive: true
  pluginConfiguration:
    name: barman-cloud.cloudnative-pg.io
YAML

echo ">> waiting for Backup ${BACKUP_NAME} to complete"
for _ in $(seq 1 120); do
    phase="$(kubectl -n "${NAMESPACE}" get backup "${BACKUP_NAME}" -o jsonpath='{.status.phase}' 2>/dev/null || true)"
    phase_lc="$(printf '%s' "${phase}" | tr '[:upper:]' '[:lower:]')"
    case "${phase_lc}" in
        completed|completed*)
            echo ">> backup phase: ${phase}"
            break
            ;;
        failed|failed*)
            echo "FAIL: backup entered phase ${phase}" >&2
            kubectl -n "${NAMESPACE}" describe backup "${BACKUP_NAME}" >&2 || true
            kubectl -n "${NAMESPACE}" get backup "${BACKUP_NAME}" -o yaml >&2 || true
            exit 1
            ;;
    esac
    sleep 5
done

phase="$(kubectl -n "${NAMESPACE}" get backup "${BACKUP_NAME}" -o jsonpath='{.status.phase}')"
phase_lc="$(printf '%s' "${phase}" | tr '[:upper:]' '[:lower:]')"
if [[ "${phase_lc}" != completed* ]]; then
    echo "FAIL: backup did not complete, last phase: ${phase:-<empty>}" >&2
    kubectl -n "${NAMESPACE}" describe backup "${BACKUP_NAME}" >&2 || true
    kubectl -n "${NAMESPACE}" get backup "${BACKUP_NAME}" -o yaml >&2 || true
    exit 1
fi

echo ">> verifying backup objects exist in MinIO"
kubectl -n "${NAMESPACE}" delete job minio-list-backup --ignore-not-found
kubectl -n "${NAMESPACE}" apply -f - <<YAML
apiVersion: batch/v1
kind: Job
metadata:
  name: minio-list-backup
spec:
  backoffLimit: 2
  template:
    spec:
      restartPolicy: Never
      containers:
        - name: mc
          image: ${MC_IMAGE}
          command: ["/bin/sh", "-ec"]
          args:
            - |
              mc alias set local http://minio:9000 "\${MINIO_ROOT_USER}" "\${MINIO_ROOT_PASSWORD}"
              objects="\$(mc find "local/${MINIO_BUCKET}/${CLUSTER_NAME}" --name data.tar.gz)"
              printf '%s\n' "\${objects}"
              test -n "\${objects}"
          env:
            - name: MINIO_ROOT_USER
              valueFrom:
                secretKeyRef:
                  name: ${MINIO_SECRET}
                  key: ACCESS_KEY_ID
            - name: MINIO_ROOT_PASSWORD
              valueFrom:
                secretKeyRef:
                  name: ${MINIO_SECRET}
                  key: ACCESS_SECRET_KEY
YAML
kubectl -n "${NAMESPACE}" wait --for=condition=complete job/minio-list-backup --timeout=180s

echo "OK: CNPG Barman Cloud plugin backup completed and backup objects exist in MinIO"
