#!/usr/bin/env bash
# Build a fresh unsigned app; signing belongs to the release trust step.
set -euo pipefail

[ "$#" -eq 4 ] || { printf 'Usage: %s <CLI> <fresh-app-path> <bundle-version> <target>\n' "$0" >&2; exit 2; }
binary=$1
app=$2
version=$3
target=$4
root=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)

[ "$(uname -s)" = Darwin ] || { printf 'macOS bundle assembly needs the macOS SDK\n' >&2; exit 1; }
[ "$(id -u)" -ne 0 ] || { printf 'Refusing to build a user app as root\n' >&2; exit 1; }
[ -f "$binary" ] && [ -x "$binary" ] || { printf 'Missing executable CLI: %s\n' "$binary" >&2; exit 1; }
[ ! -e "$app" ] && [ ! -L "$app" ] || { printf 'Refusing to replace app: %s\n' "$app" >&2; exit 1; }
[[ $version =~ ^[0-9]+(\.[0-9]+){0,2}$ ]] || { printf 'Expected a numeric bundle version\n' >&2; exit 1; }
case $target in
aarch64-apple-darwin) arch=arm64 ;;
x86_64-apple-darwin) arch=x86_64 ;;
*) printf 'Unsupported macOS build target: %s\n' "$target" >&2; exit 1 ;;
esac

# Failed builds remain in the caller-owned output path for inspection.
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp -p "$binary" "$app/Contents/Resources/retype"
cp "$root/Info.plist" "$app/Contents/Info.plist"
plutil -replace CFBundleVersion -string "$version" "$app/Contents/Info.plist"
plutil -replace CFBundleShortVersionString -string "$version" "$app/Contents/Info.plist"
xcrun --sdk macosx swiftc -swift-version 5 -O -target "$arch-apple-macos15.0" \
	-framework AppKit -framework Carbon -framework CoreServices -framework UserNotifications \
	"$root/notifier.swift" -o "$app/Contents/MacOS/retype-notifier"
plutil -lint "$app/Contents/Info.plist"
printf 'Unsigned preview bundle assembled: %s\n' "$app"
