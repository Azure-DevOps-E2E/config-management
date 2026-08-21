# NexusCart Azure Pipelines

The five runtime repositories each own four branch-focused Azure Pipelines.
Every YAML file declares its trigger, variables, stages, jobs, and Azure-native
tasks. Active service pipelines use this repository only for the minimal
required contract and reusable script implementations.

## Runtime pipeline flow

| Git update | Stages that run | Result |
|---|---|---|
| Push to `feature/*` | `<service>-ci`: `CI` | Test, coverage, lint, and build validation only |
| Open or update a PR targeting `dev` or `main` | `<service>-ci`: `CI` | Validate the GitHub PR merge commit; no image build or deployment |
| Push or merge to `dev` | `<service>-dev`: `CI -> BuildCandidate -> UpdateManifest` | Build once, scan, push an immutable candidate, then commit its tag to `values-dev.yaml` |
| Merge `dev` into `main` | `<service>-prod`: `CI -> ResolveCandidate`; then queue `<service>-release` manually | Validate the merge source and resolve the exact DEV candidate without rebuilding; the manual release workflow then promotes the image, updates `values-prod.yaml`, and creates the GitHub Release |
| Direct push to `main` | `<service>-prod`: `CI -> ResolveCandidate` | CI runs, but production promotion is skipped because the commit did not come from `dev` |

Pull-request validation is enabled only in `azure-pipelines.yml` for target
branches `dev` and `main`, with older runs automatically canceled when a PR
receives a new commit. DEV and PROD pipeline entry points keep `pr: none`, so
a pull request can never build an image or deploy an environment.

Feature pushes still run branch CI. If a feature branch already has an open
PR to `dev` or `main`, the same update can produce both the feature CI run and
the PR validation run.

Use a merge commit or a fast-forward when merging `dev` into `main`.
Squash and rebase merges intentionally do not qualify as production
promotions because they cannot be mapped safely to an immutable DEV image.

## Pipeline ownership

Every runtime repository keeps the operational shape visible in four entry
points:

```text
azure-pipelines.yml         # feature/*: CI
azure-pipelines-dev.yml     # dev: CI, candidate build, DEV manifest update
azure-pipelines-prod.yml    # main: CI, candidate resolution only
azure-pipelines-release.yml # manual: promote, PROD manifest update, GitHub Release
```

Create four Azure Pipeline definitions for each service and point them to
those files. Use the names `<service>-ci`, `<service>-dev`, `<service>-prod`,
and `<service>-release`.

Azure-native operations stay inline in each service pipeline, including
checkout, report publication, Docker, Bash, deployment jobs, Git tagging, and
Azure-native operations stay inline in each service pipeline, including checkout, report publication, Docker, Bash, deployment jobs, Git tagging, and GitHub Release API calls. The manual release pipeline keeps image promotion, manifest updates, and GitHub Release creation visible.The required outer contract is:

```yaml
extends:
  template: pipelines/templates/pipeline-contract.yml@templates
  parameters:
    pipelineStages:
    - stage: CI
      # jobs and steps remain visible here
```

Self-hosted agents do not need Java, Maven, Node.js, Python, or Go installed.
Each quality job pulls one version-matched Docker Official Image, runs all
dependency installation, linting, tests, and coverage generation in a single
`docker run --rm`, then publishes the mounted reports from the host:

| Runtime input | Docker Hub image |
|---|---|
| Java `21` | `maven:3.9.16-eclipse-temurin-21-alpine` |
| Node.js `24.x` | `node:24.19.0-alpine3.24` |
| Python `3.13` | `python:3.13.14-alpine3.24` |
| Go `1.26.6` | `golang:1.26.6-alpine3.24` |

The source directory is mounted at `/workspace`, so JUnit and coverage files
survive container removal. A per-service home directory under
`$(Pipeline.Workspace)/.ci-container-home` caches downloaded Maven, npm, pip,
and Go dependencies without carrying an old Python virtual environment into a
new run.

The self-hosted Linux agents still require Git, Bash, Docker Engine with socket
access, and Bash and curl for manifest updates and GitHub Release creation. `UseDotNet@2` supplies the SDK
needed by `PublishCodeCoverageResults@2`.

## Image promotion

The `dev` pipeline builds and scans these tags:

```text
<acr>/<service>:<dev-commit-sha>
<acr>/<service>:dev
```

A qualifying `main` pipeline resolves the commit merged from `dev`. The
separate manual release pipeline then pulls `<dev-commit-sha>` and retags that
same image as:

```text
<acr>/<service>:<releaseTag>
<acr>/<service>:prod
```

The promotion script compares the source, release, and `prod` digests. It
fails if the candidate is missing or if any digest changes. There is no
production rebuild or fallback build.

The DEV pipeline commits the immutable dev commit tag to
`deploy/helm/<service>/values-dev.yaml`. After the merge pipeline resolves the
exact candidate, the manual release pipeline commits the immutable release tag
to `values-prod.yaml`. Direct Helm deployment and runtime verification remain
disabled until AKS and public endpoints are available. The mutable `dev` and
`prod` tags are convenience pointers only.

Manifest commits include `[skip ci]`, so updating `config-management` does not
start the separate `system-e2e` pipeline.

## Git tag and GitHub Release

The PROD pipeline only validates the merge source. After `dev` is merged into
`main`, queue the separate manual release pipeline and provide a strict
semantic tag such as `v1.0.119`. The manual workflow validates
`v<major>.<minor>.<patch>` and, if the tag is missing on origin, creates and
pushes it on the current release commit before promotion.

The manual release workflow then:

1. validates the requested Git tag and creates it on origin when it is missing;
2. resolves the GitHub repository slug as `owner/repo`;
3. promotes the exact DEV image without rebuilding;
4. commits `values-prod.yaml`;
5. creates a GitHub Release through the GitHub API with the same tag;
6. includes the promoted image, digest, DEV candidate commit, and PROD commit.

The pipeline creates and pushes the Git tag when needed, then uses that tag for
promotion and the GitHub Release.

## Required Azure DevOps configuration

Create and authorize variable group `nexuscart-shared` for the DEV, PROD, and manual release
pipelines in all five runtime repositories. Feature CI deliberately does not
load the deployment variable group:

| Variable | Purpose |
|---|---|
| `acrLoginServer` | ACR hostname, for example `nexuscart.azurecr.io` |

AKS resource group, cluster, and environment URLs are intentionally not
required while direct deployment and runtime verification are disabled.

Each YAML independently declares only the values it needs, including its
service name, runtime version, report paths, image details, and service
connection aliases.

Required service connections:

| Name | Requirement |
|---|---|
| `github.com_Azure-DevOps-E2E` | Read/write `config-management` so manifest commits can be pushed; read runtime repository tags and create GitHub Releases |
| `acrLoginServer` | Docker Registry connection with ACR pull and push permission |

Use the existing environments `Development` and `Production` for the manifest
update deployment jobs. Put the production approval/check on `Production`;
the PROD manifest cannot be committed until that approval succeeds.

Qodana is not part of these pipelines, so the Marketplace extension and
`QODANA_TOKEN` are not required.

## Required template enforcement

On the GitHub service connection, add an Azure DevOps **Required template**
check after the rollout is verified:

| Field | Value |
|---|---|
| Repository type | GitHub |
| Repository | `Azure-DevOps-E2E/config-management` |
| Ref | `refs/heads/main` |
| Template path | `pipelines/templates/pipeline-contract.yml` |

The repository resource and trigger remain in each root
`azure-pipelines.yml` because Azure must resolve them before loading an
external template.

## Pipeline inventory

| Azure Pipelines | YAML sources |
|---|---|
| `frontend ci`, `frontend dev`, `frontend prod`, `frontend release` | `frontend/azure-pipelines.yml`, `azure-pipelines-dev.yml`, `azure-pipelines-prod.yml`, `azure-pipelines-release.yml` |
| `api-gateway ci`, `api-gateway dev`, `api-gateway prod`, `api-gateway release` | `api-gateway/azure-pipelines.yml`, `azure-pipelines-dev.yml`, `azure-pipelines-prod.yml`, `azure-pipelines-release.yml` |
| `user-service ci`, `user-service dev`, `user-service prod`, `user-service release` | `user-service/azure-pipelines.yml`, `azure-pipelines-dev.yml`, `azure-pipelines-prod.yml`, `azure-pipelines-release.yml` |
| `catalog-service ci`, `catalog-service dev`, `catalog-service prod`, `catalog-service release` | `catalog-service/azure-pipelines.yml`, `azure-pipelines-dev.yml`, `azure-pipelines-prod.yml`, `azure-pipelines-release.yml` |
| `order-service ci`, `order-service dev`, `order-service prod`, `order-service release` | `order-service/azure-pipelines.yml`, `azure-pipelines-dev.yml`, `azure-pipelines-prod.yml`, `azure-pipelines-release.yml` |
| `system-e2e` | `config-management/pipelines/system-e2e.yml` |

Push `config-management` before a runtime repository so the referenced
templates exist on `refs/heads/main`.

## Local validation

Validate all Helm charts:

```bash
for chart in frontend api-gateway user-service catalog-service order-service; do
  helm lint "deploy/helm/$chart"
  helm template "$chart" "deploy/helm/$chart" >/dev/null
done
```

Run the local full-stack verification:

```powershell
docker compose -f compose.yaml config >/dev/null
docker compose up --build --detach --wait
./scripts/e2e.sh -BaseUrl http://localhost:8080
docker compose down --remove-orphans
```
