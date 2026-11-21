#!/usr/bin/env bash
# Sign/notarise a fresh app copy with an existing approved identity and profile.
set -euo pipefail

die() { printf 'retype trust: %s\n' "$*" >&2; exit 1; }
[ "$#" -eq 8 ] || die 'expected unsigned app, CLI relative path, Team ID, app ID, CLI ID, identity, profile, fresh output'
input=$1
cli_relative=$2
team=$3
app_id=$4
cli_id=$5
identity=$6
profile=$7
output=$8
[ "$(uname -s)" = Darwin ] || die 'native macOS signing is required'
[[ $team =~ ^[A-Z0-9]{10}$ ]] || die 'missing or malformed approved Apple Team ID'
for identifier in "$app_id" "$cli_id"; do
	[[ $identifier =~ ^[A-Za-z0-9][A-Za-z0-9.-]+$ ]] || die 'missing or malformed approved code identifier'
done
[ -n "$identity" ] && [ "$identity" != '-' ] || die 'existing Developer ID Application identity is required'
[ -n "$profile" ] || die 'existing notarytool profile is required'
[ "$cli_relative" = 'Contents/Resources/retype' ] || die 'unsupported CLI location in app bundle'
[ -d "$input" ] && [ ! -L "$input" ] || die 'unsigned app must be a non-symlink directory'
for file in "$input/$cli_relative" "$input/Contents/MacOS/retype-notifier"; do
	[ -f "$file" ] && [ ! -L "$file" ] || die 'unsigned app executable or CLI is missing or symlinked'
done
case $output in /*) ;; *) die 'fresh output must be an absolute path' ;; esac
[ ! -e "$output" ] && [ ! -L "$output" ] || die 'refusing to replace an existing signing output'
for tool in codesign ditto xcrun plutil spctl; do
	command -v "$tool" >/dev/null 2>&1 || die "missing native signing tool: $tool"
done
root=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
source "$root/packaging/trust/verify-macos.sh"
umask 077
mkdir -- "$output" || die 'cannot create fresh private signing output'
app=$output/retype.app
cp -Rp -- "$input" "$app" || die 'cannot snapshot unsigned app; output retained'
# Re-signing is confined to this fresh copy; linker ad-hoc signatures are not publisher trust.
codesign --force --sign "$identity" --identifier "$cli_id" --options runtime --timestamp "$app/$cli_relative" ||
	die 'CLI signing failed; original and output retained'
codesign --force --sign "$identity" --options runtime --timestamp "$app" ||
	die 'app signing failed; original and output retained'
_retype_verify_macos_code "$app" "$cli_relative" "$team" "$app_id" "$cli_id" ||
	die 'signed code verification failed; original and output retained'
ditto -c -k --keepParent "$app" "$output/notary.zip" || die 'cannot create notarisation archive'
xcrun notarytool submit "$output/notary.zip" --keychain-profile "$profile" --wait --output-format json \
	> "$output/notary.json" || die 'notarisation failed; archive and response retained'
status=$(plutil -extract status raw -o - "$output/notary.json") || die 'cannot read notarisation response'
[ "$status" = Accepted ] || die 'notarisation was not accepted; archive and response retained'
xcrun stapler staple "$app" || die 'cannot staple notarisation ticket; output retained'
xcrun stapler validate "$app" || die 'stapled notarisation ticket rejected; output retained'
retype_verify_macos "$app" "$cli_relative" "$team" "$app_id" "$cli_id" ||
	die 'final native app verification failed; original and output retained'
printf 'Signed, stapled and verified app: %s\n' "$app"
printf 'Copy the signed Contents/Resources/retype to final bin/retype before archive assembly.\n'
