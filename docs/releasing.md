# Releasing Lumen

This runbook covers signed macOS and Windows releases, GitHub Release
publication, and Homebrew cask updates. Regular CI artifacts are intentionally
not distribution-signed; public distribution starts only from a stable tag.

## Release topology

| Trigger | Output | Signing | Publication |
| --- | --- | --- | --- |
| Push or pull request to `develop` or `main` | Rust checks, macOS DMG, Windows NSIS installer | Ad hoc/unsigned | GitHub Actions artifacts only |
| Tag matching `v<major>.<minor>.<patch>` | macOS DMG and Windows NSIS installer | Developer ID + notarization, Authenticode + timestamp | GitHub Release, then `Skyline-23/homebrew-lumen` |

Only stable semantic-version tags such as `v0.5.0` trigger the release
workflow. Prerelease names such as `v0.5.0-alpha.1` do not match it.

The release order is:

1. Build, sign, notarize, and staple the macOS DMG.
2. Build and Authenticode-sign the Windows installer.
3. Publish both files in one GitHub Release.
4. Compute the published DMG SHA-256 and update `Casks/lumen.rb` in the tap.

The Homebrew job cannot run until both signed packages and the GitHub Release
succeed.

## Repository constants

| Name | Value |
| --- | --- |
| Source repository | `Skyline-23/Lumen` |
| Homebrew tap | `Skyline-23/homebrew-lumen` |
| macOS bundle identifier | `dev.skyline23.lumen.app` |
| Apple development team | `Q23JLSJCCV` |
| Developer ID label | `Developer ID Application: Buseong Kim (Q23JLSJCCV)` |
| macOS release architecture | `arm64` |
| Windows release architecture | `x86_64` |
| Stable tag format | `v<major>.<minor>.<patch>` |

Do not put passwords, private keys, certificate payloads, or API-key contents
in this document, issues, commits, release notes, or command history.

## Required GitHub secrets

Configure repository-level Actions secrets in `Skyline-23/Lumen`.

| Secret | Required value | Source |
| --- | --- | --- |
| `APPLE_CERTIFICATE_P12_BASE64` | Base64 of a PKCS#12 containing the Developer ID Application certificate and private key | Export from Keychain Access |
| `APPLE_CERTIFICATE_PASSWORD` | Password chosen when exporting the PKCS#12 file | Release operator |
| `APPLE_NOTARY_KEY_BASE64` | Base64 of the App Store Connect API `.p8` key | App Store Connect |
| `APPLE_NOTARY_KEY_ID` | API key ID paired with the `.p8` file | App Store Connect |
| `APPLE_NOTARY_ISSUER_ID` | Team API issuer ID | App Store Connect |
| `WINDOWS_CERTIFICATE_PFX_BASE64` | Base64 of the Authenticode certificate and private key in PFX format | Windows code-signing certificate provider |
| `WINDOWS_CERTIFICATE_PASSWORD` | PFX export password | Release operator |
| `HOMEBREW_TAP_SSH_KEY` | Private half of the write-enabled deploy key for the tap | Tap deploy-key setup |

The matching Homebrew public deploy key must be installed on
`Skyline-23/homebrew-lumen` with write access. It should not grant access to any
other repository.

List configured secret names without revealing their values:

```bash
gh secret list --repo Skyline-23/Lumen
```

The list must contain all eight names before creating a release tag.

## Preparing Apple credentials

### Developer ID certificate

The PKCS#12 export must contain both the public certificate and its private key.
In Keychain Access, select the Developer ID Application identity under **My
Certificates**, export it as `.p12`, and assign a unique export password.

Confirm the local identity before exporting:

```bash
security find-identity -v -p codesigning login.keychain-db \
  | grep 'Developer ID Application: Buseong Kim (Q23JLSJCCV)'
```

Upload the encoded certificate and password without committing either file:

```bash
base64 < Lumen-Developer-ID.p12 | tr -d '\n' \
  | gh secret set APPLE_CERTIFICATE_P12_BASE64 --repo Skyline-23/Lumen

read -s 'P12_PASSWORD?PKCS#12 password: '
printf '%s' "$P12_PASSWORD" \
  | gh secret set APPLE_CERTIFICATE_PASSWORD --repo Skyline-23/Lumen
unset P12_PASSWORD
```

Delete the exported `.p12` after the secret is confirmed and retain the source
identity in the protected login keychain.

### App Store Connect notarization key

Create or select an App Store Connect team API key that can submit software for
notarization. Record the key ID and issuer ID when downloading its one-time
`.p8` file.

```bash
base64 < AuthKey_<key-id>.p8 | tr -d '\n' \
  | gh secret set APPLE_NOTARY_KEY_BASE64 --repo Skyline-23/Lumen

printf '%s' '<key-id>' \
  | gh secret set APPLE_NOTARY_KEY_ID --repo Skyline-23/Lumen

printf '%s' '<issuer-id>' \
  | gh secret set APPLE_NOTARY_ISSUER_ID --repo Skyline-23/Lumen
```

For an optional local notarization preflight, store the same values in a
keychain profile and query its history:

```bash
xcrun notarytool store-credentials lumen-release \
  --key AuthKey_<key-id>.p8 \
  --key-id '<key-id>' \
  --issuer '<issuer-id>'

xcrun notarytool history --keychain-profile lumen-release
```

The GitHub workflow creates a separate temporary keychain and notary profile;
it does not depend on the local `lumen-release` profile.

## Preparing Windows credentials

Export the Authenticode identity and private key as a password-protected PFX.
The certificate must permit code signing and must be accepted by Windows for
public distribution. The workflow timestamps signatures through DigiCert, so a
successfully timestamped release remains verifiable after certificate expiry.

From a shell that has the PFX file:

```bash
base64 < Lumen-Authenticode.pfx | tr -d '\n' \
  | gh secret set WINDOWS_CERTIFICATE_PFX_BASE64 --repo Skyline-23/Lumen

read -s 'PFX_PASSWORD?PFX password: '
printf '%s' "$PFX_PASSWORD" \
  | gh secret set WINDOWS_CERTIFICATE_PASSWORD --repo Skyline-23/Lumen
unset PFX_PASSWORD
```

Delete the exported PFX after uploading it. Retain the original identity in the
certificate provider's protected storage.

## Pre-release checklist

Do not create the tag until every item below is true.

- The intended `develop` commit has a green `CI` workflow.
- `develop` has been reviewed and merged into `main`.
- Local `main` is clean and matches `origin/main`.
- All eight GitHub secret names are present.
- The target version has no existing tag or GitHub Release.
- The release notes or generated commit range have been reviewed.
- The Homebrew tap deploy key is verified and has write access.

Run the mechanical checks from the repository root:

```bash
git fetch origin --tags
git status --short
git rev-parse HEAD
git rev-parse origin/main
gh secret list --repo Skyline-23/Lumen
gh release view "v<version>" --repo Skyline-23/Lumen
git rev-parse "v<version>"
```

The final two commands should report that the proposed version does not exist.
If `HEAD` differs from `origin/main`, stop and reconcile the branch first.

## Publish a release

Update and verify `main`:

```bash
git switch main
git pull --ff-only origin main
git status --short
```

Create the tag on the exact reviewed `main` commit. A signed Git tag is
preferred when the release operator has a configured signing key:

```bash
VERSION=0.5.0
git tag -s "v${VERSION}" -m "Lumen v${VERSION}"
git push origin "v${VERSION}"
```

If signed Git tags are not available, use an annotated tag only after recording
that exception in the release process:

```bash
git tag -a "v${VERSION}" -m "Lumen v${VERSION}"
git push origin "v${VERSION}"
```

The workflow checks that the tag exists but does not independently enforce a
cryptographic Git-tag signature.

Monitor the release:

```bash
gh run list --workflow Release --limit 5 --repo Skyline-23/Lumen
gh run watch <run-id> --exit-status --repo Skyline-23/Lumen
```

## Verify the published release

Inspect the release and download both files into a clean directory:

```bash
gh release view "v${VERSION}" --repo Skyline-23/Lumen
mkdir -p "/tmp/lumen-release-${VERSION}"
gh release download "v${VERSION}" \
  --repo Skyline-23/Lumen \
  --dir "/tmp/lumen-release-${VERSION}"
shasum -a 256 "/tmp/lumen-release-${VERSION}"/*
```

Verify macOS signing, Gatekeeper acceptance, and notarization:

```bash
hdiutil attach "/tmp/lumen-release-${VERSION}/Lumen-${VERSION}-macOS.dmg"
codesign --verify --deep --strict --verbose=2 /Volumes/Lumen/Lumen.app
spctl --assess --type execute --verbose=2 /Volumes/Lumen/Lumen.app
xcrun stapler validate "/tmp/lumen-release-${VERSION}/Lumen-${VERSION}-macOS.dmg"
hdiutil detach /Volumes/Lumen
```

On Windows, verify the downloaded installer from PowerShell:

```powershell
$signature = Get-AuthenticodeSignature .\Lumen-<version>-Windows-x86_64.exe
$signature | Format-List Status, StatusMessage, SignerCertificate, TimeStamperCertificate
if ($signature.Status -ne 'Valid') { throw 'Invalid Lumen installer signature' }
```

Verify the project Homebrew cask with its fully qualified name. This avoids the
unrelated `lumen` cask in Homebrew's default repository.

```bash
brew tap Skyline-23/lumen
brew update
brew info --cask Skyline-23/lumen/lumen
brew install --cask Skyline-23/lumen/lumen
```

Confirm that `Casks/lumen.rb` in `Skyline-23/homebrew-lumen` contains the same
version and DMG SHA-256 as the GitHub Release.

## Failure recovery

### Build or signing failed before publication

No GitHub Release or cask update exists yet. Inspect the failed job, correct the
credential or code issue, and rerun only failed jobs:

```bash
gh run view <run-id> --log-failed --repo Skyline-23/Lumen
gh run rerun <run-id> --failed --repo Skyline-23/Lumen
```

Do not replace a published tag. If the tag has not produced a release and the
commit itself is wrong, delete the remote and local tag only after confirming
that no release exists, then create a new tag on the corrected commit.

### GitHub Release succeeded but Homebrew failed

The signed artifacts remain valid. Fix the tap permission or cask-style error
and rerun the failed Homebrew job. Do not rebuild or retag solely for a tap
failure.

### A published release is defective

Do not move, delete, or overwrite its tag. Publish a new patch version and let
the workflow advance the Homebrew cask to that immutable release.

## Local package smoke test

Local packaging is useful before merging but is not a substitute for the
GitHub release workflow.

```bash
LUMEN_VERSION=0.5.0 \
LUMEN_SIGNING_IDENTITY='Developer ID Application: Buseong Kim (Q23JLSJCCV)' \
LUMEN_NOTARY_PROFILE=lumen-release \
scripts/macos/package.sh --skip-tests
```

Use `--install` only when intentionally replacing `/Applications/Lumen.app`.
See [Installing Lumen](installing.md) for canonical-path and duplicate-app
rules.
