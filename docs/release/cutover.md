# Cutover: moving the new release process into the platform-mesh organisation

The new release process was developed and tested in the `xrstf-pm` scratch
organisation (forks of `platform-mesh`, `helm-charts` and `.github`). This
document lists, in order, what has to happen to put it into production. Steps
1–6 are additive and leave the existing release flow untouched; step 7 is the
flip.

## 0. Decisions to take before starting

| | Question | Options |
|---|---|---|
| O2 | OCM signature name | keep `helm-charts.platform-mesh` (what consumers verify today) **or** switch to `platform-mesh.platform-mesh` (CN of the monorepo's existing cert). A switch is a consumer-visible change like the last one (`ocm.platform-mesh` → `helm-charts.platform-mesh` at 0.4.0-build.516) and needs a migration note |
| RFC 015 | First unified version | CalVer `26.10.0` (October 2026) per the RFC; `VERSION` says `26.10`. Above every existing component and chart version, so nothing is a downgrade. |

Recommendation: O2 keep `helm-charts.platform-mesh` (set the repo variable
`OCM_SIGNATURE_NAME` accordingly and use the helm-charts signing cert).

Charts keep their location `ghcr.io/platform-mesh/helm-charts/<chart>` and
images theirs (`ghcr.io/platform-mesh/platform-mesh/<image>`); only the
repository that publishes them changes.

Consumer-visible changes to announce with the first release (`docs/release/migration-26.10.md`,
to be written at cutover once O2 is decided):

- all charts and OCM components carry the Platform Mesh version; version
  constraints on individual charts must be adjusted (e.g. a Flux `HelmRelease`
  pinning `account-operator` `0.21.x` becomes `26.10.x`)
- component images are tagged `ghcr.io/platform-mesh/platform-mesh/<image>:vX.Y.Z`
  (the Platform Mesh version instead of the component's own)
- O2 as decided

## 1. Import helm-charts into the monorepo

The import scripts (`git filter-repo` with a path mapping, a byte-for-byte
verification of every tag, and the `--allow-unrelated-histories` merge) are a
one-off and live outside the repository. Rehearsed twice in the fork: the
rewrite is deterministic, so a second import on top of a newer helm-charts
`main` produces the same commits for the shared history and git can merge the
fork's work onto it (`git merge --squash`). Paths that helm-charts deleted in
the meantime must stay in the mapping (otherwise commits become empty and tags
move). **Freeze chart changes in helm-charts** from the import on, or they have
to be replayed.

## 2. Add the new tooling

Port the fork's work as one squashed commit on top of the import merge:
`ocm/`, `hack/release/`, the new workflows, `charts/Taskfile.yaml`, docs; then
`hack/charts/zero-chart-versions.sh` and `task charts:docs charts:helmtest-update`
to put the charts into the versionless shape. The old per-component workflows
go in the same step (`release.yml` only triggers on `v*` tags, which do not exist
yet).

## 3. Repository configuration

Re-enable the schedules commented out with `# FORK:`
(`grep -rn "FORK:" .github/workflows`).

`install-kind.yml` (kind install + Playwright smoke test) needs the
`ubuntu-latest-large` runner and could not be run in the fork; its first run
happens in the real organisation. Everything up to "Wait for Platform Mesh"
was verified on a default runner, where the stack then runs out of CPU.

| Kind | Name | Value |
|---|---|---|
| secret | `OCM_SIGNING_PRIVATE_KEY`, `OCM_SIGNING_CERT` | the key/cert matching the chosen signature name (O2). Both exist in helm-charts today. |
| variable | `OCM_SIGNATURE_NAME` | per O2 |
| variable | `OCM_MIRROR_FROM` | **leave unset** |
| branch protection | `main` | require the `ci` checks (and `pr-gate`), as for the old per-component workflows |

GHCR package access: the existing packages under
`ghcr.io/platform-mesh/helm-charts/*` and
`ghcr.io/platform-mesh/component-descriptors/*` were created by the helm-charts
repository, and GHCR only lets the creating repository's `GITHUB_TOKEN` push.
Two ways out:

- **GitHub App token (preferred)**: the old helm-charts `job-ocm.yml` already
  used the "PM Publisher" app (id `1415820`, secret `PM_PUBLISHER_PRIVATE_KEY`)
  for exactly this. Add `actions/create-github-app-token` to `job-publish.yml`
  and use its token for `helm registry login` / `ocm-config.sh` instead of
  `GITHUB_TOKEN`. One secret, no per-package clicking.
- Per package: Package settings → Manage Actions access → add
  `platform-mesh/platform-mesh` with write.

Check with a prerelease run (step 5) which packages are affected; the failure
is explicit. New packages are created private on first push and must be made
public once (no API for this; the fork needed ~60 clicks).

## 4. Component images

Nothing to migrate: `job-publish.yml` publishes the same
`github.com/platform-mesh/images/<component>` components to `ghcr.io/platform-mesh`
that the old `image-ocm-legacy` job did, just at the Platform Mesh version.
The images of the UI repositories (portal, iam-ui, marketplace-ui) and of
example-httpbin-operator continue to come from those repositories.

## 5. Dress rehearsal: prerelease and release candidate

```sh
gh workflow run prerelease.yml          # publishes 26.10.0-dev.N.g<sha>
# install it on kind per installation/README.md with --set-string ocm.version=<that version>
git tag v26.10.0-rc.1 && git push origin v26.10.0-rc.1
```

Both go through the complete new pipeline against the real registry and
consumers. Check the `verify` job, install the rc per `installation/README.md`
(kind and a real cluster), run the Playwright tests in `tests/`.

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
3. Tag `v26.10.0`, then create `release-26.10`
   and bump `VERSION` to `26.11` on `main`.

## Rollback

Until step 7, the old flow is fully intact; stop using the new workflows and
nothing is lost. After step 7, the old workflows can be restored from git for
as long as helm-charts is only archived, not deleted; OCM components published
by the new flow are compatible with the old consumers (same names, same shape).
