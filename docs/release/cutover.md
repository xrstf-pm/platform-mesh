# Cutover: moving the new release process into the platform-mesh organisation

The new release process was developed and tested in the `xrstf-pm` scratch
organisation (forks of `platform-mesh`, `helm-charts` and `.github`). This
document lists, in order, what has to happen to put it into production. Steps
1–6 are additive and leave the existing release flow untouched; step 7 is the
flip.

## 0. Decisions to take before starting

| | Question | Options |
|---|---|---|
| O1 | Chart OCI namespace | keep `ghcr.io/platform-mesh/helm-charts/<chart>` (the monorepo's `GITHUB_TOKEN` cannot push there; needs the PM Publisher App token or re-linking every chart package to the monorepo) **or** move to `ghcr.io/platform-mesh/platform-mesh/<chart>` (what the new workflows do by default; 23 `Chart.yaml` dependency URLs, docs and the OCM chart resources then point at the new location; consumers pulling charts by URL must adapt) |
| O2 | OCM signature name | keep `helm-charts.platform-mesh` (what consumers verify today) **or** switch to `platform-mesh.platform-mesh` (CN of the monorepo's existing cert). A switch is a consumer-visible change like the last one (`ocm.platform-mesh` → `helm-charts.platform-mesh` at 0.4.0-build.516) and needs a migration note |
| D5 | Chart dependencies | keep OCI references to `common`/`*-crds` or switch to `file://` with exact pins (would force several charts onto newer crds/common versions than they bundle today; see `removed.md`) |

Recommendation: O1 move, O2 keep `helm-charts.platform-mesh` (set the repo
variable `OCM_SIGNATURE_NAME` accordingly and use the helm-charts signing cert),
D5 defer.

## 1. Import helm-charts into the monorepo

```sh
hack/import/import-helm-charts.sh --source https://github.com/platform-mesh/helm-charts
```

Rehearsed in the fork; takes ~5 minutes, verifies the result byte-for-byte
against the source. Do this as one PR (the merge commit plus the
"Integrate imported helm-charts content" follow-up). Nothing in it is active
yet: the imported workflows are parked under `.github/workflows-helm-charts/`.
After this, chart PRs can already be made in the monorepo, but publishing still
goes through helm-charts — **freeze chart changes in helm-charts** from this
point, or they have to be replayed.

## 2. Add the new tooling

Port the fork's commits after the import (`ocm/`, `hack/release/`, the new
workflows, `charts/Taskfile.yaml`, `local-setup/Taskfile.yaml`, docs). The old
per-component workflows can stay in place during this step; `release.yml`
only triggers on `v*` tags, which do not exist yet, and `ci.yml` runs
alongside them.

## 3. Repository configuration

| Kind | Name | Value |
|---|---|---|
| secret | `OCM_SIGNING_PRIVATE_KEY`, `OCM_SIGNING_CERT` | the key/cert matching the chosen signature name (O2). Both exist in helm-charts today. |
| variable | `OCM_SIGNATURE_NAME` | per O2 |
| variable | `OCM_MIRROR_FROM` | **leave unset** |
| branch protection | `main` | require the `ci` checks (and `pr-gate`), as for the old per-component workflows |

GHCR package access: the monorepo's `GITHUB_TOKEN` must be able to push to the
existing packages under `ghcr.io/platform-mesh/component-descriptors/*`
(created by helm-charts and the old monorepo workflows). Per package: Package
settings → Manage Actions access → add `platform-mesh/platform-mesh` with
write. Alternatively give the workflows a GitHub App token. Check with a
prerelease run (step 5) which packages are affected; the failure is explicit.
New packages (charts under the new namespace, if O1 = move) are created
private on first push and must be made public once.

## 4. Component images

Nothing to migrate: `component-release.yml` publishes the same
`github.com/platform-mesh/images/<component>` components to `ghcr.io/platform-mesh`
that the old `image-ocm-legacy` job did. Verify with one component tag.

## 5. Dress rehearsal: prerelease and release candidate

```sh
gh workflow run prerelease.yml          # publishes <next>-dev.N.g<sha>
PLATFORM_MESH_VERSION=<that version> task local-setup:start   # with --iterate=false
git tag v0.6.0-rc.1 && git push origin v0.6.0-rc.1
```

Both go through the complete new pipeline against the real registry and
consumers. Check the `verify` job, install the rc with local-setup and
production-setup, run the e2e tests.

## 6. Tell people

Announce the new process (docs/release/process.md) and the removal list
(docs/release/removed.md). Update:

- the UI repositories (portal, iam-ui, marketplace-ui) and contrib-examples:
  remove the `job-chart-version-update` dispatch; their chart `appVersion` is
  bumped in the monorepo (manually or by Renovate)
- `platform-mesh/.github`: mark `job-chart-version-update`, `job-ocm-version-update`,
  `job-image-ocm`, `job-chart-ocm`, `job-release-chart`, `job-ocm` as unused by
  platform-mesh; delete once no repository uses them

## 7. Flip

In one PR / afternoon:

1. Delete the old per-component workflows and `.github/workflows-helm-charts/`
   in the monorepo (the fork's commit "Replace per-component and chart release
   workflows" is the template).
2. Archive `platform-mesh/helm-charts` (read-only). Its tags remain; the
   monorepo carries them as `helm-charts/0.x`.
3. If O1 = move: update the chart dependency URLs and docs.
4. Tag `v0.6.0`.

## Rollback

Until step 7, the old flow is fully intact; stop using the new workflows and
nothing is lost. After step 7, the old workflows can be restored from git for
as long as helm-charts is only archived, not deleted; OCM components published
by the new flow are compatible with the old consumers (same names, same shape).
