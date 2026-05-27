#!/usr/bin/env bash
# Shared helpers for local and CI smoke tests.

if [[ -z "${BASH_VERSION:-}" ]]; then
    echo "test/lib/common.sh must be sourced by bash" >&2
    exit 2
fi

require_command() {
    command -v "$1" >/dev/null || { echo "missing: $1" >&2; exit 2; }
}

default_pg_major() {
    local major="${PG_MAJOR:-}"

    if [[ -z "${major}" ]]; then
        echo "PG_MAJOR is required" >&2
        exit 2
    fi

    printf '%s\n' "${major}"
}

default_image() {
    local major="${1:-$(default_pg_major)}"

    printf 'localhost/postgres-distroless:%s\n' "${major}"
}

pg_bin_dir() {
    local major="${1:-$(default_pg_major)}"

    printf '/usr/lib/postgresql/%s/bin\n' "${major}"
}

ensure_kind_cluster() {
    local cluster="$1"

    require_command kind
    if ! kind get clusters | grep -qx "${cluster}"; then
        echo ">> creating kind cluster ${cluster}"
        kind create cluster --name "${cluster}"
    fi
}

load_image_into_kind() {
    local cluster="$1"
    local image="$2"

    require_command kind
    echo ">> loading image ${image} into kind"
    kind load docker-image --name "${cluster}" "${image}"
}

install_cnpg_operator() {
    local version="$1"

    require_command kubectl
    echo ">> installing CNPG operator (v${version})"
    kubectl apply --server-side -f \
        "https://raw.githubusercontent.com/cloudnative-pg/cloudnative-pg/v${version}/releases/cnpg-${version}.yaml"
    kubectl -n cnpg-system rollout status deploy/cnpg-controller-manager --timeout=180s
}

primary_pod() {
    local namespace="$1"
    local cluster="$2"

    kubectl -n "${namespace}" get pods \
        -l "cnpg.io/cluster=${cluster},role=primary" \
        -o jsonpath='{.items[0].metadata.name}'
}

render_template() {
    local input="$1"
    local output="$2"
    local image="$3"
    local cluster="$4"
    local namespace_name="$5"

    awk \
        -v image="${image}" \
        -v cluster="${cluster}" \
        -v namespace_name="${namespace_name}" \
        '{
            gsub(/__IMAGE__/, image)
            gsub(/__CLUSTER_NAME__/, cluster)
            gsub(/__NAMESPACE__/, namespace_name)
            print
        }' "${input}" > "${output}"
}
