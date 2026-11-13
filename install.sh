#!/bin/bash
set -euo pipefail

release='https://github.com/Batuhan1999/headroom/releases/latest/download'
archive='Headroom-macOS-arm64.zip'
check_only=false
case "${1:-}" in
  '') ;;
  --check) check_only=true ;;
  *) echo 'Usage: bash install.sh [--check]' >&2; exit 2 ;;
esac
[[ $(uname -s) == Darwin ]] || { echo 'Headroom requires macOS.' >&2; exit 1; }
[[ $(uname -m) == arm64 ]] || { echo 'The prebuilt app requires Apple Silicon. See the README to build on Intel.' >&2; exit 1; }

IFS=. read -r system_major system_minor _ <<< "$(sw_vers -productVersion)"
(( system_major > 14 || (system_major == 14 && ${system_minor:-0} >= 2) )) || { echo 'Headroom requires macOS 14.2 or newer.' >&2; exit 1; }

temporary=$(mktemp -d "${TMPDIR:-/tmp}/headroom-install.XXXXXX")
trap 'rm -rf "$temporary"' EXIT
printf 'Downloading Headroom…\n'
curl --fail --silent --show-error --location --proto '=https' --tlsv1.2 "$release/$archive" -o "$temporary/$archive"
curl --fail --silent --show-error --location --proto '=https' --tlsv1.2 "$release/Headroom-SHA256SUMS.txt" -o "$temporary/checksums"
expected=$(awk '$2 == "Headroom-macOS-arm64.zip" { print $1 }' "$temporary/checksums")
actual=$(shasum -a 256 "$temporary/$archive" | awk '{ print $1 }')
[[ ${#expected} == 64 && "$actual" == "$expected" ]] || { echo 'Download checksum did not match.' >&2; exit 1; }
unzip -q "$temporary/$archive" -d "$temporary/unpacked"
bundle="$temporary/unpacked/Headroom.app"
identifier=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$bundle/Contents/Info.plist")
[[ "$identifier" == 'io.github.Batuhan1999.headroom' ]] || { echo 'Unexpected app bundle.' >&2; exit 1; }
codesign --verify --deep --strict "$bundle"
version=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$bundle/Contents/Info.plist")
if $check_only; then printf 'Verified Headroom %s. Nothing installed.\n' "$version"; exit 0; fi

if [[ -w /Applications ]]; then
  applications=/Applications
else
  applications="$HOME/Applications"
  mkdir -p "$applications"
fi
destination="$applications/Headroom.app"
if [[ -e "$destination" ]]; then
  existing=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$destination/Contents/Info.plist" 2>/dev/null || true)
  [[ "$existing" == "$identifier" ]] || { echo 'A different Headroom.app already exists. Install manually to another location.' >&2; exit 1; }
fi
stage=$(mktemp -d "$applications/.headroom-install.XXXXXX")
ditto "$bundle" "$stage/Headroom.app"
for process in $(pgrep -x Headroom || true); do
  executable=$(ps -p "$process" -o comm= || true)
  if [[ "$executable" == "$destination/Contents/MacOS/Headroom" ]]; then kill "$process"; fi
done
if [[ -e "$destination" ]]; then mv "$destination" "$stage/Previous.app"; fi
if ! mv "$stage/Headroom.app" "$destination"; then
  if [[ -e "$stage/Previous.app" ]]; then mv "$stage/Previous.app" "$destination"; fi
  echo 'Could not replace the app; the previous app was restored.' >&2
  exit 1
fi
rm -rf "$stage"
open "$destination"
printf 'Installed Headroom %s in %s\n' "$version" "$applications"
