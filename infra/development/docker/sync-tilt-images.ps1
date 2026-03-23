param(
    [string]$Namespace = "default",
    [string]$ImagePrefix = "ride-sharing/",
    [string]$NodeContainer = "desktop-control-plane",
    [switch]$SkipRestart,
    [switch]$DryRun
)

$ErrorActionPreference = "Stop"

function Test-Command {
    param([string]$Name)
    if (-not (Get-Command $Name -ErrorAction SilentlyContinue)) {
        throw "Missing required command: $Name"
    }
}

Test-Command "kubectl"
Test-Command "docker"

$currentContext = kubectl config current-context
if ($LASTEXITCODE -ne 0) {
    throw "Unable to read current kubectl context."
}

if ($currentContext -ne "docker-desktop") {
    Write-Host "Warning: current context is '$currentContext'. This script is intended for docker-desktop." -ForegroundColor Yellow
}

Write-Host "Collecting workload images in namespace '$Namespace'..." -ForegroundColor Cyan
$rawImages = kubectl get deployment,statefulset,daemonset -n $Namespace -o jsonpath="{..image}"
if ($LASTEXITCODE -ne 0) {
    throw "Failed to query Kubernetes workloads in namespace '$Namespace'."
}

$images = @($rawImages -split "\s+" | Where-Object { $_ -and $_.StartsWith($ImagePrefix) } | Sort-Object -Unique)
if ($images.Count -eq 0) {
    Write-Host "No images found with prefix '$ImagePrefix'. Nothing to sync." -ForegroundColor Yellow
    exit 0
}

Write-Host "Found $($images.Count) image(s) to sync:" -ForegroundColor Green
$images | ForEach-Object { Write-Host " - $_" }

$importedImages = New-Object System.Collections.Generic.List[string]

foreach ($image in $images) {
    Write-Host "`nSyncing image: $image" -ForegroundColor Cyan

    docker image inspect $image *> $null
    if ($LASTEXITCODE -ne 0) {
        Write-Host "  Skipped: image not found in local Docker daemon." -ForegroundColor Yellow
        continue
    }

    if ($DryRun) {
        Write-Host "  DryRun: docker save $image | docker exec -i $NodeContainer ctr -n k8s.io images import -" -ForegroundColor DarkYellow
        $importedImages.Add($image)
        continue
    }

    docker save $image | docker exec -i $NodeContainer ctr -n k8s.io images import -
    if ($LASTEXITCODE -ne 0) {
        throw "Failed to import image '$image' into containerd node '$NodeContainer'."
    }

    Write-Host "  Imported successfully." -ForegroundColor Green
    $importedImages.Add($image)
}

if ($importedImages.Count -eq 0) {
    Write-Host "`nNo images were imported. Nothing to restart." -ForegroundColor Yellow
    exit 0
}

if ($SkipRestart) {
    Write-Host "`nSkipRestart set. Sync completed without rollout restart." -ForegroundColor Yellow
    exit 0
}

Write-Host "`nResolving deployments that use synced images..." -ForegroundColor Cyan
$deploymentRows = kubectl get deployment -n $Namespace -o jsonpath="{range .items[*]}{.metadata.name}{'|'}{range .spec.template.spec.containers[*]}{.image}{' '}{end}{'\n'}{end}"
if ($LASTEXITCODE -ne 0) {
    throw "Failed to read deployments in namespace '$Namespace'."
}

$deploymentsToRestart = New-Object System.Collections.Generic.HashSet[string]
foreach ($row in ($deploymentRows -split "`n" | Where-Object { $_ -match "\|" })) {
    $parts = $row.Split("|", 2)
    $deploymentName = $parts[0].Trim()
    $deploymentImages = @($parts[1].Trim() -split "\s+" | Where-Object { $_ })

    foreach ($image in $importedImages) {
        if ($deploymentImages -contains $image) {
            [void]$deploymentsToRestart.Add($deploymentName)
            break
        }
    }
}

if ($deploymentsToRestart.Count -eq 0) {
    Write-Host "No deployment matched synced image tags. Sync completed." -ForegroundColor Yellow
    exit 0
}

Write-Host "Restarting deployments:" -ForegroundColor Green
foreach ($name in $deploymentsToRestart) {
    Write-Host " - $name"
    if ($DryRun) {
        continue
    }

    kubectl rollout restart deployment/$name -n $Namespace
    if ($LASTEXITCODE -ne 0) {
        throw "Failed to restart deployment '$name'."
    }
}

if (-not $DryRun) {
    Write-Host "`nWaiting for rollout status..." -ForegroundColor Cyan
    foreach ($name in $deploymentsToRestart) {
        kubectl rollout status deployment/$name -n $Namespace --timeout=180s
        if ($LASTEXITCODE -ne 0) {
            throw "Rollout did not complete for deployment '$name'."
        }
    }
}

if ($DryRun) {
    Write-Host "`nDryRun done. Would sync $($importedImages.Count) image(s) and restart $($deploymentsToRestart.Count) deployment(s)." -ForegroundColor Green
} else {
    Write-Host "`nDone. Synced $($importedImages.Count) image(s) and restarted $($deploymentsToRestart.Count) deployment(s)." -ForegroundColor Green
}
