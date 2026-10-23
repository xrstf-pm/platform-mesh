# Releasing Platform Mesh

Platform Mesh has one version. A release is a git tag `vX.Y.Z` on this
repository; everything that is built from the repository — every component
image, every Helm chart, every OCM component and the aggregate
`github.com/platform-mesh/platform-mesh` — is built from that commit and
carries that version. There is nothing to prepare before tagging and no
component is released on its own. The reasoning is in
[RFC 015](https://github.com/platform-mesh/architecture/blob/main/rfc/015-versioning.md).

| What | Version | Source |
|---|---|---|
| Component images (account-operator, iam-service, …) | `X.Y.Z` | built from the tagged commit |
| Helm charts and their OCM components | `X.Y.Z` | packaged from the tagged commit (`0.0.0` in git, see below) |
| The aggregate `github.com/platform-mesh/platform-mesh` | `X.Y.Z` | |
| Components from other repositories (portal, iam-ui, marketplace-ui, example-httpbin-operator) | their own | `appVersion` in `charts/<name>/Chart.yaml` |
| Third-party software (kcp, OpenFGA, Traefik, …) | their own | [`ocm/versions.yaml`](../../ocm/versions.yaml) |
| Go modules other projects import (`apis`, `golang-commons`, `subroutines`) | their own | git tag `<module>/vX.Y.Z` by hand, nothing is built |

## Versions live in tags, not in files

Every `charts/*/Chart.yaml` says `version: 0.0.0`, and the charts of components
built here also `appVersion: 0.0.0`. The real version is written in at build
time by [`hack/release/stage-charts.sh`](../../hack/release/stage-charts.sh)
(into a copy under `ocm/.generated/charts/`, the working tree stays clean).
Chart dependencies on `common` and the `*-crds` charts are `file://` references
into this directory, pinned to the same version.

This is what makes backports a plain `git cherry-pick`: a commit carries no
version information, so it applies to any branch unchanged.

The only version-related file is [`VERSION`](../../VERSION) at the repository
root. It holds the minor (`0.61`) that the branch is working towards and is
bumped on `main` right after a minor release. Release branches keep theirs.
[`hack/release/next-version.sh`](../../hack/release/next-version.sh) derives
the next full version from it and from the tags reachable from `HEAD`.

## Releasing

### A minor release

1. On `main`, cut a release candidate:

   ```sh
   hack/release/next-version.sh              # prints the next version, e.g. 0.61.0
   git tag v0.61.0-rc.1 && git push origin v0.61.0-rc.1
   ```

2. Test the candidate (`PLATFORM_MESH_VERSION=0.61.0-rc.1 task local-setup:start`,
   production-setup, …). Fixes land on `main`; cut further candidates as
   needed (`-rc.2`, …).
3. Promote: tag the same version without the `-rc.N`:

   ```sh
   git tag v0.61.0 && git push origin v0.61.0
   ```

4. Afterwards, on `main`: create the release branch and bump `VERSION`:

   ```sh
   git branch release-0.61 v0.61.0 && git push origin release-0.61
   echo 0.62 > VERSION   # commit via pull request
   ```

   When to create the branch is a workflow decision, not a technical one. It
   can also be created earlier (then fixes for the release are cherry-picked
   into it) or later (then `main` is in code freeze until the release). See
   RFC 015.

### A patch release

Fixes are merged to `main` first, then cherry-picked into the release branch
(via a pull request against `release-X.Y`; no edits needed). Then:

```sh
git checkout release-0.61
hack/release/next-version.sh         # 0.61.1
git tag v0.61.1 && git push origin v0.61.1
```

### What the tag triggers

[`release.yml`](../../.github/workflows/release.yml) calls
[`job-publish.yml`](../../.github/workflows/job-publish.yml) with the version
from the tag:

1. **images** – every component in [`ocm/components.yaml`](../../ocm/components.yaml)
   is built for amd64 and arm64, pushed as
   `ghcr.io/platform-mesh/platform-mesh/<image>:vX.Y.Z` (image tags keep the
   `v`, like before; OCM component versions never had one), cosign-signed, its
   SBOMs attested, and published as the signed OCM component
   `github.com/platform-mesh/images/<component>:X.Y.Z`
   ([`hack/release/build-image-component.sh`](../../hack/release/build-image-component.sh)).
2. **aggregate** – [`hack/release/build-aggregate.sh`](../../hack/release/build-aggregate.sh)
   packages the charts at `X.Y.Z`, pushes them to
   `ghcr.io/platform-mesh/platform-mesh/<chart>`, builds the OCM graph (chart
   components, service components, third-party wrappers, aggregate), signs
   the new component versions and publishes them to `ghcr.io/platform-mesh`.
   Every referenced component must exist: the images from step 1, the
   components from other repositories at their `appVersion`, the third-party
   wrappers from `ocm/versions.yaml`. The run fails with a list otherwise.
3. **verify** – resolves the published graph, checks every signature of this
   version, pulls and templates charts.
4. **trivy** – scans the images and SBOMs.
5. `release.yml` then generates the release notes
   ([`hack/release/release-notes.sh`](../../hack/release/release-notes.sh):
   merged pull requests since the previous tag, grouped by area; changed
   third-party and other-repository versions) and creates the GitHub release,
   marked as prerelease for `-rc.N` tags.

Published versions are immutable. Tagging a version that exists in the
registry already fails; use the next one.

Nothing is tested on the tag: the commit went through the `verify-*`
workflows as a pull request.

### Prereleases from main

To publish the current `main` without a release, run the
[`prerelease`](../../.github/workflows/prerelease.yml) workflow (Actions →
prerelease → Run workflow). It runs the same `job-publish.yml` with the version
`<next>-dev.<run>.g<sha>`, e.g. `0.61.0-dev.42.g1a2b3c4` (`dev` sorts below
`rc`), and creates no GitHub release. The version is in the run's summary:

```sh
PLATFORM_MESH_VERSION=0.61.0-dev.42.g1a2b3c4 task local-setup:start
```

Prerelease versions older than two weeks are deleted by
[`prerelease-cleanup.yml`](../../.github/workflows/prerelease-cleanup.yml).

## Changing things

- **A component or its chart**: just change it. The next release ships it.
  CI runs the chart lint and unit tests; there is no version to bump.
- **A component from another repository** (portal, …): that repository
  releases its image and OCM component `github.com/platform-mesh/images/<name>`
  as before; then bump `appVersion` in `charts/<name>/Chart.yaml` here.
- **Third-party software**: change the pin in `ocm/versions.yaml` (Renovate
  proposes these). Wrapper components are versioned by their `PM_*` entry there
  and are immutable like everything else — bump it when a wrapper's content
  changes.
- **A new component**: see [adding a service](../deployment/adding-a-service.md).
- **A Go module** (`apis`, …): tag it when consumers need a new version
  (`git tag apis/vX.Y.Z`), then `task bump-deps -- apis vX.Y.Z` to point the
  in-repo consumers at it. Nothing is built.

## The OCM component graph

```
github.com/platform-mesh/platform-mesh:X.Y.Z
├─ account-operator  → github.com/platform-mesh/account-operator:X.Y.Z
│                        ├─ chart → github.com/platform-mesh/helm-charts/account-operator:X.Y.Z
│                        └─ image → github.com/platform-mesh/images/account-operator:X.Y.Z
├─ portal            → github.com/platform-mesh/portal:X.Y.Z
│                        ├─ chart → .../helm-charts/portal:X.Y.Z
│                        └─ image → .../images/portal:<appVersion>          (built by the portal repository)
├─ infra             → github.com/platform-mesh/infra:X.Y.Z
│                        ├─ chart → .../helm-charts/infra:X.Y.Z
│                        └─ image → .../images/infra:X.Y.Z                  (third-party images the chart deploys)
├─ kcp               → github.com/kcp-dev/kcp:<PM_KCP_VERSION>              (wrapper around upstream artifacts)
└─ ...
```

The names of the components and of the references are a contract with the
platform-mesh-operator and with everyone installing from our registry; do not
rename them. The graph is generated from
[`ocm/component-constructor.yaml`](../../ocm/component-constructor.yaml)
(aggregate and third-party wrappers), `ocm/components.yaml` (which charts
belong to components built here) and
[`ocm/charts/<chart>.yaml`](../../ocm/charts/README.md) (per-chart deviations
from the default shape).

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
ocm get component-version ghcr.io/platform-mesh//github.com/platform-mesh/platform-mesh:0.61.0 --recursive
ocm verify component-version --signature platform-mesh.platform-mesh \
  ghcr.io/platform-mesh//github.com/platform-mesh/platform-mesh:0.61.0   # public key in ~/.ocmconfig
helm pull oci://ghcr.io/platform-mesh/platform-mesh/account-operator --version 0.61.0
cosign verify ghcr.io/platform-mesh/platform-mesh/account-operator:v0.61.0 \
  --certificate-identity-regexp 'https://github.com/platform-mesh/platform-mesh/' \
  --certificate-oidc-issuer https://token.actions.githubusercontent.com
```

## Secrets and configuration

| Where | Name | Purpose |
|---|---|---|
| repository secret | `OCM_SIGNING_PRIVATE_KEY`, `OCM_SIGNING_CERT` | RSA key and certificate for OCM signatures. The signature name must equal the certificate's CN. |
| repository variable | `OCM_SIGNATURE_NAME` | signature name, default `platform-mesh.platform-mesh` |
| repository variable | `OCM_MIRROR_FROM` | test setups only: OCM repository to copy components from other repositories from |

Image signing uses keyless cosign (GitHub OIDC); no secret.

## Building the graph locally

The workflows have no logic of their own; it is all in `hack/release/`, so it
can be run from a checkout:

```sh
hack/release/build-aggregate.sh --version 0.61.0 --generate-only   # stage charts, write ocm/.generated/constructor.yaml
hack/release/build-aggregate.sh --help
hack/release/next-version.sh                                       # what the next release would be
```

local-setup uses the same script for its working-tree builds, with the images
of the latest release reachable from `HEAD` (it does not build images;
`PLATFORM_MESH_IMAGE_VERSION` overrides the choice).
