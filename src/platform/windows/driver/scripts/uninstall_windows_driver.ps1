[CmdletBinding()]
param([string]$CertificateThumbprint)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

$principal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw "Driver removal requires an elevated PowerShell session."
}

try {
    $devices = @(Get-PnpDevice | Where-Object InstanceId -Like "ROOT\LUMENIDDCX*")
    $devcon = Get-ChildItem (Join-Path ${env:ProgramFiles(x86)} "Windows Kits\10\Tools") -Filter devcon.exe -Recurse |
        Where-Object { $_.FullName -match '\\x64\\' } |
        Sort-Object FullName -Descending |
        Select-Object -First 1 -ExpandProperty FullName
    if ($devices.Count -ne 0 -and -not $devcon) { throw "WDK devcon.exe x64 is required to remove the root device." }
    if ($devices.Count -ne 0) {
        & $devcon remove "Root\LumenIddCx"
        if ($LASTEXITCODE -ne 0) { throw "devcon failed to remove the root-enumerated adapter." }
    }

    $packages = @(Get-WindowsDriver -Online -All | Where-Object OriginalFileName -Like "*\LumenIddCx.inf")
    foreach ($package in $packages) {
        & pnputil.exe /delete-driver $package.Driver /uninstall /force
        if ($LASTEXITCODE -ne 0) { throw "pnputil failed to remove $($package.Driver)." }
    }

    $remainingDevices = @(Get-PnpDevice | Where-Object InstanceId -Like "ROOT\LUMENIDDCX*")
    if ($remainingDevices.Count -ne 0) { throw "The Lumen root device remains after removal." }
    $remainingPackages = @(Get-WindowsDriver -Online -All | Where-Object OriginalFileName -Like "*\LumenIddCx.inf")
    if ($remainingPackages.Count -ne 0) { throw "The Lumen driver package remains after removal." }
}
finally {
    if ($CertificateThumbprint) {
        foreach ($store in @("Root", "TrustedPublisher")) {
            $certificatePath = "Cert:\LocalMachine\$store\$CertificateThumbprint"
            if (Test-Path $certificatePath) {
                Remove-Item $certificatePath -Force
            }
            if (Test-Path $certificatePath) { throw "Failed to remove test certificate $CertificateThumbprint from $store." }
        }
    }
}
