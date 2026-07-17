# Installing Lumen

Use a release build for normal operation. Developer builds use the same bundle
identifier and can otherwise appear as duplicate Lumen applications in macOS
permission and application pickers.

## macOS

### Requirements

- Apple Silicon Mac
- macOS 15 or newer
- Screen & System Audio Recording permission for desktop capture
- Accessibility permission when keyboard or pointer control is enabled
- Microphone permission only when microphone streaming is enabled

### Homebrew installation

The Lumen project uses the `Skyline-23/lumen` tap. Homebrew's default cask
repository contains an unrelated application with the same `lumen` token, so
always use the fully qualified project cask name.

```bash
brew tap Skyline-23/lumen
brew install --cask Skyline-23/lumen/lumen
```

The cask becomes available after the first signed GitHub release completes.
The release workflow creates `Casks/lumen.rb` in the tap automatically.

Upgrade an existing Homebrew installation with:

```bash
brew update
brew upgrade --cask Skyline-23/lumen/lumen
```

Remove the application while preserving its data with:

```bash
brew uninstall --cask Skyline-23/lumen/lumen
```

Remove the application, saved settings, and application-support data with:

```bash
brew uninstall --cask --zap Skyline-23/lumen/lumen
```

### DMG installation

Download `Lumen-<version>-macOS.dmg` from the project GitHub Release, open it,
and drag `Lumen.app` to `/Applications`. Do not keep a second copy in Downloads,
Desktop, or another Applications directory.

Verify the installed release before opening it:

```bash
codesign --verify --deep --strict --verbose=2 /Applications/Lumen.app
spctl --assess --type execute --verbose=2 /Applications/Lumen.app
```

The canonical installation has:

- path: `/Applications/Lumen.app`
- bundle identifier: `dev.skyline23.lumen.app`
- Apple team identifier: `Q23JLSJCCV`

### Local developer installation

Build the current architecture, verify the signed app, then replace the
canonical application explicitly:

```bash
CONFIGURATION=Release ARCHS="$(uname -m)" CURRENT_ARCH=undefined_arch \
  scripts/rust/build_lumen_engine.sh
cd src/platform/macos
tuist generate --no-open
tuist xcodebuild build \
  -workspace Lumen.xcworkspace \
  -scheme LumenApp \
  -configuration Release \
  -destination 'generic/platform=macOS' \
  -derivedDataPath ../../../build/local-install \
  "ARCHS=$(uname -m)" \
  ONLY_ACTIVE_ARCH=YES
cd ../../..
codesign --verify --deep --strict --verbose=2 \
  build/local-install/Build/Products/Release/Lumen.app
ditto build/local-install/Build/Products/Release/Lumen.app \
  /Applications/Lumen.app
open -na /Applications/Lumen.app
```

Stop an existing Lumen and worker process before replacing the bundle. Do not
launch an app directly from DerivedData, `build/`, or `/private/tmp` while
using the installed app.

### Check for duplicate applications

Only `/Applications/Lumen.app` should be returned by these checks:

```bash
mdfind 'kMDItemCFBundleIdentifier == "dev.skyline23.lumen.app"c' \
  | grep '/Lumen.app$'

LSREGISTER='/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister'
"$LSREGISTER" -dump \
  | awk -F': +' '/^path:/{path=$2} /^identifier: +dev\.skyline23\.lumen\.app$/{print path}'
```

Before deleting a duplicate, quit the process launched from that exact path and
run `lsregister -u <duplicate-path>`. Keep `/Applications/Lumen.app`; deleting
application data or resetting macOS privacy permissions is not required merely
to remove a duplicate build.

## Windows

Download `Lumen-<version>-Windows-x86_64.exe` from the project GitHub Release
and run it as an administrator. The installer installs the application and
service, creates the required firewall rule, and offers the virtual-gamepad
component. Lumen does not bundle a virtual-display driver. A compatible driver
must be installed independently before a Windows session can request a virtual
display.

Running a newer installer upgrades the existing installation; the installer
removes the previous version before installing the replacement. The uninstaller
stops and removes the service and firewall rule, and asks separately whether to
remove the virtual gamepad and Lumen data directory.

Verify the Authenticode signature from PowerShell before installation:

```powershell
$signature = Get-AuthenticodeSignature .\Lumen-<version>-Windows-x86_64.exe
$signature | Format-List Status, StatusMessage, SignerCertificate
if ($signature.Status -ne 'Valid') { throw 'Invalid Lumen installer signature' }
```

Unsigned installers produced by the regular CI workflow are development
artifacts. Public installations should use the signed installer attached to a
GitHub Release.
