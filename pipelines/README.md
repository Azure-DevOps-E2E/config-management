# NexusCart Azure Pipelines

The five runtime repositories each own one readable Azure Pipeline. Every
service file declares its trigger, variables, stages, jobs, and Azure-native
tasks. Only reusable script implementations live in this repository.

## Runtime pipeline flow

| Git update | Stages that run | Result |
|---|---|---|
| Push to `feature/*` | `CI` | Test, coverage, lint, and build validation only |
| Push or merge to `dev` | `CI -> BuildCandidate -> DeployDev -> VerifyDev` | Build once, scan, push an immutable candidate, deploy and verify DEV |
| Merge `dev` into `main` | `CI -> ResolveCandidate -> PromoteImage -> DeployProd -> VerifyProd -> Release` | Promote the exact DEV image without rebuilding, deploy PROD, then create a Git tag and GitHub Release |
| Direct push to `main` | `CI -> ResolveCandidate` | CI runs, but production promotion is skipped because the commit did not come from `dev` |

Pull-request validation is not enabled separately. A push to a `feature/*`
branch already supplies the CI status without starting a duplicate PR run.

Use a merge commit or a fast-forward when merging `dev` into `main`.
Squash and rebase merges intentionally do not qualify as production
promotions because they cannot be mapped safely to an immutable DEV image.

## Pipeline ownership

The entry point in every runtime repository keeps the complete operational
shape visible:

```text
azure-pipelines.yml
|-- resources.repositories (alias: templates)
|-- variables
`-- extends pipeline-contract.yml
    `-- pipelineStages
        |-- CI
        |-- BuildCandidate / DeployDev / VerifyDev
        `-- ResolveCandidate / PromoteImage / DeployProd / VerifyProd / Release
```

Azure-native operations stay inline in each service pipeline, including
checkout, runtime setup, report publication, Docker, Helm, PowerShell, and
GitHub Release tasks. Shared templates are used only for scripts such as test
commands, Trivy scanning, candidate resolution, and digest-safe image
promotion.

The required outer contract is:

```yaml
extends:
  template: pipelines/templates/pipeline-contract.yml@templates
  parameters:
    pipelineStages:
    - stage: CI
      # jobs and steps remain visible here
```

## Image promotion

The `dev` pipeline builds and scans these tags:

```text
<acr>/<service>:candidate-<dev-commit-sha>
<acr>/<service>:dev
```

A qualifying `main` pipeline resolves the commit merged from `dev`, pulls
`candidate-<dev-commit-sha>`, and retags that same image as:

```text
<acr>/<service>:v1.0.<Build.BuildId>
<acr>/<service>:prod
```

The promotion script compares the source, release, and `prod` digests. It
fails if the candidate is missing or if any digest changes. There is no
production rebuild or fallback build.

Helm deploys the immutable candidate tag to DEV and the immutable release tag
to PROD. The mutable `dev` and `prod` tags are convenience pointers only.

## Git tag and GitHub Release

After PROD deployment and verification succeed, `GitHubRelease@1`:

1. creates `v1.0.<Build.BuildId>` at the triggering `main` commit;
2. creates a GitHub Release with the same tag;
3. includes the promoted image, digest, DEV candidate commit, PROD commit, and
   generated changelog.

The tag and release are therefore not created when deployment or verification
fails.

## Required Azure DevOps configuration

Create and authorize variable group `nexuscart-shared` for all five runtime
pipelines:

| Variable | Purpose |
|---|---|
| `acrLoginServer` | ACR hostname, for example `nexuscart.azurecr.io` |
| `azureServiceConnection` | Azure Resource Manager service connection name |
| `aksResourceGroup` | AKS resource group |
| `aksClusterName` | AKS cluster |
| `devBaseUrl` | Public DEV gateway base URL |
| `prodBaseUrl` | Public PROD gateway base URL |

Each service pipeline independently declares its service name, image
repository, runtime version, report paths, Dockerfile, Trivy version,
candidate tag, release tag, chart path, and service connection aliases.

Required service connections:

| Name | Requirement |
|---|---|
| `github.com_Azure-DevOps-E2E` | Read `config-management`; for releases it must be an OAuth or PAT GitHub connection with repository contents write permission |
| `acrLoginServer` | Docker Registry connection with ACR pull and push permission |
| value of `azureServiceConnection` | Azure Resource Manager access to the target AKS cluster |

Use the existing environments `Development` and `Production`. Put the
production approval/check on `Production`; the YAML deployment job
automatically waits for that environment check.

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

| Azure Pipeline | YAML source |
|---|---|
| `frontend` | `frontend/azure-pipelines.yml` |
| `api-gateway` | `api-gateway/azure-pipelines.yml` |
| `user-service` | `user-service/azure-pipelines.yml` |
| `catalog-service` | `catalog-service/azure-pipelines.yml` |
| `order-service` | `order-service/azure-pipelines.yml` |
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
docker compose -f compose.yaml config --quiet
docker compose up --build --detach --wait
./scripts/health.ps1 -BaseUrl http://localhost:8080
./scripts/smoke.ps1 -BaseUrl http://localhost:8080
docker compose down --remove-orphans
```
