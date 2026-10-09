#!/bin/bash

# Packages every chart under charts/ from the working tree and pushes it to the
# kind cluster's OCI registry (via the ocm-transfer-pod). Sourced by
# ocm-build-component.sh, which afterwards builds the OCM components for them.

set -e

# Script directory and project root
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# Pinned ocm/helm/yq (tools/Taskfile.yaml), installed on demand
source "$PROJECT_ROOT/hack/release/tools.sh" # pinned ocm/helm/yq on PATH

# Configuration
LOCAL_BIN="${LOCAL_BIN:-$PROJECT_ROOT/bin}"
OCM_DIR="${OCM_DIR:-$PROJECT_ROOT/ocm}"
PRERELEASE_DIR="${PRERELEASE_DIR:-$PROJECT_ROOT/prerelease}"

# Local charts to build (component-name:chart-path)

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

# Swap OCI common chart reference to local file reference (only for 'common' dependency)
# Operates on a copied chart in the prerelease directory to avoid modifying original files
swap_common_to_local() {
    local chart_path="$1"  # Full path to the copied chart
    local chart_yaml="$chart_path/Chart.yaml"

    # Check if this chart has a common dependency with OCI reference
    if grep -A2 "name: common" "$chart_yaml" | grep -q "oci://ghcr.io/platform-mesh/helm-charts"; then
        # Replace only the common chart's OCI reference with local file reference
        # Uses awk to only modify the repository line that follows "name: common"
        # Path is relative to the copied chart in prerelease/<comp>/, pointing to prerelease/common
        local temp_file
        temp_file=$(mktemp)
        awk '
            /- name: common/ { in_common=1 }
            in_common && /repository:.*oci:\/\/ghcr.io\/platform-mesh\/helm-charts/ {
                sub(/oci:\/\/ghcr.io\/platform-mesh\/helm-charts/, "file://../common")
                in_common=0
            }
            { print }
        ' "$chart_yaml" > "$temp_file"
        mv "$temp_file" "$chart_yaml"

        # Update dependencies to fetch local common chart
        helm dependency update "$chart_path" 2>/dev/null || true

        return 0  # swapped
    fi
    return 1  # no swap needed
}


# Configuration for parallel execution
MAX_PARALLEL=${MAX_PARALLEL:-8}
CONCURRENT=${CONCURRENT:-false}

# Package one chart from the working tree and push it to the local registry.
prepare_and_push_chart() {
    local comp="$1"
    local chart_dir="charts/$comp"

    echo -e "${COL}[$(date '+%H:%M:%S')] Processing $chart_dir${COL_RES}"

    # Copy chart to prerelease directory to avoid modifying the original
    local prerelease_chart_dir="$PRERELEASE_DIR/$comp"
    rm -rf "$prerelease_chart_dir"
    cp -r "$PROJECT_ROOT/$chart_dir" "$prerelease_chart_dir"

    # Swap common chart reference to local in the copied chart (if it has the dependency)
    swap_common_to_local "$prerelease_chart_dir" || true

    local out tarball
    out=$(helm package "$prerelease_chart_dir" -d "$PRERELEASE_DIR")
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

# Package and push all charts (in parallel with CONCURRENT=true)
build_local_charts() {
    echo -e "${COL}[$(date '+%H:%M:%S')] Packaging and pushing charts from the working tree...${COL_RES}"

    # Ensure kubeconfig is set
    kind export kubeconfig -n platform-mesh

    # Create prerelease directory
    mkdir -p "$PRERELEASE_DIR"
    rm -f "$PRERELEASE_DIR"/*.tgz

    local charts=()
    for f in "$PROJECT_ROOT"/charts/*/Chart.yaml; do
        local name
        name="$(basename "$(dirname "$f")")"
        [ "$name" = common ] && continue  # dependency only, bundled into the others
        charts+=("$name")
    done

    # Copy common chart to prerelease directory (used as dependency by other charts)
    rm -rf "$PRERELEASE_DIR/common"
    cp -r "$PROJECT_ROOT/charts/common" "$PRERELEASE_DIR/common"

    # Setup OCM CLI
    setup_ocm_cli
    export_ocm_path

    # Phase 1: Prepare and push all charts
    local failed=0

    if [ "$CONCURRENT" = "true" ]; then
        echo -e "${COL}[$(date '+%H:%M:%S')] Packaging charts (parallel, max $MAX_PARALLEL concurrent)${COL_RES}"
        local running=0
        local pids=()

        for pair in "${CUSTOM_LOCAL_COMPONENTS_CHART_PATHS[@]}"; do
            local comp="${pair%%:*}"
            local chart_dir="${pair#*:}"

            # Start background job
            prepare_and_push_chart "$comp" "$chart_dir" &
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

    # Phase 2: Add all components to local OCI registry sequentially
    echo -e "${COL}[$(date '+%H:%M:%S')] All charts pushed${COL_RES}"
}

# Main function
main() {
    build_local_charts
}

# Run if executed directly
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
