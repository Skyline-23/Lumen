#!/usr/bin/env bash
set -euo pipefail

MODE="${1:-run}"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONFIGURATION="${LUMEN_CONFIGURATION:-Debug}"
DERIVED_DATA_PATH="${LUMEN_DERIVED_DATA_PATH:-$HOME/Library/Developer/Xcode/DerivedData/Lumen-local-run}"
APP_BUNDLE="$DERIVED_DATA_PATH/Build/Products/$CONFIGURATION/Lumen.app"
APP_BINARY="$APP_BUNDLE/Contents/MacOS/Lumen"

case "$MODE" in
  run|--debug|--logs|--telemetry|--verify) ;;
  *) echo "usage: $0 [run|--debug|--logs|--telemetry|--verify]" >&2; exit 2 ;;
esac

# An orphaned worker can keep serving the previous codec after the GUI exits.
# Stop only processes belonging to the selected build output.
while read -r LUMEN_RUN_PID LUMEN_RUN_PATH; do
  case "$LUMEN_RUN_PATH" in
    "$APP_BINARY"|"$APP_BUNDLE/Contents/MacOS/LumenHostWorker"|"$APP_BUNDLE/Contents/MacOS/LumenRustHostWorker")
      kill -TERM "$LUMEN_RUN_PID" 2>/dev/null || true
      ;;
  esac
done < <(ps -axo pid=,comm=)

for _ in {1..40}; do
  LUMEN_RUN_ACTIVE=false
  while read -r LUMEN_RUN_PID LUMEN_RUN_PATH; do
    case "$LUMEN_RUN_PATH" in
      "$APP_BINARY"|"$APP_BUNDLE/Contents/MacOS/LumenHostWorker"|"$APP_BUNDLE/Contents/MacOS/LumenRustHostWorker")
        LUMEN_RUN_ACTIVE=true
        ;;
    esac
  done < <(ps -axo pid=,comm=)
  if [[ "$LUMEN_RUN_ACTIVE" == false ]]; then break; fi
  sleep 0.25
done
if [[ "$LUMEN_RUN_ACTIVE" == true ]]; then
  # The worker can be parked in an unfinished codec ACK during shutdown.
  # After its graceful deadline, retire only these owned build processes.
  while read -r LUMEN_RUN_PID LUMEN_RUN_PATH; do
    case "$LUMEN_RUN_PATH" in
      "$APP_BINARY"|"$APP_BUNDLE/Contents/MacOS/LumenHostWorker"|"$APP_BUNDLE/Contents/MacOS/LumenRustHostWorker")
        echo "Retiring unresponsive previous build process: $LUMEN_RUN_PID" >&2
        kill -KILL "$LUMEN_RUN_PID" 2>/dev/null || true
        ;;
    esac
  done < <(ps -axo pid=,comm=)
  sleep 0.25
  while read -r LUMEN_RUN_PID LUMEN_RUN_PATH; do
    case "$LUMEN_RUN_PATH" in
      "$APP_BINARY"|"$APP_BUNDLE/Contents/MacOS/LumenHostWorker"|"$APP_BUNDLE/Contents/MacOS/LumenRustHostWorker")
        echo "A previous Lumen process is still serving this build output" >&2
        exit 1
        ;;
    esac
  done < <(ps -axo pid=,comm=)
fi

(
  cd "$ROOT_DIR/src/platform/macos"
  tuist generate --no-open
  tuist xcodebuild build \
    -workspace Lumen.xcworkspace \
    -scheme LumenApp \
    -destination 'generic/platform=macOS' \
    -configuration "$CONFIGURATION" \
    -derivedDataPath "$DERIVED_DATA_PATH"
)

if [[ ! -x "$APP_BINARY" ]]; then
  echo "Built Lumen executable is missing: $APP_BINARY" >&2
  exit 1
fi

case "$MODE" in
  run)
    /usr/bin/open -n "$APP_BUNDLE"
    ;;
  --debug)
    lldb -- "$APP_BINARY"
    ;;
  --logs)
    /usr/bin/open -n "$APP_BUNDLE"
    /usr/bin/log stream --info --style compact --predicate 'process == "Lumen" OR process == "LumenHostWorker"'
    ;;
  --telemetry)
    /usr/bin/open -n "$APP_BUNDLE"
    /usr/bin/log stream --info --style compact --predicate 'subsystem BEGINSWITH "dev.skyline23.lumen"'
    ;;
  --verify)
    /usr/bin/open -n "$APP_BUNDLE"
    for _ in {1..40}; do
      if pgrep -f -x "$APP_BINARY" >/dev/null; then
        echo "Started the freshly built Lumen app: $APP_BUNDLE"
        exit 0
      fi
      sleep 0.25
    done
    echo "Lumen did not start from the requested build output" >&2
    exit 1
    ;;
esac
