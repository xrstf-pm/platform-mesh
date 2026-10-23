# Removed release machinery

What was deleted during the release rework, and what replaced it. Kept as a
checklist for the port back into the `platform-mesh` organisation and for
anyone wondering where a workflow went.

The rework happened in two steps: first the per-component workflows were
consolidated (still with independent component versions), then
[RFC 015](https://github.com/platform-mesh/architecture/blob/main/rfc/015-versioning.md)
replaced independent versions with one Platform Mesh version. The tables below
name the final replacement; where the intermediate step is mentioned it is
struck through.

## Independent component versions (RFC 015)

| Removed | Replaced by |
|---|---|
| Component release tags `<component>/vX.Y.Z` and ~~`component-release.yml`~~ | A Platform Mesh release (`vX.Y.Z`) builds every image at that version (`job-publish.yml`). Go modules (`apis`, `golang-commons`, `subroutines`) keep their `<module>/vX.Y.Z` tags; nothing is built for them. |
| `version:` and `appVersion:` in `charts/*/Chart.yaml` as the place where versions are decided | `0.0.0` in git; the release version is written in at build time (`hack/release/stage-charts.sh`). `appVersion` is still meaningful for charts wrapping components from other repositories (portal, iam-ui, …). |
| `ct lint`'s version-increment check | Nothing to check: no chart version in git. |
| Vendored chart dependencies (`charts/*/charts/*.tgz`, `Chart.lock`) and `oci://ghcr.io/platform-mesh/helm-charts` dependency references | `file://../<chart>` references, resolved at packaging and test time. |
| Per-chart "already published, skip" logic in `build-aggregate.sh` | A version is published once, for everything at once. Third-party wrappers (`PM_*` in `ocm/versions.yaml`) still have their own versions and the immutability check. |
| `cmd/release` (`task release`) | Deleted. Tagging is `git tag`; `hack/release/next-version.sh` prints the next Platform Mesh version. A new helper can be written for the new repository shape if one turns out to be useful. |
| `hack/release/next-version.sh` deriving the next version from tags alone | `VERSION` file (the minor), bumped on `main` after each minor release; tags only supply the patch. |
| Per-component version table in the release notes | Dropped; everything has the release's version. The notes list changed third-party and other-repository versions instead. |

## platform-mesh repository

| Removed | Replaced by |
|---|---|
| 16 per-component workflows `.github/workflows/<component>.yml` (account-operator, backup-operator, extension-manager-operator, iam-service, kcp-migration-operator, kro-composition-operator, kubernetes-graphql-gateway, platform-mesh-deployer, platform-mesh-operator, rebac-authz-webhook, resource-broker, search-operator, search-service, security-operator, terminal-controller-manager, virtual-workspaces) | `verify-component.yml` (PR checks for changed components, from `ocm/components.yaml`) and `job-publish.yml` (images for every component, on `v*` tags) |
| Library workflows `apis.yml`, `golang-commons.yml`, `subroutines.yml` | `verify-component.yml`. Library tags are still created for `go get`, but no longer produce a GitHub release. |
| `update-version` jobs dispatching chart bumps into helm-charts via `platform-mesh/.github/job-chart-version-update.yml` | Nothing. Chart `appVersion` bumps are commits in this repository. |
| `image-ocm` + `image-ocm-legacy` jobs (same OCM component published twice, to `ghcr.io/platform-mesh/platform-mesh` and `ghcr.io/platform-mesh`) via `platform-mesh/.github/job-image-ocm.yml` | `hack/release/build-image-component.sh`, run by `job-publish.yml`, publishing once to `ghcr.io/<owner>` (the repository the aggregate and its consumers use). The signing config is written by `hack/release/ocm-config.sh`. |
| Per-component GitHub releases on `<component>/v*` tags | Nothing. Only Platform Mesh releases (`v*`) get a GitHub release. |
| `verify`/`test`/`test-e2e` re-runs on every push to `main` (inside the per-component workflows) | Nothing. Every commit on `main` passed the checks as a pull request / in the merge queue. `:latest` images are still built on push to `main`, by `images.yml`, for the changed components only. |

## helm-charts repository (imported, then removed)

| Removed | Replaced by |
|---|---|
| 25 per-chart workflows `<chart>.yaml` + `pipeline-chart.yml` | Charts are published by the Platform Mesh release workflow, all at the release's version. |
| `update-chart-parameters.yaml` (bot-created, bot-approved, auto-merged bump PRs), `hack/bump-chart-version.sh` | Human commits. |
| `job-ocm.yml`, `ocm-service-component.yaml` (chart-only and service OCM components) | Built from one constructor in `release.yml`. Component names are unchanged. |
| `ocm-aggregator.yaml` (version derived from the registry, build/rc counters, `workflow_dispatch` increment inputs; third-party pins in its `env:` block) | `release.yml` on `v*` tags; version is the tag. Third-party pins in `ocm/versions.yaml`. |
| `ocm-create-draft-release.yaml`, `hack/ocm/{draft-release,fetch-versions,generate-changelog,format-notes,create-release}.sh` | Release notes generated from this repository's history between two tags (`hack/release/release-notes.sh`). |
| `ocm-create-patch.yaml` (patch releases by editing a descriptor fetched from the registry) | Tags on `release-X.Y` branches. |
| `pr-checks.yml`, `job-test-chart.yml`, `job-check-helm-chart-docs.yml`, `hack-tests.yml` | `verify-component.yml` / `verify-charts.yml` chart jobs. |
| `kind-localsetup.yaml`, `kind-localsetup-remote.yaml`, `nightly-local-setup.yaml` | `verify-local-setup.yml`, `verify-local-setup-remote.yml`, `local-setup-nightly.yml`, sharing the `.github/actions/local-setup*` actions. |
| `ocm-cleanup-versions.yaml`, `hack/ocm/list-cleanup-candidates.sh` | `prerelease-cleanup.yml` + `hack/release/cleanup-prereleases.sh` (every `-dev.` version: aggregate, components, charts, images). |
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

## Resolved by RFC 015

The version skew noticed during the first step (charts bundling older
`*-crds`/`common` versions than the repository contained, e.g.
`account-operator-crds 0.2.7` vs. 0.4.0) no longer exists: every chart and
dependency is built from the same commit at the same version.
