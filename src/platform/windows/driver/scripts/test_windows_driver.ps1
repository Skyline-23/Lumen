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

$certificate = Join-Path $PackageDirectory "LumenIddCxTest.cer"
$certificateThumbprint = $null
if (Test-Path $certificate) {
    $certificateThumbprint = (Get-PfxCertificate -FilePath $certificate).Thumbprint
}
$qaSucceeded = $false
try {
    & (Join-Path $PSScriptRoot "install_windows_driver.ps1") -PackageDirectory $PackageDirectory

    $unauthorizedReceipt = Join-Path $EvidenceDirectory "unauthorized-probes.jsonl"
    Remove-Item $unauthorizedReceipt -Force -ErrorAction SilentlyContinue
    & $qa --expect-denied --output $unauthorizedReceipt
    if ($LASTEXITCODE -ne 0) { throw "The administrator process was not denied by the system-only device ACL." }

    $authorizedReceipt = Join-Path $EvidenceDirectory "authorized-probes.jsonl"
    Remove-Item $authorizedReceipt -Force -ErrorAction SilentlyContinue
    $taskName = "LumenIddCxQa-$([Guid]::NewGuid().ToString('N'))"
    $action = New-ScheduledTaskAction -Execute $qa -Argument "--authorized --output `"$authorizedReceipt`""
    $principal = New-ScheduledTaskPrincipal -UserId "SYSTEM" -LogonType ServiceAccount -RunLevel Highest
    $trigger = New-ScheduledTaskTrigger -Once -At (Get-Date).AddMinutes(5)
    Register-ScheduledTask -TaskName $taskName -Action $action -Principal $principal -Trigger $trigger | Out-Null
    try {
        $startedAt = Get-Date
        Start-ScheduledTask -TaskName $taskName
        $taskCompleted = $false
        for ($attempt = 0; $attempt -lt 60; $attempt++) {
            Start-Sleep -Milliseconds 500
            $task = Get-ScheduledTask -TaskName $taskName
            $taskInfo = Get-ScheduledTaskInfo -TaskName $taskName
            if ($taskInfo.LastRunTime -ge $startedAt -and $task.State -ne "Running") {
                $taskCompleted = $true
                break
            }
        }
        if (-not $taskCompleted) { throw "The LocalSystem QA task did not complete within 30 seconds." }
        if ($taskInfo.LastTaskResult -ne 0) { throw "The LocalSystem QA harness failed with code $($taskInfo.LastTaskResult)." }
    }
    finally {
        Unregister-ScheduledTask -TaskName $taskName -Confirm:$false -ErrorAction SilentlyContinue
    }

    $unauthorizedProbes = @(Get-Content $unauthorizedReceipt | ForEach-Object { $_ | ConvertFrom-Json })
    $authorizedProbes = @(Get-Content $authorizedReceipt | ForEach-Object { $_ | ConvertFrom-Json })
    $allProbes = @($unauthorizedProbes + $authorizedProbes)
    $failedProbes = @($allProbes | Where-Object result -ne 0)
    if ($failedProbes.Count -ne 0) { throw "One or more driver QA probes failed." }
    $requiredProbes = @(
        "unauthorized_open", "first_owner", "second_owner", "query_health",
        "malformed_version", "oversize_event", "stale_generation", "create_monitor",
        "start_encoder", "stop_cancels_access_unit_1", "restart_accepts_access_unit_1",
        "stop_cancels_access_unit_2", "restart_accepts_access_unit_2", "cancel_event",
        "orphan_health_1", "orphan_query_1", "orphan_adopt_1",
        "orphan_health_2", "orphan_query_2", "orphan_adopt_2",
        "orphan_remove_after_repeated_crash"
    )
    foreach ($probe in $requiredProbes) {
        if (@($allProbes | Where-Object probe -eq $probe).Count -ne 1) {
            throw "Expected exactly one receipt for probe $probe."
        }
    }

    $devices = @(Get-PnpDevice -PresentOnly | Where-Object HardwareID -Contains "ROOT\LumenIddCx")
    if ($devices.Count -ne 1) { throw "Expected exactly one installed Lumen IDD device; found $($devices.Count)." }
    $pnputilOutput = & pnputil.exe /enum-devices /deviceid "ROOT\LumenIddCx" /drivers
    if ($LASTEXITCODE -ne 0) { throw "pnputil device query failed." }
    $pnputilOutput | Set-Content (Join-Path $EvidenceDirectory "pnputil-query.log")
    $devices | ConvertTo-Json | Set-Content (Join-Path $EvidenceDirectory "device-inventory.json")
    $qaSucceeded = $true
}
finally {
    if (-not $qaSucceeded -or -not $KeepInstalled) {
        & (Join-Path $PSScriptRoot "uninstall_windows_driver.ps1") -CertificateThumbprint $certificateThumbprint
    }
}
