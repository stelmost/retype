#!/usr/bin/env bash
# Sign only a final manifest; never overwrite an asset or copy a private key.
set -euo pipefail

die() { printf 'retype trust: %s\n' "$*" >&2; exit 1; }
[ "$#" -eq 3 ] || die 'expected final release directory, existing signing-key path and approved public key'
directory=$1
key=$2
public_key=$3
[[ $public_key =~ ^[A-Za-z0-9+/]{56}$ ]] || die 'missing or malformed approved minisign public key'
[ "$(uname -s)" = Linux ] || die 'manifest signing uses the Linux release assembly toolchain'
[ -d "$directory" ] && [ ! -L "$directory" ] || die 'release directory must be a non-symlink directory'
[ -f "$key" ] && [ ! -L "$key" ] || die 'approved existing signing-key file is required'
checksums=$directory/SHA256SUMS
signature=$directory/SHA256SUMS.minisig
[ -f "$checksums" ] && [ ! -L "$checksums" ] || die 'final SHA256SUMS is required'
[ ! -e "$signature" ] && [ ! -L "$signature" ] || die 'refusing to replace an existing manifest signature'
for tool in minisign sha256sum cmp mktemp cp ln; do
	command -v "$tool" >/dev/null 2>&1 || die "missing signing tool: $tool"
done
size=$(wc -c < "$checksums") || die 'cannot size final manifest'
[ "$size" -gt 0 ] && [ "$size" -le 1048576 ] || die 'empty or oversized final manifest'
root=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
source "$root/packaging/trust/verify.sh"

check_asset() {
	local asset=$1 expected actual
	expected=$(_retype_manifest_checksum "$checksums" "$asset") || die 'malformed or incomplete final manifest'
	[ -f "$directory/$asset" ] && [ ! -L "$directory/$asset" ] || die "missing regular release asset: $asset"
	actual=$(sha256sum -- "$directory/$asset") || die "cannot hash release asset: $asset"
	[ "${actual%% *}" = "$expected" ] || die "final manifest does not match release asset: $asset"
}
for file in "$directory"/*.tar.gz "$directory/install.sh" "$directory/install.ps1"; do
	check_asset "${file##*/}"
done
while IFS= read -r line || [ -n "$line" ]; do
	asset=${line:66}
	check_asset "${asset%$'\r'}"
done < "$checksums"

umask 077
staging=$(mktemp -d "$directory/.sign-release.XXXXXX") || die 'cannot create private signing staging'
printf 'Signing staging retained: %s\n' "$staging"
cp -- "$checksums" "$staging/SHA256SUMS" || die 'cannot snapshot final manifest'
minisign -S -s "$key" -m "$staging/SHA256SUMS" -x "$staging/SHA256SUMS.minisig" ||
	die 'manifest signing failed; original assets and staging retained'
cmp -s -- "$checksums" "$staging/SHA256SUMS" || die 'final manifest changed during signing'
while IFS= read -r line || [ -n "$line" ]; do
	asset=${line:66}
	retype_verify_release "$directory/${asset%$'\r'}" "$checksums" "$staging/SHA256SUMS.minisig" "$public_key" ||
		die 'signed manifest or final asset verification failed; candidate retained'
done < "$checksums"
# GNU ln -T refuses any occupied destination, including a symlink to a directory.
ln -T -- "$staging/SHA256SUMS.minisig" "$signature" || die 'refusing to replace manifest signature'
printf 'Publisher manifest signature verified: %s\n' "$signature"
