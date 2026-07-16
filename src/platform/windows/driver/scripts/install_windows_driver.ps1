[CmdletBinding()]
param([Parameter(Mandatory)][string]$PackageDirectory)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

$principal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw "Driver installation requires an elevated PowerShell session."
}

$PackageDirectory = (Resolve-Path $PackageDirectory).Path
$inf = Join-Path $PackageDirectory "LumenIddCx.inf"
$certificate = Join-Path $PackageDirectory "LumenIddCxTest.cer"
if (-not (Test-Path $inf)) { throw "Missing $inf." }

$certificateThumbprint = $null
$installSucceeded = $false
try {
    if (Test-Path $certificate) {
        $certificateThumbprint = (Get-PfxCertificate -FilePath $certificate).Thumbprint
        Import-Certificate -FilePath $certificate -CertStoreLocation Cert:\LocalMachine\Root | Out-Null
        Import-Certificate -FilePath $certificate -CertStoreLocation Cert:\LocalMachine\TrustedPublisher | Out-Null
    }

    & pnputil.exe /add-driver $inf /install
    if ($LASTEXITCODE -ne 0) { throw "pnputil failed to stage the driver package." }

    $devcon = Get-ChildItem (Join-Path ${env:ProgramFiles(x86)} "Windows Kits\10\Tools") -Filter devcon.exe -Recurse |
        Where-Object { $_.FullName -match '\\x64\\' } |
        Sort-Object FullName -Descending |
        Select-Object -First 1 -ExpandProperty FullName
    if (-not $devcon) { throw "WDK devcon.exe x64 was not found." }

    $devices = @(Get-PnpDevice -PresentOnly | Where-Object HardwareID -Contains "ROOT\LumenIddCx")
    if ($devices.Count -eq 0) {
        & $devcon install $inf "Root\LumenIddCx"
        if ($LASTEXITCODE -ne 0) { throw "devcon failed to create the root-enumerated adapter." }
    }
    $devices = @()
    for ($attempt = 0; $attempt -lt 60; $attempt++) {
        $devices = @(Get-PnpDevice -PresentOnly | Where-Object HardwareID -Contains "ROOT\LumenIddCx")
        if ($devices.Count -eq 1) { break }
        Start-Sleep -Milliseconds 500
    }
    if ($devices.Count -ne 1) { throw "Expected exactly one Lumen IDD device after 30 seconds; found $($devices.Count)." }
    $installSucceeded = $true
}
finally {
    if (-not $installSucceeded) {
        & (Join-Path $PSScriptRoot "uninstall_windows_driver.ps1") -CertificateThumbprint $certificateThumbprint
    }
}
$devices
