[CmdletBinding()]
param(
    [string]$InstallDirectory = "${env:ProgramFiles}\Lumen",
    [ValidateRange(1029, 65515)]
    [int]$BasePort = 47989,
    [ValidateRange(1, 120)]
    [int]$ReadinessTimeoutSeconds = 30,
    [bool]$ExpectDesktopShortcut = $true
)

$ErrorActionPreference = "Stop"
$failures = New-Object System.Collections.Generic.List[string]

function Assert-InstallationCondition {
    param(
        [bool]$Condition,
        [string]$Message
    )

    if (-not $Condition) {
        $failures.Add($Message)
    }
}

$principal = New-Object Security.Principal.WindowsPrincipal(
    [Security.Principal.WindowsIdentity]::GetCurrent()
)
$isAdministrator = $principal.IsInRole(
    [Security.Principal.WindowsBuiltInRole]::Administrator
)
Assert-InstallationCondition $isAdministrator "The smoke test must run as an administrator."

$applicationPath = Join-Path $InstallDirectory "Lumen.exe"
$servicePath = Join-Path $InstallDirectory "tools\LumenService.exe"
$driverSetupPath = Join-Path $InstallDirectory "tools\LumenDriverSetup.exe"
$driverInfPath = Join-Path $InstallDirectory "driver\LumenIddCx.inf"
Assert-InstallationCondition (Test-Path -LiteralPath $applicationPath -PathType Leaf) `
    "Lumen.exe is missing from the installation directory."
Assert-InstallationCondition (Test-Path -LiteralPath $servicePath -PathType Leaf) `
    "LumenService.exe is missing from the installation directory."
Assert-InstallationCondition (Test-Path -LiteralPath $driverSetupPath -PathType Leaf) `
    "LumenDriverSetup.exe is missing from the installation directory."
Assert-InstallationCondition (Test-Path -LiteralPath $driverInfPath -PathType Leaf) `
    "The packaged Lumen IDD INF is missing from the installation directory."

$uninstallRoots = @(
    "HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*",
    "HKLM:\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*"
)
$products = @(
    Get-ItemProperty $uninstallRoots -ErrorAction SilentlyContinue |
        Where-Object { $_.DisplayName -eq "Lumen" }
)
Assert-InstallationCondition ($products.Count -eq 1) `
    "Expected exactly one registered Lumen MSI product, found $($products.Count)."

$controlPort = $BasePort + 1
$sessionPort = $BasePort + 21
$readinessDeadline = (Get-Date).AddSeconds($ReadinessTimeoutSeconds)
do {
    $service = Get-CimInstance Win32_Service -Filter "Name='LumenService'" `
        -ErrorAction SilentlyContinue
    $lumenProcesses = @(
        Get-CimInstance Win32_Process -ErrorAction SilentlyContinue |
            Where-Object { $_.ExecutablePath -eq $applicationPath }
    )
    $lumenProcessIDs = @($lumenProcesses | ForEach-Object { [uint32]$_.ProcessId })
    $tcpListeners = @(
        Get-NetTCPConnection -State Listen -LocalPort $controlPort `
            -ErrorAction SilentlyContinue
    )
    $udpListeners = @(
        Get-NetUDPEndpoint -LocalPort $sessionPort -ErrorAction SilentlyContinue
    )
    $lumenTCPListeners = @(
        $tcpListeners |
            Where-Object { $lumenProcessIDs -contains [uint32]$_.OwningProcess }
    )
    $lumenUDPListeners = @(
        $udpListeners |
            Where-Object { $lumenProcessIDs -contains [uint32]$_.OwningProcess }
    )
    $virtualDisplays = @(
        Get-CimInstance Win32_PnPEntity -ErrorAction SilentlyContinue |
            Where-Object { $_.HardwareID -contains "Root\LumenIddCx" }
    )
    $runtimeReady =
        $null -ne $service -and
        $service.State -eq "Running" -and
        $lumenProcessIDs.Count -eq 1 -and
        $lumenTCPListeners.Count -eq 1 -and
        $lumenUDPListeners.Count -eq 1 -and
        $virtualDisplays.Count -eq 1 -and
        $virtualDisplays[0].ConfigManagerErrorCode -eq 0
    if (-not $runtimeReady -and (Get-Date) -lt $readinessDeadline) {
        Start-Sleep -Milliseconds 250
    }
} while (-not $runtimeReady -and (Get-Date) -lt $readinessDeadline)

Assert-InstallationCondition ($null -ne $service) "LumenService is not installed."
if ($null -ne $service) {
    $normalizedServicePath = $service.PathName.Trim('"')
    Assert-InstallationCondition ($normalizedServicePath -eq $servicePath) `
        "LumenService points at an unexpected executable."
    Assert-InstallationCondition ($service.State -eq "Running") `
        "LumenService is not running."
    Assert-InstallationCondition ($service.StartMode -eq "Auto") `
        "LumenService is not configured for automatic startup."
}

$firewallRules = @(
    Get-NetFirewallRule -DisplayName "Lumen *" -ErrorAction SilentlyContinue |
        Where-Object {
            $_.Direction -eq "Inbound" -and
            $_.Action -eq "Allow" -and
            $_.Enabled -eq "True"
        }
)
$firewallProtocols = @(
    $firewallRules |
        Get-NetFirewallPortFilter |
        ForEach-Object { $_.Protocol.ToString().ToUpperInvariant() }
)
$firewallApplications = @(
    $firewallRules |
        Get-NetFirewallApplicationFilter |
        ForEach-Object { $_.Program.Trim('"') }
)
Assert-InstallationCondition ($firewallProtocols -contains "TCP") `
    "The inbound TCP firewall rule is missing."
Assert-InstallationCondition ($firewallProtocols -contains "UDP") `
    "The inbound UDP firewall rule is missing."
Assert-InstallationCondition ($firewallApplications -contains $applicationPath) `
    "The firewall rule does not target the installed Lumen.exe."

Assert-InstallationCondition ($lumenProcessIDs.Count -eq 1) `
    "Expected exactly one installed Lumen.exe host process, found $($lumenProcessIDs.Count)."
Assert-InstallationCondition ($lumenTCPListeners.Count -eq 1) `
    "Lumen is not listening on the HTTPS control port $controlPort."
Assert-InstallationCondition ($lumenUDPListeners.Count -eq 1) `
    "Lumen is not listening on the QUIC session port $sessionPort."

Assert-InstallationCondition ($virtualDisplays.Count -eq 1) `
    "Expected exactly one Lumen virtual display adapter, found $($virtualDisplays.Count)."
Assert-InstallationCondition (@(
    $virtualDisplays |
        Where-Object { $_.ConfigManagerErrorCode -ne 0 }
).Count -eq 0) `
    "The Lumen virtual display adapter is present but not healthy."

$desktopShortcuts = @(
    "$env:USERPROFILE\Desktop\Lumen.lnk",
    "$env:PUBLIC\Desktop\Lumen.lnk"
) | Where-Object { Test-Path -LiteralPath $_ -PathType Leaf }
Assert-InstallationCondition ((-not $ExpectDesktopShortcut) -or $desktopShortcuts.Count -eq 1) `
    "The requested Lumen desktop shortcut is missing or duplicated."

$errorLogs = @(
    "$env:ProgramData\Lumen\service-error.log",
    "$env:ProgramData\Lumen\host-startup-error.log"
) | Where-Object { Test-Path -LiteralPath $_ -PathType Leaf }
Assert-InstallationCondition ($errorLogs.Count -eq 0) `
    "The installed runtime left a current startup error receipt: $($errorLogs -join ', ')."

$result = [ordered]@{
    passed = $failures.Count -eq 0
    computer = $env:COMPUTERNAME
    architecture = $env:PROCESSOR_ARCHITECTURE
    administrator = $isAdministrator
    installDirectory = $InstallDirectory
    productVersions = @($products | ForEach-Object { $_.DisplayVersion })
    service = if ($null -eq $service) { $null } else {
        [ordered]@{
            state = $service.State
            startMode = $service.StartMode
            path = $service.PathName
        }
    }
    hostProcessIDs = $lumenProcessIDs
    listeners = [ordered]@{
        controlHTTPS = $controlPort
        controlReady = $lumenTCPListeners.Count -gt 0
        sessionQUIC = $sessionPort
        sessionReady = $lumenUDPListeners.Count -gt 0
    }
    virtualDisplays = @($virtualDisplays | ForEach-Object {
        [ordered]@{
            name = $_.Name
            instanceID = $_.PNPDeviceID
            problemCode = $_.ConfigManagerErrorCode
        }
    })
    desktopShortcuts = @($desktopShortcuts)
    errorLogs = @($errorLogs)
    failures = @($failures)
}

$result | ConvertTo-Json -Depth 5
if ($failures.Count -gt 0) {
    exit 1
}
