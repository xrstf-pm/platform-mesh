#!/bin/bash

# Builds the Platform Mesh OCM component graph from the working tree and
# publishes it as github.com/platform-mesh/prerelease:<COMPONENT_PRERELEASE_VERSION>
# into the kind cluster's OCI registry. This is local-setup's "working tree"
# mode; `task local-setup:ocm:build` runs it.
#
# The graph is the same one a release publishes, produced by the same
# generator (hack/release/build-aggregate.sh --generate-only), only
#   - the aggregate is named .../prerelease,
#   - charts are packaged from the working tree and pushed to the local registry,
#   - image components and other external references are copied into the local
#     registry from REMOTE_REGISTRY (images are those pinned by the charts'
#     appVersion; use load-custom-images.sh for locally built ones).
#
# All registry operations run inside the ocm-transfer-pod, since the local
# registry is only reachable from within the cluster.

set -e

if [ "${DEBUG}" = "true" ]; then
  set -x
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

source "$PROJECT_ROOT/hack/release/tools.sh" # pinned ocm/helm/yq on PATH
source "$SCRIPT_DIR/ocm-build-local-charts.sh"

LOCAL_BIN="${LOCAL_BIN:-$PROJECT_ROOT/bin}"
COMPONENT_PRERELEASE_VERSION="${COMPONENT_PRERELEASE_VERSION:-1.0.0}"
PRERELEASE_COMPONENT="github.com/platform-mesh/prerelease"

# Where external components (images, third-party wrappers) are copied from.
REMOTE_REGISTRY="${REMOTE_REGISTRY:-ghcr.io/platform-mesh}"
# In-cluster registry; only reachable from inside the cluster.
LOCAL_REGISTRY="${LOCAL_REGISTRY:-oci-registry-docker-registry.registry.svc.cluster.local}"
LOCAL_OCM_REPO="$LOCAL_REGISTRY/platform-mesh"

CONSTRUCTOR="$PROJECT_ROOT/ocm/.generated/prerelease-constructor.yaml"

if [ -z "$NO_COLOR" ]; then
    COL='\033[92m'
    RED='\033[91m'
    COL_RES='\033[0m'
else
    COL=''
    RED=''
    COL_RES=''
fi

# kubectl exec flags; no -t because of wrapper scripts and output redirection.
# Must be called at point of use, not script init, because background jobs lose TTY
get_kubectl_exec_flags() {
    echo "-i"
}

pod_ocm() { # run ocm inside the transfer pod
    kubectl exec $(get_kubectl_exec_flags) ocm-transfer-pod -- ocm "$@"
}

# Generate the constructor for the whole graph, with the local registry as
# the place where charts and components live.
generate_constructor() {
    echo -e "${COL}[$(date '+%H:%M:%S')] Generating constructor for $PRERELEASE_COMPONENT:$COMPONENT_PRERELEASE_VERSION...${COL_RES}"
    "$PROJECT_ROOT/hack/release/build-aggregate.sh" \
        --generate-only \
        --version "$COMPONENT_PRERELEASE_VERSION" \
        --component "$PRERELEASE_COMPONENT" \
        --ocm-repo "$LOCAL_OCM_REPO" \
        --chart-repo "$LOCAL_OCM_REPO" \
        --output "$CONSTRUCTOR"
}

# Every component the constructor references but does not define must exist in
# the local registry before `ocm add` (OCM v2 resolves references during graph
# discovery). Copy them from the remote registry.
mirror_external_components() {
    echo -e "${COL}[$(date '+%H:%M:%S')] Copying external components into the local registry...${COL_RES}"
    local refs
    refs=$(yq -o=json '.' "$CONSTRUCTOR" | jq -r '
        [.components[] | .name + ":" + .version] as $defined
        | [.components[].componentReferences[]? | .componentName + ":" + .version]
        | unique | .[] | select(. as $r | $defined | index($r) | not)')

    local failed=0
    for ref in $refs; do
        local name="${ref%:*}" version="${ref##*:}"
        if pod_ocm get component-version "$LOCAL_OCM_REPO//$name:$version" >/dev/null 2>&1; then
            echo -e "${COL}[$(date '+%H:%M:%S')] $name:$version already present${COL_RES}"
            continue
        fi
        local source="$REMOTE_REGISTRY"
        case "$name" in
            github.com/gardener/*) source="europe-docker.pkg.dev/gardener-project/releases" ;;
        esac
        echo -e "${COL}[$(date '+%H:%M:%S')] $name:$version: copying from $source...${COL_RES}"
        if ! pod_ocm transfer component-version --recursive "$source//$name:$version" "$LOCAL_OCM_REPO"; then
            echo -e "${RED}Failed to copy $name:$version${COL_RES}" >&2
            case "$name" in
                github.com/platform-mesh/images/*)
                    echo -e "${RED}  The image version is taken from charts/${name##*/}/Chart.yaml (appVersion).${COL_RES}" >&2
                    echo -e "${RED}  For locally built images use local-setup/scripts/load-custom-images.sh.${COL_RES}" >&2 ;;
            esac
            failed=$((failed + 1))
        fi
    done
    if ((failed > 0)); then
        return 1
    fi
}

# One `ocm add` for the whole graph: chart components, service components,
# third-party wrappers and the prerelease aggregate.
build_component_graph() {
    echo -e "${COL}[$(date '+%H:%M:%S')] Building component graph in the local registry...${COL_RES}"
    kubectl cp "$CONSTRUCTOR" -n default ocm-transfer-pod:.ocm/prerelease-constructor.yaml
    pod_ocm add component-versions \
        --component-version-conflict-policy replace \
        --repository "$LOCAL_OCM_REPO" \
        --constructor .ocm/prerelease-constructor.yaml
}

build_component() {
    echo -e "${COL}[$(date '+%H:%M:%S')] Starting OCM component build...${COL_RES}"
    kind export kubeconfig -n platform-mesh
    setup_ocm_cli
    export_ocm_path

    generate_constructor
    build_local_charts
    mirror_external_components
    build_component_graph

    echo ""
    echo -e "${COL}[$(date '+%H:%M:%S')] Built $PRERELEASE_COMPONENT:$COMPONENT_PRERELEASE_VERSION from the working tree into $LOCAL_OCM_REPO (component names are a contract and do not follow the GitHub org)${COL_RES}"
}

main() {
    build_component
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
