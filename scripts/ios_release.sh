#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

if [[ "$(uname -s)" != "Darwin" ]]; then
  echo "iOS release requires macOS."
  exit 2
fi

BUILD_NUMBER="${BUILD_NUMBER:-$("$ROOT_DIR/scripts/build_number.sh")}"
BUILD_DATE="${BUILD_DATE:-$(date +'%Y%m%d')}"
OUTPUT_DIR="${OUTPUT_DIR:-$HOME/Documents/AppsBuild/SwingCapture}"
ENVIRONMENT="${ENVIRONMENT:-production}"
UPLOAD_TO_TESTFLIGHT="${UPLOAD_TO_TESTFLIGHT:-1}"
SKIP_BUILD="${SKIP_BUILD:-0}"
IOS_EXPORT_OPTIONS_PLIST="${IOS_EXPORT_OPTIONS_PLIST:-ios/TestFlightExportOptions.plist}"
IOS_TEAM_ID="${IOS_TEAM_ID:-UXQMR4GU6P}"

TEMP_PATHS=()
cleanup() {
  for path in "${TEMP_PATHS[@]}"; do
    if [[ -e "$path" ]]; then
      rm -rf "$path"
    fi
  done
}
trap cleanup EXIT

if [[ -z "${BUILD_SUFFIX:-}" ]]; then
  mkdir -p "$OUTPUT_DIR"
  sequence=1
  while true; do
    printf -v seq "%02d" "$sequence"
    if [[ ! -e "$OUTPUT_DIR/SwingCapture-iOS-${BUILD_DATE}-${seq}.ipa" ]]; then
      BUILD_SUFFIX="${BUILD_DATE}-${seq}"
      break
    fi
    sequence=$((sequence + 1))
  done
fi

IPA_BASENAME="${IPA_BASENAME:-SwingCapture-iOS-${BUILD_SUFFIX}.ipa}"
STAGED_IPA="$OUTPUT_DIR/$IPA_BASENAME"

if [[ ! -f "$IOS_EXPORT_OPTIONS_PLIST" ]]; then
  echo "Missing iOS export options plist: $IOS_EXPORT_OPTIONS_PLIST"
  exit 2
fi

effective_export_options="$(mktemp "${TMPDIR:-/tmp}/swingcapture-export-options.XXXXXX.plist")"
TEMP_PATHS+=("$effective_export_options")
cp "$IOS_EXPORT_OPTIONS_PLIST" "$effective_export_options"
/usr/libexec/PlistBuddy -c "Set :teamID $IOS_TEAM_ID" "$effective_export_options" >/dev/null 2>&1 \
  || /usr/libexec/PlistBuddy -c "Add :teamID string $IOS_TEAM_ID" "$effective_export_options"

mkdir -p "$OUTPUT_DIR"
rm -rf build/ios/ipa

build_args=(
  --release
  "--dart-define=ENVIRONMENT=$ENVIRONMENT"
  "--build-number=$BUILD_NUMBER"
  "--export-options-plist=$effective_export_options"
)

if [[ -n "${BUILD_NAME:-}" ]]; then
  build_args+=("--build-name=$BUILD_NAME")
fi

echo "Building iOS IPA..."
echo "Build number: $BUILD_NUMBER"
echo "Environment: $ENVIRONMENT"
echo "Apple team: $IOS_TEAM_ID"
if [[ "$SKIP_BUILD" == "1" || "$SKIP_BUILD" == "true" ]]; then
  echo "Skipping IPA build because SKIP_BUILD=$SKIP_BUILD."
else
  flutter build ipa "${build_args[@]}"
fi

shopt -s nullglob
ipas=(build/ios/ipa/*.ipa)
shopt -u nullglob

if [[ ${#ipas[@]} -ne 1 ]]; then
  if [[ ("$SKIP_BUILD" == "1" || "$SKIP_BUILD" == "true") && -f "$STAGED_IPA" ]]; then
    echo "Using staged IPA: $STAGED_IPA"
  else
    echo "Expected one IPA under build/ios/ipa, found ${#ipas[@]}."
    exit 1
  fi
else
  cp "${ipas[0]}" "$STAGED_IPA"
  echo "IPA: $STAGED_IPA"
fi

if [[ "$UPLOAD_TO_TESTFLIGHT" == "0" || "$UPLOAD_TO_TESTFLIGHT" == "false" ]]; then
  echo "Skipping TestFlight upload because UPLOAD_TO_TESTFLIGHT=$UPLOAD_TO_TESTFLIGHT."
  exit 0
fi

ARCHIVE_PATH="${ARCHIVE_PATH:-build/ios/archive/Runner.xcarchive}"
if [[ ! -d "$ARCHIVE_PATH" ]]; then
  echo "Missing archive for TestFlight upload: $ARCHIVE_PATH"
  exit 1
fi

ASC_API_KEY_ID="${ASC_API_KEY_ID:-${APP_STORE_CONNECT_API_KEY_ID:-}}"
ASC_API_ISSUER_ID="${ASC_API_ISSUER_ID:-${APP_STORE_CONNECT_ISSUER_ID:-}}"
ASC_API_PRIVATE_KEY_PATH="${ASC_API_PRIVATE_KEY_PATH:-${APP_STORE_CONNECT_API_KEY_PATH:-}}"

auth_args=()
if [[ -n "$ASC_API_KEY_ID" || -n "$ASC_API_ISSUER_ID" || -n "$ASC_API_PRIVATE_KEY_PATH" ]]; then
  if [[ -z "$ASC_API_KEY_ID" || -z "$ASC_API_ISSUER_ID" || -z "$ASC_API_PRIVATE_KEY_PATH" ]]; then
    echo "Set ASC_API_KEY_ID, ASC_API_ISSUER_ID, and ASC_API_PRIVATE_KEY_PATH together for API-key upload."
    exit 2
  fi
  if [[ ! -f "$ASC_API_PRIVATE_KEY_PATH" ]]; then
    echo "App Store Connect API private key not found: $ASC_API_PRIVATE_KEY_PATH"
    exit 2
  fi
  auth_args=(
    -authenticationKeyPath "$ASC_API_PRIVATE_KEY_PATH"
    -authenticationKeyID "$ASC_API_KEY_ID"
    -authenticationKeyIssuerID "$ASC_API_ISSUER_ID"
  )
else
  echo "No App Store Connect API key env vars set; using the Xcode account configured on this Mac."
fi

upload_dir="$(mktemp -d "${TMPDIR:-/tmp}/swingcapture-testflight-upload.XXXXXX")"
upload_options="$(mktemp "${TMPDIR:-/tmp}/swingcapture-testflight-options.XXXXXX.plist")"
upload_log="$(mktemp "${TMPDIR:-/tmp}/swingcapture-testflight-upload.XXXXXX.log")"
TEMP_PATHS+=("$upload_dir" "$upload_options" "$upload_log")

cp "$effective_export_options" "$upload_options"
/usr/libexec/PlistBuddy -c "Set :destination upload" "$upload_options" >/dev/null 2>&1 \
  || /usr/libexec/PlistBuddy -c "Add :destination string upload" "$upload_options"

echo "Uploading iOS archive to TestFlight..."
xcodebuild_args=(
  -exportArchive \
  -archivePath "$ARCHIVE_PATH" \
  -exportPath "$upload_dir" \
  -exportOptionsPlist "$upload_options" \
  -allowProvisioningUpdates
)
if [[ ${#auth_args[@]} -gt 0 ]]; then
  xcodebuild_args+=("${auth_args[@]}")
fi
set +e
xcodebuild "${xcodebuild_args[@]}" 2>&1 | tee "$upload_log"
upload_status=${PIPESTATUS[0]}
set -e

if [[ $upload_status -ne 0 ]]; then
  log_bundle="$(sed -n 's/.*Created bundle at path "\(.*\.xcdistributionlogs\)".*/\1/p' "$upload_log" | tail -n 1)"
  if [[ -n "$log_bundle" && -d "$log_bundle" ]]; then
    missing_app="$(grep -R "missingApp(bundleId:" "$log_bundle" 2>/dev/null \
      | sed -E 's/.*missingApp\(bundleId: "([^"]+)".*/\1/' \
      | tail -n 1 || true)"
    if [[ -n "$missing_app" ]]; then
      echo "App Store Connect app record not found for bundle ID: $missing_app"
      echo "Create the App Store Connect app for this bundle ID, or update PRODUCT_BUNDLE_IDENTIFIER to the existing app bundle ID, then rerun make ios-build."
    fi
  fi
  exit "$upload_status"
fi

echo "TestFlight upload submitted."
