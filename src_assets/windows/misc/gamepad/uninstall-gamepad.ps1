Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$roots = @(
    "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*",
    "HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*"
)
$entry = Get-ItemProperty -Path $roots -ErrorAction SilentlyContinue |
    Where-Object { $_.DisplayName -like "ViGEm Bus Driver*" } |
    Select-Object -First 1

if ($null -eq $entry) {
    Write-Information "ViGEm Bus Driver is not installed."
    exit 0
}

$command = if ($entry.QuietUninstallString) {
    $entry.QuietUninstallString
} else {
    $entry.UninstallString
}
if ([string]::IsNullOrWhiteSpace($command)) {
    throw "ViGEm Bus Driver does not expose an uninstall command."
}

if ($command -match '^"([^"]+)"\s*(.*)$') {
    $program = $matches[1]
    $arguments = $matches[2]
} elseif ($command -match '^(\S+)\s*(.*)$') {
    $program = $matches[1]
    $arguments = $matches[2]
} else {
    throw "ViGEm Bus Driver uninstall command is malformed."
}

if ([System.IO.Path]::GetFileName($program) -ieq "msiexec.exe") {
    $arguments = "$arguments /qn /norestart"
}
$process = Start-Process -FilePath $program -ArgumentList $arguments -Wait -PassThru
if ($process.ExitCode -notin 0, 1605, 3010) {
    throw "ViGEm Bus Driver uninstall failed with exit code $($process.ExitCode)."
}

exit $process.ExitCode
