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
$installMutated = $false
try {
    $devcon = Get-ChildItem (Join-Path ${env:ProgramFiles(x86)} "Windows Kits\10\Tools") -Filter devcon.exe -Recurse |
        Where-Object { $_.FullName -match '\\x64\\' } |
        Sort-Object FullName -Descending |
        Select-Object -First 1 -ExpandProperty FullName
    if (-not $devcon) { throw "WDK devcon.exe x64 was not found." }

    $devices = @(Get-PnpDevice -PresentOnly | Where-Object HardwareID -Contains "ROOT\LumenIddCx")
    if ($devices.Count -gt 1) {
        throw "Expected at most one existing Lumen IDD device; found $($devices.Count)."
    }

    $installMutated = $true
    if (Test-Path $certificate) {
        $certificateThumbprint = (Get-PfxCertificate -FilePath $certificate).Thumbprint
        Import-Certificate -FilePath $certificate -CertStoreLocation Cert:\LocalMachine\Root | Out-Null
        Import-Certificate -FilePath $certificate -CertStoreLocation Cert:\LocalMachine\TrustedPublisher | Out-Null
    }

    if ($devices.Count -eq 0) {
        # There is no matching device yet. Stage the package first; devcon
        # creates the ROOT\LumenIddCx node and binds the staged package below.
        & pnputil.exe /add-driver $inf | Out-Host
    }
    else {
        # An existing node can be upgraded in place.
        & pnputil.exe /add-driver $inf /install | Out-Host
    }
    $pnputilExitCode = $LASTEXITCODE
    if ($pnputilExitCode -notin @(0, 3010)) {
        throw "pnputil failed to stage and apply the driver package with code $pnputilExitCode."
    }

    if ($devices.Count -eq 0) {
        & $devcon install $inf "Root\LumenIddCx" | Out-Host
        $devconExitCode = $LASTEXITCODE
        if ($devconExitCode -notin @(0, 1)) {
            throw "devcon failed to create the root-enumerated adapter with code $devconExitCode."
        }
    }

    $devices = @()
    $problem = $null
    for ($attempt = 0; $attempt -lt 60; $attempt++) {
        $devices = @(Get-PnpDevice -PresentOnly | Where-Object HardwareID -Contains "ROOT\LumenIddCx")
        if ($devices.Count -eq 1) {
            $problem = Get-PnpDeviceProperty `
                -InstanceId $devices[0].InstanceId `
                -KeyName "DEVPKEY_Device_ProblemCode"
            if ($devices[0].Status -eq "OK" -and [int]$problem.Data -eq 0) {
                break
            }
            if ([int]$problem.Data -eq 14) {
                break
            }
        }
        Start-Sleep -Milliseconds 500
    }
    if ($devices.Count -ne 1) { throw "Expected exactly one Lumen IDD device after 30 seconds; found $($devices.Count)." }
    if ($null -ne $problem -and [int]$problem.Data -eq 14) {
        $installSucceeded = $true
        [pscustomobject]@{
            InstanceId = $devices[0].InstanceId
            Status = $devices[0].Status
            ProblemCode = [int]$problem.Data
            RestartRequired = $true
        }
        return
    }
    if ($null -eq $problem -or $devices[0].Status -ne "OK" -or [int]$problem.Data -ne 0) {
        throw "Lumen IDD did not start: status=$($devices[0].Status) problem=$($problem.Data)."
    }
    $installSucceeded = $true
}
finally {
    if (-not $installSucceeded -and $installMutated) {
        & (Join-Path $PSScriptRoot "uninstall_windows_driver.ps1") -CertificateThumbprint $certificateThumbprint
    }
}
[pscustomobject]@{
    InstanceId = $devices[0].InstanceId
    Status = $devices[0].Status
    ProblemCode = 0
    RestartRequired = $false
}
