#Requires -Version 5.1
<#
.SYNOPSIS
    Downloads an installer and prints the fields needed for a WINGET_MANIFEST
    entry in config/settings.json.

.DESCRIPTION
    When bumping a WINGET_MANIFEST-backed app to a new version, run this with
    the new DownloadUrl. It downloads the file, computes SHA256, and prints
    a ready-to-paste JSON fragment.

.EXAMPLE
    .\tools\Get-WingetManifestFields.ps1 `
        -Url 'https://github.com/rustdesk/rustdesk/releases/download/1.4.6/rustdesk-1.4.6-x86_64.msi' `
        -PackageIdentifier 'RustDesk.RustDesk' `
        -PackageVersion '1.4.6'
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$Url,
    [string]$PackageIdentifier,
    [string]$PackageVersion,
    [ValidateSet('x64','x86','arm64')][string]$Architecture = 'x64',
    [ValidateSet('msi','wix','exe','burn','nullsoft','inno','portable','zip','appx','msix')][string]$ManifestInstallerType = 'wix'
)

$ErrorActionPreference = 'Stop'

$tmp = Join-Path $env:TEMP ("wdm-probe-" + [guid]::NewGuid().ToString('N') + [System.IO.Path]::GetExtension(([uri]$Url).AbsolutePath))

try {
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    Write-Host "Downloading $Url ..." -ForegroundColor Cyan
    Invoke-WebRequest -Uri $Url -OutFile $tmp -UseBasicParsing

    $sha = (Get-FileHash -Path $tmp -Algorithm SHA256).Hash.ToUpper()
    $size = (Get-Item $tmp).Length
    $sizeMB = [math]::Round($size / 1MB, 2)

    Write-Host ""
    Write-Host "SHA256 : $sha"
    Write-Host "Size   : $size bytes ($sizeMB MB)"
    Write-Host ""
    Write-Host "--- Paste into config/settings.json Apps.<Stage> ---" -ForegroundColor Green
    $fragment = [ordered]@{
        InstallerType          = 'WINGET_MANIFEST'
        PackageIdentifier      = $PackageIdentifier
        PackageVersion         = $PackageVersion
        Architecture           = $Architecture
        ManifestInstallerType  = $ManifestInstallerType
        DownloadUrl            = $Url
        InstallerSha256        = $sha
    }
    ($fragment | ConvertTo-Json -Depth 3)
} finally {
    if (Test-Path $tmp) { Remove-Item $tmp -Force }
}
