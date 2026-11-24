#!/usr/bin/env bash
# Assemble checksums and, where applicable, installers in a private release directory.
set -euo pipefail

embed_options=()
archives_only=false
case ${1:-} in
--signed)
	embed_options=(--signed)
	shift
	;;
--archives-only)
	archives_only=true
	shift
	;;
esac
if [ "$#" -ne 1 ]; then
	printf 'Usage: %s [--signed | --archives-only] <release-directory>\n' "$0" >&2
	exit 2
fi

root=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
cd -- "$1"

for archive in *.tar.gz; do
	if [ ! -f "$archive" ] || [ ! -f "$archive.sha256" ]; then
		printf 'Missing release archive or checksum: %s\n' "$archive" >&2
		exit 1
	fi
	if ! sha256sum -- "$archive" | cmp -s -- "$archive.sha256" - &&
		! sha256sum --binary -- "$archive" | cmp -s -- "$archive.sha256" -; then
		printf 'Build checksum does not match archive: %s\n' "$archive" >&2
		exit 1
	fi
	printf '%s: OK\n' "$archive"
done

for file in install.sh install.ps1 install.sh.sha256 install.ps1.sha256 SHA256SUMS SHA256SUMS.minisig; do
	if [ -e "$file" ] || [ -L "$file" ]; then
		printf 'Refusing to overwrite release asset: %s\n' "$file" >&2
		exit 1
	fi
done

assets=(*.tar.gz)
if ! $archives_only; then
	python3 "$root/scripts/embed-trust.py" "${embed_options[@]}" "$root/packaging/install.sh" install.sh
	python3 "$root/scripts/embed-trust.py" "${embed_options[@]}" "$root/packaging/install.ps1" install.ps1
	sha256sum -- install.sh > install.sh.sha256
	sha256sum -- install.ps1 > install.ps1.sha256
	assets+=(install.sh install.ps1)
fi
sha256sum -- "${assets[@]}" > SHA256SUMS
sha256sum --check SHA256SUMS
