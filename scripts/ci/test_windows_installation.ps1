[CmdletBinding()]
param(
    [string]$InstallDirectory = "${env:ProgramFiles}\Lumen",
    [ValidateRange(1029, 65515)]
    [int]$BasePort = 47989
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
Assert-InstallationCondition (Test-Path -LiteralPath $applicationPath -PathType Leaf) `
    "Lumen.exe is missing from the installation directory."
Assert-InstallationCondition (Test-Path -LiteralPath $servicePath -PathType Leaf) `
    "LumenService.exe is missing from the installation directory."

$service = Get-CimInstance Win32_Service -Filter "Name='LumenService'" `
    -ErrorAction SilentlyContinue
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
    Get-NetFirewallRule -DisplayName "Lumen" -ErrorAction SilentlyContinue |
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

$controlPort = $BasePort + 1
$sessionPort = $BasePort + 21
$tcpListener = @(
    Get-NetTCPConnection -State Listen -LocalPort $controlPort `
        -ErrorAction SilentlyContinue
)
$udpListener = @(
    Get-NetUDPEndpoint -LocalPort $sessionPort -ErrorAction SilentlyContinue
)
Assert-InstallationCondition ($tcpListener.Count -gt 0) `
    "Lumen is not listening on the HTTPS control port $controlPort."
Assert-InstallationCondition ($udpListener.Count -gt 0) `
    "Lumen is not listening on the QUIC session port $sessionPort."

$virtualDisplays = @(
    Get-PnpDevice -Class Display -PresentOnly -ErrorAction SilentlyContinue |
        Where-Object {
            $_.FriendlyName -match "Lumen|SudoMaker Virtual Display"
        }
)
Assert-InstallationCondition ($virtualDisplays.Count -gt 0) `
    "No supported virtual display adapter is present."

$result = [ordered]@{
    passed = $failures.Count -eq 0
    computer = $env:COMPUTERNAME
    architecture = $env:PROCESSOR_ARCHITECTURE
    administrator = $isAdministrator
    installDirectory = $InstallDirectory
    service = if ($null -eq $service) { $null } else {
        [ordered]@{
            state = $service.State
            startMode = $service.StartMode
            path = $service.PathName
        }
    }
    listeners = [ordered]@{
        controlHTTPS = $controlPort
        controlReady = $tcpListener.Count -gt 0
        sessionQUIC = $sessionPort
        sessionReady = $udpListener.Count -gt 0
    }
    virtualDisplays = @($virtualDisplays | ForEach-Object { $_.FriendlyName })
    failures = @($failures)
}

$result | ConvertTo-Json -Depth 5
if ($failures.Count -gt 0) {
    exit 1
}
