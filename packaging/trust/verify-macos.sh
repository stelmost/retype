#!/usr/bin/env bash
# Installer verification uses built-in macOS tools, not an SDK or downloaded code.

# BEGIN RETYPE_MACOS_TRUST
_retype_verify_macos_code() (
	set -eu
	die() { printf 'retype trust: %s\n' "$*" >&2; exit 1; }
	[ "$#" -eq 5 ] || die 'expected app, CLI relative path, approved Team ID, app ID and CLI ID'
	local app=$1 cli_relative=$2 team=$3 app_id=$4 cli_id=$5 identifier component requirement details flags timestamp
	[[ $team =~ ^[A-Z0-9]{10}$ ]] || die 'missing or malformed approved Apple Team ID'
	for identifier in "$app_id" "$cli_id"; do
		[[ $identifier =~ ^[A-Za-z0-9][A-Za-z0-9.-]+$ ]] || die 'missing or malformed approved code identifier'
	done
	[ "$cli_relative" = 'Contents/Resources/retype' ] || die 'unsupported CLI location in app bundle'
	[ "$(uname -s)" = Darwin ] || die 'native macOS verification is required'
	[ -d "$app" ] && [ ! -L "$app" ] || die 'app must be a regular non-symlink directory'
	for component in "$app/Contents/MacOS/retype-notifier" "$app/$cli_relative"; do
		[ -f "$component" ] && [ ! -L "$component" ] || die 'app executable or CLI is missing or symlinked'
	done
	command -v codesign >/dev/null 2>&1 || die 'codesign is required'
	command -v plutil >/dev/null 2>&1 || die 'plutil is required'
	identifier=$(plutil -extract CFBundleIdentifier raw -o - "$app/Contents/Info.plist") ||
		die 'cannot read app bundle identifier'
	[ "$identifier" = "$app_id" ] || die 'app bundle identifier does not match approved identifier'
	identifier=$(plutil -extract CFBundleExecutable raw -o - "$app/Contents/Info.plist") ||
		die 'cannot read app executable name'
	[ "$identifier" = retype-notifier ] || die 'unsupported app executable'
	for component in "$app" "$app/$cli_relative"; do
		identifier=$app_id
		[ "$component" = "$app" ] || identifier=$cli_id
		requirement="anchor apple generic and certificate 1[field.1.2.840.113635.100.6.2.6] exists"
		requirement="$requirement and certificate leaf[field.1.2.840.113635.100.6.1.13] exists"
		requirement="$requirement and certificate leaf[subject.OU] = \"$team\" and identifier = \"$identifier\""
		codesign --verify --deep --strict -R "=$requirement" "$component" ||
			die 'Apple Developer ID code signature or approved identity rejected'
		details=$(codesign --display --verbose=4 "$component" 2>&1) || die 'cannot inspect code signature'
		flags=$(printf '%s\n' "$details" | awk '
			$1 == "CodeDirectory" { for (i = 2; i <= NF; i++) if ($i ~ /^flags=0x/) {
				sub(/^flags=/, "", $i); sub(/\(.*/, "", $i); print $i; exit
			} }
		') || die 'cannot inspect hardened runtime'
		[[ $flags =~ ^0x[0-9a-fA-F]+$ ]] && (( flags & 0x10000 )) || die 'hardened runtime is required'
		timestamp=$(printf '%s\n' "$details" | awk '/^Timestamp=/ { print substr($0, 11); exit }') ||
			die 'cannot inspect code-signing timestamp'
		case $timestamp in '' | none | None | unavailable | Unavailable)
			die 'secure code-signing timestamp is required' ;;
		esac
	done
)

retype_verify_macos() (
	set -eu
	_retype_verify_macos_code "$@" || exit 1
	local assessment
	# This native predicate is not satisfied by a local Gatekeeper allow rule.
	codesign --verify --strict --check-notarization -R '=notarized' "$1" || {
		printf 'retype trust: Apple notarisation predicate rejected the app\n' >&2; exit 1;
	}
	command -v spctl >/dev/null 2>&1 || { printf 'retype trust: spctl is required\n' >&2; exit 1; }
	assessment=$(spctl --assess --type execute --ignore-cache --no-cache --verbose=4 "$1" 2>&1) || {
		printf 'retype trust: Gatekeeper rejected the app\n' >&2; exit 1;
	}
	[[ $'\n'$assessment$'\n' == *$'\nsource=Notarized Developer ID\n'* ]] || {
		printf 'retype trust: notarised Developer ID assessment is required\n' >&2; exit 1;
	}
)
# END RETYPE_MACOS_TRUST

if [[ ${BASH_SOURCE[0]} == "$0" ]]; then
	retype_verify_macos "$@"
fi
