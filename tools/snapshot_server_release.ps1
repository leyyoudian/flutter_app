param(
    [Parameter(Mandatory = $true)]
    [string]$BaseUrl,

    [Parameter(Mandatory = $true)]
    [string]$OutputDirectory,

    [string]$AdminToken = $env:ESP_BAJI_ADMIN_TOKEN
)

$ErrorActionPreference = 'Stop'
$base = $BaseUrl.TrimEnd('/')
$root = [System.IO.Path]::GetFullPath($OutputDirectory)
New-Item -ItemType Directory -Force -Path $root | Out-Null

function Save-Json([string]$Name, $Value) {
    $path = Join-Path $root $Name
    $parent = Split-Path -Parent $path
    New-Item -ItemType Directory -Force -Path $parent | Out-Null
    $Value | ConvertTo-Json -Depth 30 | Set-Content -LiteralPath $path -Encoding utf8
}

function Get-Api([string]$Path, [bool]$Admin = $false) {
    $headers = @{}
    if ($Admin) {
        if ([string]::IsNullOrWhiteSpace($AdminToken)) {
            throw 'ESP_BAJI_ADMIN_TOKEN is required for release history'
        }
        $headers['X-Admin-Token'] = $AdminToken
    }
    Invoke-RestMethod -Uri "$base$Path" -Headers $headers -TimeoutSec 30
}

function Save-RemoteFile($FileMeta) {
    if ($null -eq $FileMeta -or [string]::IsNullOrWhiteSpace($FileMeta.url)) { return }
    $uri = [Uri]::new([Uri]::new("$base/"), [string]$FileMeta.url)
    $relative = $uri.AbsolutePath.TrimStart('/').Replace('/', [IO.Path]::DirectorySeparatorChar)
    $target = Join-Path $root $relative
    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $target) | Out-Null
    if (-not (Test-Path -LiteralPath $target)) {
        Invoke-WebRequest -Uri $uri.AbsoluteUri -OutFile $target -TimeoutSec 300
    }
    if ($FileMeta.size -and (Get-Item -LiteralPath $target).Length -ne [int64]$FileMeta.size) {
        throw "size mismatch: $relative"
    }
    if ($FileMeta.sha256) {
        $actual = (Get-FileHash -LiteralPath $target -Algorithm SHA256).Hash.ToLowerInvariant()
        if ($actual -ne ([string]$FileMeta.sha256).ToLowerInvariant()) {
            throw "sha256 mismatch: $relative"
        }
    }
}

$health = Get-Api '/api/health'
$versions = @{}
foreach ($platform in 'android', 'ios') {
    $versions[$platform] = Get-Api "/api/version?platform=$platform"
}
$ota = @{}
foreach ($hardware in 'esp32s3', 'esp32p4') {
    try { $ota[$hardware] = Get-Api "/api/ota/manifest?hardware=$hardware" } catch {}
}
$catalogs = @{}
foreach ($hardware in 'esp32s3', 'esp32p4') {
    try { $catalogs[$hardware] = Get-Api "/api/factory-catalog?hardware=$hardware" } catch {}
}

$appHistory = @{}
foreach ($platform in 'android', 'ios') {
    $appHistory[$platform] = Get-Api "/api/admin/app-versions?platform=$platform" $true
}
$firmwareHistory = @{}
foreach ($hardware in 'esp32s3', 'esp32p4') {
    $firmwareHistory[$hardware] = Get-Api "/api/admin/firmware-versions?hardware=$hardware" $true
}

Save-Json 'manifest/health.json' $health
Save-Json 'manifest/versions.json' $versions
Save-Json 'manifest/ota.json' $ota
Save-Json 'manifest/factory_catalogs.json' $catalogs
Save-Json 'manifest/app_history.json' $appHistory
Save-Json 'manifest/firmware_history.json' $firmwareHistory

foreach ($history in $appHistory.Values + $firmwareHistory.Values) {
    foreach ($item in @($history.items)) { Save-RemoteFile $item }
}
foreach ($catalog in $catalogs.Values) {
    foreach ($item in @($catalog.items)) {
        foreach ($property in @($item.appFiles.PSObject.Properties)) {
            Save-RemoteFile $property.Value
        }
        foreach ($file in @($item.deviceFiles)) { Save-RemoteFile $file }
    }
}

$files = Get-ChildItem -LiteralPath $root -Recurse -File
$summary = [ordered]@{
    source = $base
    capturedAt = (Get-Date).ToUniversalTime().ToString('o')
    fileCount = $files.Count
    totalBytes = ($files | Measure-Object Length -Sum).Sum
}
Save-Json 'manifest/snapshot.json' $summary
$summary
