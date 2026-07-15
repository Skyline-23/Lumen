[CmdletBinding()]
param(
    [ValidateSet("Debug", "Release")]
    [string]$Configuration = "Release",
    [switch]$TestSign,
    [string]$OutputDirectory
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

if ($env:OS -ne "Windows_NT") {
    throw "Lumen IddCx requires Windows, Visual Studio 2022 C++ tools, and WDK 10.0.26100 or newer."
}

$driverRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
$repoRoot = (Resolve-Path (Join-Path $driverRoot "..\..\..\..")).Path
if (-not $OutputDirectory) {
    $OutputDirectory = Join-Path $driverRoot "build\package\x64\$Configuration"
}
$OutputDirectory = [System.IO.Path]::GetFullPath($OutputDirectory)
$rustTarget = "x86_64-pc-windows-msvc"
$coreLibrary = Join-Path $repoRoot "target\$rustTarget\release\lumen_windows_driver_core.lib"
$project = Join-Path $driverRoot "LumenIddCx.vcxproj"
$driverBinary = Join-Path $driverRoot "build\bin\x64\$Configuration\LumenIddCx.dll"

$vswhere = Join-Path ${env:ProgramFiles(x86)} "Microsoft Visual Studio\Installer\vswhere.exe"
if (-not (Test-Path $vswhere)) {
    throw "vswhere.exe was not found; install Visual Studio 2022 with Desktop C++ and WDK."
}
$msbuild = & $vswhere -latest -products * -requires Microsoft.Component.MSBuild -find MSBuild\**\Bin\MSBuild.exe | Select-Object -First 1
if (-not $msbuild) {
    throw "MSBuild was not found in the latest Visual Studio installation."
}

$kitsBin = Join-Path ${env:ProgramFiles(x86)} "Windows Kits\10\bin"
$inf2cat = Get-ChildItem $kitsBin -Filter inf2cat.exe -Recurse |
    Where-Object { $_.FullName -match '\\x64\\' } |
    Sort-Object FullName -Descending |
    Select-Object -First 1 -ExpandProperty FullName
$signtool = Get-ChildItem $kitsBin -Filter signtool.exe -Recurse |
    Where-Object { $_.FullName -match '\\x64\\' } |
    Sort-Object FullName -Descending |
    Select-Object -First 1 -ExpandProperty FullName
if (-not $inf2cat -or -not $signtool) {
    throw "WDK Inf2Cat.exe and SignTool.exe were not found under $kitsBin."
}

rustup target add $rustTarget
if ($LASTEXITCODE -ne 0) { throw "rustup target add failed." }
cargo test --locked -p lumen-windows-driver-core --manifest-path (Join-Path $repoRoot "Cargo.toml")
if ($LASTEXITCODE -ne 0) { throw "Rust driver boundary tests failed." }
cargo build --locked -p lumen-windows-driver-core --release --target $rustTarget --manifest-path (Join-Path $repoRoot "Cargo.toml")
if ($LASTEXITCODE -ne 0) { throw "Rust driver core build failed." }

$boundaryBuild = Join-Path $driverRoot "build\boundary-windows"
cmake -S $driverRoot -B $boundaryBuild -G "Visual Studio 17 2022" -A x64 "-DLUMEN_DRIVER_CORE_LIBRARY=$coreLibrary"
if ($LASTEXITCODE -ne 0) { throw "CMake boundary-test configuration failed." }
cmake --build $boundaryBuild --config $Configuration --parallel
if ($LASTEXITCODE -ne 0) { throw "C++ boundary-test build failed." }
ctest --test-dir $boundaryBuild -C $Configuration --output-on-failure
if ($LASTEXITCODE -ne 0) { throw "C++ boundary tests failed." }

& $msbuild $project /m /t:Build "/p:Configuration=$Configuration" /p:Platform=x64 "/p:LumenDriverCoreLibrary=$coreLibrary"
if ($LASTEXITCODE -ne 0) { throw "WDK UMDF2 driver build failed." }
if (-not (Test-Path $driverBinary)) {
    throw "MSBuild succeeded without producing $driverBinary."
}

Remove-Item $OutputDirectory -Recurse -Force -ErrorAction SilentlyContinue
New-Item $OutputDirectory -ItemType Directory -Force | Out-Null
Copy-Item $driverBinary (Join-Path $OutputDirectory "LumenIddCx.dll")
Copy-Item (Join-Path $driverRoot "package\LumenIddCx.inf") $OutputDirectory
Copy-Item (Join-Path $boundaryBuild "$Configuration\lumen_driver_device_qa.exe") $OutputDirectory

$certificate = $null
if ($TestSign) {
    $certificate = New-SelfSignedCertificate -Type CodeSigningCert -Subject "CN=Lumen IddCx Test" -CertStoreLocation "Cert:\CurrentUser\My" -HashAlgorithm SHA256
    Export-Certificate -Cert $certificate -FilePath (Join-Path $OutputDirectory "LumenIddCxTest.cer") | Out-Null
    & $signtool sign /fd SHA256 /s My /sha1 $certificate.Thumbprint (Join-Path $OutputDirectory "LumenIddCx.dll")
    if ($LASTEXITCODE -ne 0) { throw "Test signing the driver DLL failed." }
}

& $inf2cat "/driver:$OutputDirectory" /os:10_X64,Server10_X64
if ($LASTEXITCODE -ne 0) { throw "Inf2Cat validation failed." }
if ($TestSign) {
    & $signtool sign /fd SHA256 /s My /sha1 $certificate.Thumbprint (Join-Path $OutputDirectory "LumenIddCx.cat")
    if ($LASTEXITCODE -ne 0) { throw "Test signing the driver catalog failed." }
    Remove-Item "Cert:\CurrentUser\My\$($certificate.Thumbprint)" -Force
}

Get-ChildItem $OutputDirectory | Select-Object Name, Length
