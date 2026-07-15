[CmdletBinding()]
param()

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

$principal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw "Driver removal requires an elevated PowerShell session."
}

$devcon = Get-ChildItem (Join-Path ${env:ProgramFiles(x86)} "Windows Kits\10\Tools") -Filter devcon.exe -Recurse |
    Where-Object { $_.FullName -match '\\x64\\' } |
    Sort-Object FullName -Descending |
    Select-Object -First 1 -ExpandProperty FullName
if ($devcon) {
    & $devcon remove "Root\LumenIddCx"
}

$packages = @(Get-WindowsDriver -Online -All | Where-Object OriginalFileName -Like "*\LumenIddCx.inf")
foreach ($package in $packages) {
    & pnputil.exe /delete-driver $package.Driver /uninstall /force
    if ($LASTEXITCODE -ne 0) { throw "pnputil failed to remove $($package.Driver)." }
}
