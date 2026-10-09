# Releasing Platform Mesh

Everything that makes up a Platform Mesh release lives in this repository and
is released from it. There are three independent things with versions:

| What | Versioned by | Published by |
|---|---|---|
| **Component images** (account-operator, iam-service, …) | git tag `<component>/vX.Y.Z` | [`component-release.yml`](../../.github/workflows/component-release.yml) |
| **Helm charts** | `version` in `charts/<chart>/Chart.yaml`; the image a chart deploys by its `appVersion` | the next Platform Mesh release (or prerelease) that includes them |
| **Platform Mesh** (the OCM aggregate `github.com/platform-mesh/platform-mesh`) | git tag `vX.Y.Z` | [`release.yml`](../../.github/workflows/release.yml) |

The tagged commit of a Platform Mesh release fully describes it: the chart
versions and image versions are what the `Chart.yaml` files say, the
third-party versions are what [`ocm/versions.yaml`](../../ocm/versions.yaml)
says. Nothing is looked up in a registry to decide what a release contains.

## Releasing a component

1. Make sure `main` has what you want to ship.
2. Cut the tag, e.g. for a patch release of the account-operator:

   ```sh
   task release -- account-operator            # next patch
   task release -- account-operator --minor    # next minor
   task release -- account-operator --dry-run  # just show what would happen
   ```

   This creates and pushes `account-operator/vX.Y.Z`. (`git tag` + `git push`
   work just as well; the tool only computes the next version for you.)
3. `component-release.yml` runs the component's tests, builds and signs the
   image for amd64 and arm64, generates SBOMs, and publishes the OCM component
   `github.com/platform-mesh/images/account-operator:vX.Y.Z` to
   `ghcr.io/platform-mesh`.

That is all a component tag does. It does **not** change any chart and it does
not create a GitHub release. The component list, image names and chart
assignments live in [`ocm/components.yaml`](../../ocm/components.yaml).

Library modules (`apis`, `golang-commons`, `subroutines`) are tagged the same
way (`apis/vX.Y.Z`) because Go needs the tag; nothing is built for them.

## Changing a chart

Edit the chart and bump its `version` in `Chart.yaml` in the same pull request.
CI (`ct lint`) fails if a chart changed without a version bump. To ship a new
component image, bump the chart's `appVersion` to the image's tag — the
component must have been released (see above) before a Platform Mesh release
can include it.

Charts are not published on merge. They are packaged and pushed the first time
a Platform Mesh release or prerelease includes their version.

## Releasing Platform Mesh

1. Decide what the release contains: check the `Chart.yaml` files on `main`
   point at the chart and image versions you want, and `ocm/versions.yaml` at
   the right third-party versions. Everything referenced must already exist
   (component images via their tags; the release fails early otherwise and
   lists what is missing).
2. Tag the commit:

   ```sh
   git tag v0.7.0-rc.1 -m "Platform Mesh 0.7.0-rc.1"   # release candidate
   git tag v0.7.0 -m "Platform Mesh 0.7.0"             # final
   git push origin <tag>
   ```

3. `release.yml` runs [`hack/release/build-aggregate.sh`](../../hack/release/build-aggregate.sh):
   - packages and pushes every chart version not yet in `ghcr.io/platform-mesh/platform-mesh/<chart>`,
   - verifies every referenced component exists,
   - refuses to continue if an already published component version would
     get different content (bump the version instead),
   - builds the OCM component graph (chart components, service components,
     third-party wrappers, aggregate) in one go, signs the new ones, and
     publishes them to `ghcr.io/platform-mesh`,
   - generates the release notes ([`hack/release/release-notes.sh`](../../hack/release/release-notes.sh))
     and creates the GitHub release (marked as prerelease for `-rc.` tags),
   - verifies the result: resolves the whole graph, checks the signatures,
     pulls and templates charts.

A release candidate and a final release are the same process; only the tag
differs. Promoting an rc means tagging the same commit again with the final
version.

### Patch releases

Create a branch from the release tag, cherry-pick or commit the fixes (with
the required chart version bumps), and tag on that branch:

```sh
git checkout -b release-0.7 v0.7.0
# ... commits ...
git tag v0.7.1 -m "Platform Mesh 0.7.1"
git push origin release-0.7 v0.7.1
```

### Prereleases from main

To publish the current state of `main` without a release, run the
[`prerelease`](../../.github/workflows/prerelease.yml) workflow (Actions →
prerelease → Run workflow). It publishes
`github.com/platform-mesh/platform-mesh:<next>-dev.<run>.g<sha>`, e.g.
`0.7.0-dev.42.g1a2b3c4`, with the same script and no GitHub release. The
version is shown in the run's summary:

```sh
PLATFORM_MESH_VERSION=0.7.0-dev.42.g1a2b3c4 task local-setup:start
```

Prereleases older than two weeks are deleted by
[`cleanup-prereleases.yml`](../../.github/workflows/cleanup-prereleases.yml).

## The OCM component graph

```
github.com/platform-mesh/platform-mesh:<X.Y.Z>
├─ account-operator  → github.com/platform-mesh/account-operator:<chart version>
│                        ├─ chart → github.com/platform-mesh/helm-charts/account-operator:<chart version>
│                        └─ image → github.com/platform-mesh/images/account-operator:<appVersion>
├─ infra             → github.com/platform-mesh/infra:<chart version>
│                        ├─ chart → .../helm-charts/infra
│                        └─ image → .../images/infra:<chart version>   (third-party images the chart deploys)
├─ kcp               → github.com/kcp-dev/kcp:<PM_KCP_VERSION>          (wrapper around upstream artifacts)
└─ ...
```

The names of the components and of the references are a contract with the
platform-mesh-operator and with everyone installing from our registry; do not
rename them. The graph is generated from
[`ocm/component-constructor.yaml`](../../ocm/component-constructor.yaml)
(aggregate and third-party wrappers), the charts' `Chart.yaml` files and
[`ocm/charts/<chart>.yaml`](../../ocm/charts/README.md) (per-chart
deviations from the default shape).

## Tooling

The release scripts need `ocm` (the CLI from
[open-component-model/open-component-model](https://github.com/open-component-model/open-component-model)),
`helm` and `yq`. Their versions are pinned in `tools/Taskfile.yaml`
(`task tools:ocm` etc. install them into `bin/`). Scripts source
`hack/release/tools.sh` and call `require_tools ocm helm`, which installs the
tools they need and exports their paths as `$OCM`, `$HELM`, ...; the workflows
do the same via `UGET_PRINT_PATH=absolute task tools:<tool>`. So one pin
serves developers and CI. Set `RELEASE_TOOLS_FROM_PATH=true` to use whatever
is on `PATH` instead.

## Verifying a release

```sh
ocm get component-version ghcr.io/platform-mesh//github.com/platform-mesh/platform-mesh:0.7.0 --recursive
ocm verify component-version --signature platform-mesh.platform-mesh \
  ghcr.io/platform-mesh//github.com/platform-mesh/platform-mesh:0.7.0   # public key in ~/.ocmconfig
helm pull oci://ghcr.io/platform-mesh/platform-mesh/account-operator --version 0.21.1
cosign verify ghcr.io/platform-mesh/platform-mesh/account-operator:v0.15.5 \
  --certificate-identity-regexp 'https://github.com/platform-mesh/platform-mesh/' \
  --certificate-oidc-issuer https://token.actions.githubusercontent.com
```

## Secrets and configuration

| Where | Name | Purpose |
|---|---|---|
| repository secret | `OCM_SIGNING_PRIVATE_KEY`, `OCM_SIGNING_CERT` | RSA key and certificate for OCM signatures. The signature name must equal the certificate's CN. |
| repository variable | `OCM_SIGNATURE_NAME` | signature name, default `platform-mesh.platform-mesh` |
| repository variable | `OCM_MIRROR_FROM` | test setups only: OCM repository to copy missing image components from |

Image signing uses keyless cosign (GitHub OIDC); no secret.

## Building the graph locally

The release workflow has no logic of its own; everything is in
`hack/release/build-aggregate.sh`, so it can be run from a checkout:

```sh
hack/release/build-aggregate.sh --version 0.7.0 --generate-only   # just write ocm/.generated/constructor.yaml
hack/release/build-aggregate.sh --help
```

local-setup uses the same script for its working-tree builds.
