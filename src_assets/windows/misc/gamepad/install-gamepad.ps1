Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$driver = Join-Path $env:SystemRoot "System32\drivers\ViGEmBus.sys"
if (Test-Path -LiteralPath $driver) {
    $version = [System.Version](Get-Item -LiteralPath $driver).VersionInfo.FileVersion
    if ($version -ge [System.Version]"1.17") {
        Write-Information "ViGEm Bus $version is already installed."
        exit 0
    }
}

$installer = Join-Path $PSScriptRoot "vigembus_installer.exe"
if (-not (Test-Path -LiteralPath $installer)) {
    throw "ViGEm Bus installer is missing: $installer"
}

$process = Start-Process -FilePath $installer -ArgumentList "/passive", "/promptrestart" -Wait -PassThru
if ($process.ExitCode -notin 0, 3010) {
    throw "ViGEm Bus installation failed with exit code $($process.ExitCode)."
}

exit $process.ExitCode
