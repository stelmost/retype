#!/usr/bin/env bash
# Embed the complete marked block in the independently trusted Unix installer.

# BEGIN RETYPE_RELEASE_TRUST
_retype_manifest_checksum() {
	[[ ${2:-} =~ ^[A-Za-z0-9][A-Za-z0-9._+-]*$ ]] || return 1
	LC_ALL=C awk -v wanted="$2" '
		{
			sub(/\r$/, "")
			digest = substr($0, 1, 64)
			asset = substr($0, 67)
			if (length(digest) != 64 || digest ~ /[^0-9a-f]/ || substr($0, 65, 1) != " " ||
				substr($0, 66, 1) !~ /[ *]/ || asset !~ /^[A-Za-z0-9][A-Za-z0-9._+-]*$/ ||
				seen[tolower(asset)]++) invalid = 1
			if (asset == wanted) expected = digest
		}
		END { if (invalid || expected == "") exit 1; print expected }
	' "$1"
}

retype_verify_release() (
	set -eu
	die() { printf 'retype trust: %s\n' "$*" >&2; exit 1; }
	[ "$#" -eq 4 ] || die 'expected archive, SHA256SUMS, signature and pinned public key'
	local archive=$1 checksums=$2 signature=$3 public_key=$4 size expected actual
	[[ $public_key =~ ^[A-Za-z0-9+/]{56}$ ]] || die 'missing or malformed pinned minisign public key'
	for file in "$archive" "$checksums" "$signature"; do
		[ -f "$file" ] && [ ! -L "$file" ] || die "not a regular non-symlink file: $file"
	done
	for file in "$checksums" "$signature"; do
		size=$(wc -c < "$file") || die "cannot size $file"
		[ "$size" -gt 0 ] && [ "$size" -le 1048576 ] || die "empty or oversized trust file: $file"
	done
	command -v minisign >/dev/null 2>&1 || die 'signed installation requires an independently trusted minisign'
	minisign -V -P "$public_key" -m "$checksums" -x "$signature" || die 'publisher manifest signature rejected'
	expected=$(_retype_manifest_checksum "$checksums" "${archive##*/}") ||
		die 'malformed, duplicate or missing archive entry in publisher manifest'
	if command -v sha256sum >/dev/null 2>&1; then
		actual=$(sha256sum -- "$archive") || die 'cannot hash archive'
	elif command -v shasum >/dev/null 2>&1; then
		actual=$(shasum -a 256 -- "$archive") || die 'cannot hash archive'
	else
		die 'signed installation requires sha256sum or shasum'
	fi
	[ "${actual%% *}" = "$expected" ] || die 'archive does not match publisher manifest'
)
# END RETYPE_RELEASE_TRUST

if [[ ${BASH_SOURCE[0]} == "$0" ]]; then
	retype_verify_release "$@"
fi
