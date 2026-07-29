$ErrorActionPreference = "Stop"

$serviceDataPath = Join-Path $env:ProgramData "Lumen"
$serviceDataSddl = "O:SYG:SYD:P(A;OICI;FA;;;SY)(A;OICI;FA;;;BA)"
$trustedWriterSids = @("S-1-5-18", "S-1-5-32-544")

if (Test-Path -LiteralPath $serviceDataPath) {
    $item = Get-Item -LiteralPath $serviceDataPath -Force
    if (-not $item.PSIsContainer) {
        throw "Lumen service data path is not a directory."
    }
    if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw "Lumen service data directory must not be a reparse point."
    }
} else {
    New-Item -ItemType Directory -Path $serviceDataPath | Out-Null
}

$security = New-Object System.Security.AccessControl.DirectorySecurity
$security.SetSecurityDescriptorSddlForm(
    $serviceDataSddl,
    [System.Security.AccessControl.AccessControlSections]::All
)
Set-Acl -LiteralPath $serviceDataPath -AclObject $security

$actual = Get-Acl -LiteralPath $serviceDataPath
$ownerSid = ([System.Security.Principal.NTAccount]$actual.Owner).Translate(
    [System.Security.Principal.SecurityIdentifier]
).Value
if ($ownerSid -ne "S-1-5-18" -or -not $actual.AreAccessRulesProtected) {
    throw "Lumen service data owner or DACL protection does not match policy."
}
$rules = @($actual.Access)
if ($rules.Count -ne 2) {
    throw "Lumen service data DACL contains an unexpected ACE count."
}
foreach ($rule in $rules) {
    $sid = $rule.IdentityReference.Translate(
        [System.Security.Principal.SecurityIdentifier]
    ).Value
    if ($sid -notin $trustedWriterSids -or
        $rule.AccessControlType -ne [System.Security.AccessControl.AccessControlType]::Allow -or
        $rule.FileSystemRights -ne [System.Security.AccessControl.FileSystemRights]::FullControl -or
        $rule.InheritanceFlags -ne (
            [System.Security.AccessControl.InheritanceFlags]::ContainerInherit -bor
            [System.Security.AccessControl.InheritanceFlags]::ObjectInherit
        ) -or
        $rule.PropagationFlags -ne [System.Security.AccessControl.PropagationFlags]::None -or
        $rule.IsInherited) {
        throw "Lumen service data DACL contains an untrusted or malformed ACE."
    }
}
