[CmdletBinding()]
param(
    [ValidateSet("all", "shared", "unified", "diagnostics")]
    [string]$Target = "all",
    [string]$OutputDirectory,
    [ValidateSet("production", "diagnostics")]
    [string]$Profile = "production"
)

$ErrorActionPreference = "Stop"
if ($Target -eq "diagnostics") { $Profile = "diagnostics"; $Target = "all" }

$repositoryRoot = Split-Path -Parent $PSScriptRoot
if ([string]::IsNullOrWhiteSpace($OutputDirectory)) {
    $OutputDirectory = Join-Path $repositoryRoot "dist"
} elseif (-not [System.IO.Path]::IsPathRooted($OutputDirectory)) {
    $OutputDirectory = Join-Path (Get-Location) $OutputDirectory
}

$sourcePath = Join-Path $repositoryRoot "src"
if (-not (Test-Path -LiteralPath $sourcePath -PathType Container)) {
    throw "Could not find $sourcePath"
}

$outputDirectoryPath = [System.IO.Path]::GetFullPath($OutputDirectory)
New-Item -ItemType Directory -Force -Path $outputDirectoryPath | Out-Null

if ($Target -notin @("all", "shared", "unified")) {
    throw "Target must be all, shared, or unified"
}

$manifestPath = Join-Path $repositoryRoot "info.toml"
if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) {
    throw "Could not find $manifestPath"
}

$artifactName = if ($Profile -eq "diagnostics") { "tm-webhooks-diagnostics.op" } else { "tm-webhooks.op" }
$artifactPath = Join-Path $outputDirectoryPath $artifactName
$temporaryZip = Join-Path $outputDirectoryPath "$([guid]::NewGuid()).zip"
$stage = Join-Path ([System.IO.Path]::GetTempPath()) "tm-webhooks-$([guid]::NewGuid())"
try {
    New-Item -ItemType Directory -Path $stage | Out-Null
    Copy-Item -LiteralPath $manifestPath -Destination (Join-Path $stage "info.toml")
    Copy-Item -LiteralPath $sourcePath -Destination (Join-Path $stage "src") -Recurse
    $entries = @((Join-Path $stage "info.toml"), (Join-Path $stage "src"))
    if ($Profile -eq "diagnostics") {
        $diagnostics = Join-Path $stage "diagnostics"
        New-Item -ItemType Directory -Path (Join-Path $diagnostics "generated") -Force | Out-Null
        Copy-Item -Path (Join-Path $repositoryRoot "diagnostics/*.as") -Destination $diagnostics
        Copy-Item -Path (Join-Path $repositoryRoot "diagnostics/generated/*.as") -Destination (Join-Path $diagnostics "generated")
        Copy-Item -Path (Join-Path $repositoryRoot "diagnostics/generated/*-api.json") -Destination (Join-Path $diagnostics "generated")
        $manifest = (Get-Content -LiteralPath $manifestPath -Raw) -replace 'name = "TM Webhooks"', 'name = "TM Webhooks (Diagnostics)"' -replace '(?m)^siteid = .*\r?\n', ''
        $manifest += "`ndefines = [""DIAGNOSTICS""]`n"
        [System.IO.File]::WriteAllText((Join-Path $stage "info.toml"), $manifest)
        $entries += $diagnostics
    } else {
        $mainPath = Join-Path $stage "src/Main.as"
        $main = (Get-Content -LiteralPath $mainPath -Raw) -replace '(?ms)^// DIAGNOSTICS_FRAME_PUMP_BEGIN\r?\n.*?^// DIAGNOSTICS_FRAME_PUMP_END\r?\n?', ''
        [System.IO.File]::WriteAllText($mainPath, $main)
    }
    Compress-Archive -LiteralPath $entries -DestinationPath $temporaryZip -CompressionLevel Optimal
    Copy-Item -LiteralPath $temporaryZip -Destination $artifactPath -Force
    Write-Output "Created $artifactPath"
} finally {
    Remove-Item -LiteralPath $temporaryZip -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $stage -Recurse -Force -ErrorAction SilentlyContinue
}
