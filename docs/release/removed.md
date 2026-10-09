# Removed release machinery

What was deleted during the release rework, and what replaced it. Kept as a
checklist for the port back into the `platform-mesh` organisation and for
anyone wondering where a workflow went.

## platform-mesh repository

| Removed | Replaced by |
|---|---|
| 16 per-component workflows `.github/workflows/<component>.yml` (account-operator, backup-operator, extension-manager-operator, iam-service, kcp-migration-operator, kro-composition-operator, kubernetes-graphql-gateway, platform-mesh-deployer, platform-mesh-operator, rebac-authz-webhook, resource-broker, search-operator, search-service, security-operator, terminal-controller-manager, virtual-workspaces) | `ci.yml` (PR/main checks for changed components, from `ocm/components.yaml`) and `component-release.yml` (`<component>/v*` tags) |
| Library workflows `apis.yml`, `golang-commons.yml`, `subroutines.yml` | `ci.yml`. Library tags are still created for `go get`, but no longer produce a GitHub release. |
| `update-version` jobs dispatching chart bumps into helm-charts via `platform-mesh/.github/job-chart-version-update.yml` | Nothing. Chart `appVersion` bumps are commits in this repository. |
| `image-ocm` + `image-ocm-legacy` jobs (same OCM component published twice, to `ghcr.io/platform-mesh/platform-mesh` and `ghcr.io/platform-mesh`) via `platform-mesh/.github/job-image-ocm.yml` | `ocm` job in `component-release.yml`, publishing once to `ghcr.io/<owner>` (the repository the aggregate and its consumers use). Logic is inlined; the signing config is written by `hack/release/ocm-config.sh`. |
| Per-component GitHub releases on `<component>/v*` tags | Nothing. Only Platform Mesh releases (`v*`) get a GitHub release. |

## helm-charts repository (imported, then removed)

| Removed | Replaced by |
|---|---|
| 25 per-chart workflows `<chart>.yaml` + `pipeline-chart.yml` | Charts are published by the Platform Mesh release workflow (`release.yml`) for every chart version not yet in the registry. |
| `update-chart-parameters.yaml` (bot-created, bot-approved, auto-merged bump PRs), `hack/bump-chart-version.sh` | Human commits. |
| `job-ocm.yml`, `ocm-service-component.yaml` (chart-only and service OCM components) | Built from one constructor in `release.yml`. Component names are unchanged. |
| `ocm-aggregator.yaml` (version derived from the registry, build/rc counters, `workflow_dispatch` increment inputs; third-party pins in its `env:` block) | `release.yml` on `v*` tags; version is the tag. Third-party pins in `ocm/versions.yaml`. |
| `ocm-create-draft-release.yaml`, `hack/ocm/{draft-release,fetch-versions,generate-changelog,format-notes,create-release}.sh` | Release notes generated from this repository's history between two tags (`hack/release/release-notes.sh`). |
| `ocm-create-patch.yaml` (patch releases by editing a descriptor fetched from the registry) | Tags on `release-X.Y` branches. |
| `pr-checks.yml`, `job-test-chart.yml`, `job-check-helm-chart-docs.yml`, `hack-tests.yml` | `ci.yml` chart jobs. |
| `kind-localsetup.yaml`, `kind-localsetup-remote.yaml`, `nightly-local-setup.yaml` | `e2e-localsetup.yml` (one workflow, `pull_request` + `schedule`). |
| `ocm-cleanup-versions.yaml`, `hack/ocm/list-cleanup-candidates.sh` | Scheduled cleanup of prerelease aggregate versions (see `prerelease.yml`). `hack/release/cleanup-versions.sh` kept. |
| `ocm-mirror-helm-chart.yaml` | Kept as `mirror-helm-chart.yml` (manual, unchanged). |
| `auto-labeler.yml`, `dco.yaml`, `ossf-scorecard.yml`, `renovate-autofix.yaml` | Monorepo already has its own. |
| `.ocm/component-constructor-{chart-only,service-component,service-component-chart-only,local-prerelease,chart-only-prerelease}.yaml`, `component-constructor.yaml` | One constructor, `ocm/component-constructor.yaml`. |

## platform-mesh/.github repository

Not deleted there (other repositories may still use them), but no longer used
by platform-mesh:

- `job-chart-version-update.yml`
- `job-ocm-version-update.yml`
- `job-image-ocm.yml`
- `job-chart-ocm.yml`
- `job-release-chart.yml`
- `job-ocm.yml`

## Open follow-ups for chart owners

Not changed by the rework, but noticed while doing it:

- Several charts pin older versions of in-repo dependencies than what the
  repository contains, e.g. `account-operator` bundles `account-operator-crds
  0.2.7` (repo: 0.4.0), `extension-manager-operator` bundles
  `extension-manager-operator-crds 0.3.3` (repo: 0.5.0), `security-operator`
  bundles `security-operator-crds 0.4.1` (repo: 0.6.0); all charts pin `common
  0.15.0` (repo: 0.15.1). Switching dependencies from `oci://ghcr.io/platform-mesh/helm-charts`
  to local `file://` references would force these to current, so it was not
  done as part of the rework.
