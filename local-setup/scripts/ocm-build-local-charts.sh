#!/bin/bash

# Packages the charts staged by hack/release/build-aggregate.sh (copies of
# charts/ with the build's version written in, see hack/release/stage-charts.sh)
# and pushes them to the kind cluster's OCI registry via the ocm-transfer-pod.
# Sourced by ocm-build-component.sh, which afterwards builds the OCM components
# for them.

set -e

# Script directory and project root
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# Pinned ocm/helm/yq (tools/Taskfile.yaml), installed on demand
source "$PROJECT_ROOT/hack/release/tools.sh" # pinned tool versions, see tools/Taskfile.yaml
require_tools helm

# Configuration
LOCAL_BIN="${LOCAL_BIN:-$PROJECT_ROOT/bin}"
# Where build-aggregate.sh stages the charts and where packages go.
STAGED_CHARTS="${STAGED_CHARTS:-$PROJECT_ROOT/ocm/.generated/charts}"
PRERELEASE_DIR="${PRERELEASE_DIR:-$PROJECT_ROOT/prerelease}"

# Color output (respect NO_COLOR env var)
if [ -z "$NO_COLOR" ]; then
    COL='\033[92m'
    RED='\033[91m'
    COL_RES='\033[0m'
else
    COL=''
    RED=''
    COL_RES=''
fi

# Get kubectl exec flags; should not provide -t because users might have wrapper
# scripts for managed kubectl's or am trying to redirect the output of this script
# to a file.
# Must be called at point of use, not script init, because background jobs lose TTY
get_kubectl_exec_flags() {
    echo "-i"
}

# Configuration for parallel execution
MAX_PARALLEL=${MAX_PARALLEL:-8}
CONCURRENT=${CONCURRENT:-false}

# Package one staged chart and push it to the local registry.
prepare_and_push_chart() {
    local comp="$1"
    local chart_dir="$STAGED_CHARTS/$comp"

    echo -e "${COL}[$(date '+%H:%M:%S')] Processing $chart_dir${COL_RES}"

    local out tarball
    out=$("$HELM" package "$chart_dir" --dependency-update -d "$PRERELEASE_DIR")
    tarball=$(echo "$out" | awk -F': ' '/saved it to:/ {print $2}')
    if [ ! -f "$tarball" ]; then
        echo -e "${RED}Failed to package $comp${COL_RES}" >&2
        return 1
    fi

    echo -e "${COL}[$(date '+%H:%M:%S')] Pushing $tarball to local OCI registry...${COL_RES}"
    kubectl cp "$tarball" -n default ocm-transfer-pod:.
    kubectl exec $(get_kubectl_exec_flags) ocm-transfer-pod -- helm push "$(basename "$tarball")" oci://oci-registry-docker-registry.registry.svc.cluster.local/platform-mesh
    echo -e "${COL}[$(date '+%H:%M:%S')] Pushed $tarball${COL_RES}"
}

# Package and push all staged charts (in parallel with CONCURRENT=true)
build_local_charts() {
    echo -e "${COL}[$(date '+%H:%M:%S')] Packaging and pushing charts from $STAGED_CHARTS...${COL_RES}"
    [ -d "$STAGED_CHARTS" ] || { echo -e "${RED}$STAGED_CHARTS does not exist; run build-aggregate.sh first${COL_RES}" >&2; return 1; }

    # Ensure kubeconfig is set
    kind export kubeconfig -n platform-mesh

    mkdir -p "$PRERELEASE_DIR"
    rm -f "$PRERELEASE_DIR"/*.tgz

    local charts=()
    for f in "$STAGED_CHARTS"/*/Chart.yaml; do
        local name
        name="$(basename "$(dirname "$f")")"
        [ "$name" = common ] && continue  # dependency only, bundled into the others
        charts+=("$name")
    done

    local failed=0

    if [ "$CONCURRENT" = "true" ]; then
        echo -e "${COL}[$(date '+%H:%M:%S')] Packaging charts (parallel, max $MAX_PARALLEL concurrent)${COL_RES}"
        local running=0
        local pids=()

        for comp in "${charts[@]}"; do
            # Start background job
            prepare_and_push_chart "$comp" &
            pids+=($!)
            running=$((running + 1))

            # Limit concurrency
            if ((running >= MAX_PARALLEL)); then
                # Wait for any one job to finish
                wait -n 2>/dev/null || true
                running=$((running - 1))
            fi
        done

        # Wait for all remaining jobs to complete
        for pid in "${pids[@]}"; do
            if ! wait "$pid"; then
                failed=$((failed + 1))
            fi
        done
    else
        echo -e "${COL}[$(date '+%H:%M:%S')] Packaging charts (sequential)${COL_RES}"
        for comp in "${charts[@]}"; do
            if ! prepare_and_push_chart "$comp"; then
                failed=$((failed + 1))
            fi
        done
    fi

    if ((failed > 0)); then
        echo -e "${RED}[$(date '+%H:%M:%S')] $failed chart(s) failed${COL_RES}" >&2
        return 1
    fi
    echo -e "${COL}[$(date '+%H:%M:%S')] All charts packaged and pushed${COL_RES}"
}

# Main function
main() {
    build_local_charts
}

# Run if executed directly
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
