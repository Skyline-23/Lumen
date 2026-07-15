[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$PackageDirectory,
    [string]$EvidenceDirectory,
    [switch]$KeepInstalled
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

$PackageDirectory = (Resolve-Path $PackageDirectory).Path
if (-not $EvidenceDirectory) {
    $EvidenceDirectory = Join-Path $PackageDirectory "qa"
}
New-Item $EvidenceDirectory -ItemType Directory -Force | Out-Null
$qa = Join-Path $PackageDirectory "lumen_driver_device_qa.exe"
if (-not (Test-Path $qa)) { throw "Missing $qa." }

& (Join-Path $PSScriptRoot "install_windows_driver.ps1") -PackageDirectory $PackageDirectory

$unauthorizedReceipt = Join-Path $EvidenceDirectory "unauthorized.json"
& $qa --expect-denied --output $unauthorizedReceipt
if ($LASTEXITCODE -ne 0) { throw "The administrator process was not denied by the system-only device ACL." }

$authorizedReceipt = Join-Path $EvidenceDirectory "authorized.json"
Remove-Item $authorizedReceipt -Force -ErrorAction SilentlyContinue
$taskName = "LumenIddCxQa-$([Guid]::NewGuid().ToString('N'))"
$action = New-ScheduledTaskAction -Execute $qa -Argument "--authorized --output `"$authorizedReceipt`""
$principal = New-ScheduledTaskPrincipal -UserId "SYSTEM" -LogonType ServiceAccount -RunLevel Highest
$trigger = New-ScheduledTaskTrigger -Once -At (Get-Date).AddMinutes(5)
Register-ScheduledTask -TaskName $taskName -Action $action -Principal $principal -Trigger $trigger | Out-Null
try {
    Start-ScheduledTask -TaskName $taskName
    for ($attempt = 0; $attempt -lt 60 -and -not (Test-Path $authorizedReceipt); $attempt++) {
        Start-Sleep -Milliseconds 500
    }
    if (-not (Test-Path $authorizedReceipt)) { throw "The LocalSystem QA task did not produce a receipt within 30 seconds." }
    $authorized = Get-Content $authorizedReceipt -Raw | ConvertFrom-Json
    if ($authorized.result -ne 0) { throw "The LocalSystem QA harness failed with code $($authorized.result)." }
}
finally {
    Unregister-ScheduledTask -TaskName $taskName -Confirm:$false -ErrorAction SilentlyContinue
}

$devices = @(Get-PnpDevice -PresentOnly | Where-Object InstanceId -Like "ROOT\LUMENIDDCX*")
if ($devices.Count -ne 1) { throw "Expected exactly one installed Lumen IDD device; found $($devices.Count)." }
& pnputil.exe /enum-devices /deviceid "ROOT\LumenIddCx" /drivers |
    Set-Content (Join-Path $EvidenceDirectory "pnputil-query.log")

$receipt = [ordered]@{
    sddl = "D:P(A;;GA;;;SY)"
    presentDeviceCount = $devices.Count
    unauthorizedProcess = "access-denied"
    authorizedOwner = "LocalSystem"
    secondOwner = "busy"
    malformedVersion = "rejected"
    oversizedRead = "rejected"
    staleGeneration = "rejected"
    cancellation = "completed-with-operation-aborted"
}
$receipt | ConvertTo-Json | Set-Content (Join-Path $EvidenceDirectory "device-acl.json")

if (-not $KeepInstalled) {
    & (Join-Path $PSScriptRoot "uninstall_windows_driver.ps1")
}
