[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidatePattern('^[a-z0-9-]+$')]
    [string]$ServiceName,

    [Parameter(Mandatory = $true)]
    [ValidateSet('dev', 'prod')]
    [string]$Environment,

    [Parameter(Mandatory = $true)]
    [ValidatePattern('^[A-Za-z0-9.-]+(?::[0-9]+)?$')]
    [string]$Registry,

    [Parameter(Mandatory = $true)]
    [ValidatePattern('^[A-Za-z0-9._-]+$')]
    [string]$ImageTag,

    [string]$RepositoryRoot = (Get-Location).Path,

    [ValidatePattern('^[A-Za-z0-9._/-]+$')]
    [string]$Branch = 'main',

    [ValidateRange(1, 5)]
    [int]$PushAttempts = 3
)

$ErrorActionPreference = 'Stop'
$repositoryPath = (Resolve-Path -LiteralPath $RepositoryRoot).Path
$relativeManifestPath = "deploy/helm/$ServiceName/values-$Environment.yaml"
$manifestPath = Join-Path $repositoryPath $relativeManifestPath
$updateBranch = "pipeline/$ServiceName-$Environment-$ImageTag"
$startMarker = '# BEGIN AZURE PIPELINES MANAGED IMAGE'
$endMarker = '# END AZURE PIPELINES MANAGED IMAGE'

if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) {
    throw "Manifest does not exist: $manifestPath"
}

Push-Location $repositoryPath
try {
    git rev-parse --is-inside-work-tree | Out-Null
    if ($LASTEXITCODE -ne 0) {
        throw "RepositoryRoot is not a Git working tree: $repositoryPath"
    }

    git fetch origin "+refs/heads/${Branch}:refs/remotes/origin/$Branch"
    if ($LASTEXITCODE -ne 0) {
        throw "Unable to fetch origin/$Branch"
    }

    git checkout -B $updateBranch "refs/remotes/origin/$Branch"
    if ($LASTEXITCODE -ne 0) {
        throw "Unable to create manifest update branch from origin/$Branch"
    }

    git config user.name 'azure-pipelines[bot]'
    git config user.email 'azure-pipelines@users.noreply.github.com'

    $content = Get-Content -LiteralPath $manifestPath -Raw
    $managedBlock = @"
$startMarker
image:
  repository: $Registry/$ServiceName
  tag: "$ImageTag"
appVersion: "$ImageTag"
$endMarker
"@

    $escapedStart = [regex]::Escape($startMarker)
    $escapedEnd = [regex]::Escape($endMarker)
    $managedPattern = "(?ms)$escapedStart.*?$escapedEnd"

    if ([regex]::IsMatch($content, $managedPattern)) {
        $updatedContent = [regex]::Replace($content, $managedPattern, $managedBlock)
    }
    else {
        if ($content -match '(?m)^image:\s*$' -or $content -match '(?m)^appVersion:\s*') {
            throw "Manifest already contains unmanaged image or appVersion keys: $relativeManifestPath"
        }

        $updatedContent = "$($content.TrimEnd())`n`n$managedBlock`n"
    }

    Set-Content -LiteralPath $manifestPath -Value $updatedContent -NoNewline -Encoding utf8
    git add -- $relativeManifestPath

    git diff --cached --quiet
    if ($LASTEXITCODE -eq 0) {
        Write-Host "Manifest already points to $Registry/${ServiceName}:$ImageTag"
        Write-Host "##vso[task.setvariable variable=manifestChanged;isOutput=true]false"
        Write-Host "##vso[task.setvariable variable=manifestCommit;isOutput=true]$(git rev-parse HEAD)"
        return
    }
    if ($LASTEXITCODE -ne 1) {
        throw "Unable to inspect the staged manifest change"
    }

    $commitMessage = "chore(manifest): update $ServiceName $Environment to $ImageTag [skip ci]"
    git commit -m $commitMessage
    if ($LASTEXITCODE -ne 0) {
        throw "Unable to commit $relativeManifestPath"
    }

    for ($attempt = 1; $attempt -le $PushAttempts; $attempt++) {
        git push origin "HEAD:refs/heads/$Branch"
        if ($LASTEXITCODE -eq 0) {
            $manifestCommit = git rev-parse HEAD
            Write-Host "Updated $relativeManifestPath to $Registry/${ServiceName}:$ImageTag"
            Write-Host "Manifest commit: $manifestCommit"
            Write-Host "##vso[task.setvariable variable=manifestChanged;isOutput=true]true"
            Write-Host "##vso[task.setvariable variable=manifestCommit;isOutput=true]$manifestCommit"
            return
        }

        if ($attempt -eq $PushAttempts) {
            throw "Unable to push manifest after $PushAttempts attempts"
        }

        Write-Host "Manifest push raced with another update; rebasing attempt $attempt"
        git fetch origin "+refs/heads/${Branch}:refs/remotes/origin/$Branch"
        if ($LASTEXITCODE -ne 0) {
            throw "Unable to refresh origin/$Branch before retry"
        }

        git rebase "refs/remotes/origin/$Branch"
        if ($LASTEXITCODE -ne 0) {
            git rebase --abort
            throw "Manifest update conflicts with a concurrent change"
        }
    }
}
finally {
    Pop-Location
}
