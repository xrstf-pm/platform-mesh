# Per-chart OCM settings

`hack/release/build-aggregate.sh` publishes an OCM component for every chart
under `charts/`. The default shape, derived from the chart's `Chart.yaml`, is

```
github.com/platform-mesh/<chart>:<version>              service component
  ├─ chart → github.com/platform-mesh/helm-charts/<chart>:<version>
  │            resource "chart" (the packaged chart in the OCI registry)
  │            source   "chart" (this repository at the released commit)
  └─ image → github.com/platform-mesh/images/<chart>:<appVersion>
               (only if appVersion is set and not 0.0.0; published by
               component-release.yml for components built here, or by the
               component's own repository otherwise)
```

A file `ocm/charts/<chart>.yaml` adjusts that for one chart. All keys are
optional:

| Key | Effect |
|---|---|
| `publish: false` | push the chart to the registry, but create no OCM component (library charts) |
| `flat: true` | put the chart resource directly into the service component, no `helm-charts/` layer |
| `images:` | list of OCM resources (third-party images the chart deploys). Published as `github.com/platform-mesh/images/<chart>:<version>` – note: versioned like the *chart* – and referenced as `image` |
| `extraReferences:` | additional `componentReferences` of the service component. Values may use `${VARIABLES}` from `ocm/versions.yaml` |

Charts without such a file use the defaults.
