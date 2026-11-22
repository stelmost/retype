#!/usr/bin/env bash
# Install or update retype from a GitHub release.
#
# Signed installs authenticate the publisher manifest before extraction or code.
# Explicit preview mode retains checksum verification but supplies no publisher trust.
set -euo pipefail

# Filled from the independently approved publisher inputs, never from a download.
retype_minisign_public_key=''
retype_macos_team_id=''

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

repo=${RETYPE_REPO:-LapilliWorks/retype}
version=${RETYPE_VERSION:-latest}
prefix=${RETYPE_PREFIX:-${HOME:?HOME is not set}/.local}
target=${RETYPE_TARGET:-}
release_base=${RETYPE_RELEASE_BASE:-https://github.com/$repo/releases/download}
install_mode=${RETYPE_INSTALL_MODE:-signed}
uninstall=false
enable_startup=false

usage() {
	cat <<'EOF'
Install or update retype from a GitHub release.

Usage:
  bash ./install.sh
  bash ./install.sh --version '<supported-release-tag>'
  bash ./install.sh --prefix "$HOME/.local"

Options:
  --version TAG   Install a specific release tag instead of the latest
  --prefix DIR    Install under DIR (default: $HOME/.local)
  --uninstall     Remove this installation, preserving configuration and recovery data
  --preview       Explicit unsigned preview, outside installed-tier qualification
  --enable-startup  Opt in to native per-user startup on macOS
  -h, --help      Show this help

Environment:
  RETYPE_VERSION       Same as --version
  RETYPE_PREFIX        Same as --prefix
  RETYPE_REPO          GitHub repository (default: LapilliWorks/retype)
  RETYPE_RELEASE_BASE  Release download base, for a mirror
  RETYPE_TARGET        Override platform detection, such as x86_64-unknown-linux-gnu
  RETYPE_INSTALL_MODE  signed (default) or explicit preview

Signed installs need an independently trusted minisign and fixed publisher pins.
On Linux, installs the notification/URI desktop entry and systemd user unit;
new services stay disabled. Requires Python 3.12 or newer and xdg-mime (xdg-utils).
On macOS, installs the native app/URI identity; startup stays off unless opted in.
No SDK, compiler, elevation, keychain changes or converter installation is performed.
EOF
}

die() {
	printf 'install: %s\n' "$*" >&2
	exit 1
}

have() {
	command -v "$1" >/dev/null 2>&1
}

download() {
	if have curl; then
		curl -fsSL --retry 3 "$1"
	elif have wget; then
		wget -qO- "$1"
	else
		die 'needs curl or wget'
	fi
}

download_file() {
	if have curl; then
		curl -fsSL --retry 3 -o "$2" "$1"
	elif have wget; then
		wget -qO "$2" "$1"
	else
		die 'needs curl or wget'
	fi
}

sha256_of() {
	if have sha256sum; then
		sha256sum "$1" | awk '{ print $1; exit }'
	elif have shasum; then
		shasum -a 256 "$1" | awk '{ print $1; exit }'
	elif have openssl; then
		openssl dgst -sha256 -r "$1" | awk '{ print $1; exit }'
	else
		die 'needs sha256sum, shasum or openssl'
	fi
}

# BEGIN RETYPE_MACOS_EXTRACTION
extract_macos() {
	local archive=$1 destination=$2 root=$3 version
	[ -x /usr/bin/perl ] || die 'macOS archive validation needs the built-in Perl runtime'
	version=$(/usr/bin/tar --version) || die 'cannot identify the native archive tool'
	case $version in *bsdtar*) ;; *) die 'macOS extraction requires native libarchive/bsdtar' ;; esac
	[ ! -e "$destination" ] && [ ! -L "$destination" ] || die 'archive staging must be fresh'
	mkdir -m 0700 "$destination"
	/usr/bin/tar -tzf "$archive" >"$destination.entries" || die 'cannot enumerate release archive'
	/usr/bin/perl -e '
		use strict; use warnings;
		my $root = shift @ARGV; my %seen; my $found = 0;
		while (<>) {
			chomp; s{/$}{};
			die "unsupported archive path\n" unless /^[A-Za-z0-9_.+\/-]+$/;
			my @parts = split m{/};
			die "unexpected archive root\n" unless $parts[0] eq $root;
			die "unsupported archive component\n" if grep { $_ eq q{} || $_ eq q{.} || $_ eq q{..} } @parts;
			die "duplicate or case-colliding archive member\n" if $seen{lc $_}++;
			$found = 1 if $_ eq $root;
		}
		die "missing archive root\n" unless $found;
	' "$root" "$destination.entries" || die 'unsupported release archive hierarchy'
	/usr/bin/tar -tvzf "$archive" >"$destination.types" || die 'cannot enumerate archive entry types'
	/usr/bin/perl -ne '
		die "unsupported archive entry type\n" unless /^[-d]/;
		die "archive links are unsupported\n" if / -> | link to /;
	' "$destination.types" || die 'release archive contains links or special entries'
	# Keep bsdtar secure-symlink/no-dotdot defaults enabled: never use -P or --insecure.
	# Safe writes and empty private staging avoid existing-inode replacement; xattrs are not stripped.
	/usr/bin/tar --safe-writes --no-same-owner --no-same-permissions -xzf "$archive" -C "$destination" ||
		die 'native secure archive extraction failed'
	/usr/bin/perl -MFile::Find -e '
		use strict; use warnings;
		my ($staging, $root) = @ARGV; my %seen;
		find({ no_chdir => 1, wanted => sub {
			my $path = $File::Find::name; return if $path eq $staging;
			my $name = substr($path, length($staging) + 1);
			my @parts = split m{/}, $name;
			die "unexpected extracted root\n" unless $parts[0] eq $root;
			die "unsupported extracted path\n" unless $name =~ /^[A-Za-z0-9_.+\/-]+$/;
			die "case-colliding extracted path\n" if $seen{lc $name}++;
			my @info = lstat($path); die "cannot inspect extracted entry\n" unless @info;
			die "unowned or unsafe extracted entry\n" if $info[4] != $< || ($info[2] & 07022);
			die "extracted link or special entry\n" unless -d _ || (-f _ && $info[3] == 1);
		}}, $staging);
	' "$destination" "$root" || die 'extracted archive failed type/ownership/permission validation'
}
# END RETYPE_MACOS_EXTRACTION

extract_linux() {
	python3 - "$1" "$2" "$3" <<'PYTHON'
import re
import sys
import tarfile

archive, destination, root = sys.argv[1:]
try:
	with tarfile.open(archive, 'r:gz') as source:
		members = {}
		for entry in source:
			parts = entry.name.split('/')
			if (parts[0] != root or not re.fullmatch(r'[A-Za-z0-9_.+/-]+', entry.name)
					or any(part in ('', '.', '..') for part in parts)):
				raise ValueError(f'unsupported archive path: {entry.name!r}')
			if not (entry.isdir() or (entry.isfile() and not entry.issparse())):
				raise ValueError(f'links and special archive entries are unsupported: {entry.name!r}')
			key = entry.name.lower()
			if key in members:
				raise ValueError(f'duplicate or case-colliding archive member: {entry.name!r}')
			members[key] = entry
		if root.lower() not in members or not members[root.lower()].isdir():
			raise ValueError('missing archive root directory')
		for entry in members.values():
			parent = entry.name.rpartition('/')[0]
			if parent and (parent.lower() not in members or not members[parent.lower()].isdir()
					or members[parent.lower()].name != parent):
				raise ValueError(f'archive parent is not a declared directory: {entry.name!r}')
		source.extractall(destination, members=members.values(), filter='data')
except (OSError, tarfile.TarError, ValueError) as error:
	raise SystemExit(f'install: unsafe or invalid Linux release archive: {error}') from error
PYTHON
}

# Current Debian stable (trixie) defines the Linux floor. Report an older runtime
# before attempting to execute the downloaded binary.
check_glibc() {
	local reported
	reported=$(getconf GNU_LIBC_VERSION 2>/dev/null || true)
	[ -n "$reported" ] || die 'retype targets current Debian stable and needs glibc 2.41 or newer; this system does not report glibc'
	reported=${reported#glibc }
	if [ "$(printf '%s\n' 2.41 "$reported" | sort -V | head -n1)" != 2.41 ]; then
		die "retype targets current Debian stable and needs glibc 2.41 or newer; this system has $reported"
	fi
}

while [ $# -gt 0 ]; do
	case $1 in
	--version)
		[ $# -ge 2 ] || die '--version needs a tag'
		version=$2
		shift 2
		;;
	--version=*)
		version=${1#*=}
		shift
		;;
	--prefix)
		[ $# -ge 2 ] || die '--prefix needs a directory'
		prefix=$2
		shift 2
		;;
	--prefix=*)
		prefix=${1#*=}
		shift
		;;
	--uninstall)
		uninstall=true
		shift
		;;
	--preview)
		install_mode=preview
		shift
		;;
	--enable-startup)
		enable_startup=true
		shift
		;;
	-h | --help)
		usage
		exit 0
		;;
	*)
		die "unknown option: $1"
		;;
	esac
done

[ -n "$prefix" ] || die 'the install prefix is empty'
case $prefix in
/*) ;;
*) prefix=$PWD/$prefix ;;
esac

if [ -z "$target" ]; then
	case $(uname -s) in
	Linux) os=unknown-linux-gnu ;;
	Darwin) os=apple-darwin ;;
	MINGW* | MSYS* | CYGWIN*)
		die "Windows uses the PowerShell installer: https://retype.name/install.ps1"
		;;
	*) die "unsupported operating system: $(uname -s)" ;;
	esac
	case $(uname -m) in
	x86_64 | amd64) arch=x86_64 ;;
	arm64 | aarch64) arch=aarch64 ;;
	*) die "unsupported architecture: $(uname -m)" ;;
	esac
	target=$arch-$os
fi

case $install_mode in signed | preview) ;; *) die 'RETYPE_INSTALL_MODE must be signed or preview' ;; esac
if $enable_startup; then
	$uninstall && die '--enable-startup cannot be combined with --uninstall'
	case $target in *-apple-darwin) ;; *) die '--enable-startup is a macOS option' ;; esac
fi

bin_dir=$prefix/bin
share_dir=$prefix/share/retype
integration_helper=
integration_runtime=python3
integration_asset=packaging/linux/integrate.py
integration_extension=py
integration_options=()
case $target in
*-apple-darwin)
	[ "$(uname -s)" = Darwin ] || die 'macOS installation needs a native macOS host'
	[ "$(id -u)" -ne 0 ] || die 'refusing a per-user macOS installation as root'
	macos_version=$(sw_vers -productVersion) || die 'cannot identify the macOS runtime'
	macos_major=${macos_version%%.*}
	[[ $macos_major =~ ^[0-9]+$ ]] && [ "$macos_major" -ge 15 ] || die 'macOS installation needs macOS 15 or newer'
	case $prefix:$HOME in *$'\n'* | *$'\r'* | *$'\t'*) die 'macOS paths must not contain control characters' ;; esac
	case /${prefix#/}/ in *'/../'* | *'/./'* | '//') die 'unsupported macOS installation prefix' ;; esac
	for path in "$prefix" "$bin_dir" "$prefix/share" "$share_dir"; do
		[ ! -L "$path" ] || die "refusing a symlinked macOS installation path: $path"
	done
	integration_runtime=bash
	integration_asset=packaging/macos/integrate.sh
	integration_extension=sh
	if $enable_startup; then integration_options=(--enable-startup); fi
	;;
esac

if ! $uninstall; then
	if [ "$install_mode" = signed ]; then
		[[ $retype_minisign_public_key =~ ^[A-Za-z0-9+/]{56}$ ]] || die 'signed installer has no approved publisher key'
		have retype_verify_release || die 'signed installer lacks its embedded trusted verifier'
		have minisign || die 'signed installation needs an independently trusted minisign'
		case $target in *-apple-darwin)
			[[ $retype_macos_team_id =~ ^[A-Z0-9]{10}$ ]] || die 'signed installer has no approved Apple Team ID'
			;;
		esac
	else
		printf 'install: UNSIGNED PREVIEW; publisher trust is not verified, not installed-tier qualification\n' >&2
	fi
fi

if $uninstall; then
	case $target in
	*-unknown-linux-gnu)
		have python3 || die 'Linux installation removal needs python3'
		[ -f "$share_dir/packaging/linux/integrate.py" ] || die 'this installation has no Linux integration helper'
		;;
	*-apple-darwin)
		[ -f "$share_dir/$integration_asset" ] || die 'this installation has no macOS integration helper'
		;;
	*) die '--uninstall supports Linux and macOS only' ;;
	esac
else
	case $target in
	*-unknown-linux-gnu)
		check_glibc
		have python3 || die 'Linux desktop integration needs python3'
		;;
	esac
fi

case $version in
latest)
	if $uninstall; then
		tag=uninstall
	else
		api=https://api.github.com/repos/$repo/releases?per_page=100
		release=$(download "$api") || die "could not read published releases from $api"
		tag_pattern='"tag_name"[[:space:]]*:[[:space:]]*"([^"]+)"'
		[[ $release =~ $tag_pattern ]] || die "could not find a tag in the published release response from $api"
		tag=${BASH_REMATCH[1]}
	fi
	;;
v*) tag=$version ;;
*) tag=v$version ;;
esac
[[ $tag =~ ^[A-Za-z0-9][A-Za-z0-9._+-]*$ ]] || die 'invalid release tag'
[[ $target =~ ^(x86_64|aarch64)-(unknown-linux-gnu|apple-darwin)$ ]] || die 'unsupported release target'

release_base=${release_base%/}
base=$release_base/$tag
name=retype-$tag-$target
archive=$name.tar.gz

tmp=$(mktemp -d "${TMPDIR:-/tmp}/retype-install.XXXXXX")
staged_bin=
staged_share=
backup=
changed_bin=false
changed_share=false
had_share=false

restore_installation() {
	if $changed_bin; then
		if [ -e "$backup/retype" ] || [ -L "$backup/retype" ]; then
			cp -pP "$backup/retype" "$staged_bin" || return 1
			mv -f "$staged_bin" "$bin_dir/retype" || return 1
		else
			rm -f "$bin_dir/retype" || return 1
		fi
	fi
	if $changed_share; then
		if [ -e "$backup/share" ] || [ -L "$backup/share" ]; then
			rm -rf "$share_dir" || return 1
			mv "$backup/share" "$share_dir" || return 1
		elif ! $had_share; then
			rm -rf "$share_dir" || return 1
		fi
	fi
}

cleanup() {
	local status=$?
	trap - EXIT
	if [ "$status" -ne 0 ] && [ -n "$backup" ]; then
		local can_restore=true
		case $target in *-apple-darwin)
			if [ -n "$integration_helper" ] && ! bash "$integration_helper" abort --prefix "$prefix" --backup "$backup"; then
				can_restore=false
			fi
			;;
		esac
		if $can_restore && restore_installation && { [ -z "$integration_helper" ] ||
			"$integration_runtime" "$integration_helper" rollback --prefix "$prefix" --backup "$backup"; }; then
			printf 'install: previous installation preserved; backup: %s\n' "$backup" >&2
		else
			printf 'install: rollback failed; recover the previous installation from %s\n' "$backup" >&2
		fi
	fi
	[ -z "$staged_bin" ] || rm -f "$staged_bin"
	[ -z "$staged_share" ] || rm -rf "$staged_share"
	rm -rf "$tmp"
	exit "$status"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

if $uninstall; then
	backup=$(mktemp -d "$prefix/share/retype-backup.XXXXXX")
	integration_helper=$backup/integrate.$integration_extension
	cp "$share_dir/$integration_asset" "$integration_helper"
	if [ -e "$bin_dir/retype" ] || [ -L "$bin_dir/retype" ]; then
		staged_bin=$(mktemp "$bin_dir/.retype.XXXXXX")
		cp -pP "$bin_dir/retype" "$backup/retype"
	fi
	case $target in *-apple-darwin)
		bash "$integration_helper" prepare --prefix "$prefix" --backup "$backup" --source "$share_dir"
		;;
	esac
	"$integration_runtime" "$integration_helper" remove --prefix "$prefix" --backup "$backup"
	changed_bin=true
	rm -f "$bin_dir/retype"
	had_share=true
	changed_share=true
	mv "$share_dir" "$backup/share"
	printf 'retype removed; configuration and recovery data preserved. Backup: %s\n' "$backup"
	exit 0
fi

if [ "$install_mode" = signed ]; then
	download_file "$base/SHA256SUMS" "$tmp/SHA256SUMS" || die 'could not download publisher manifest'
	download_file "$base/SHA256SUMS.minisig" "$tmp/SHA256SUMS.minisig" || die 'could not download publisher signature'
	download_file "$base/$archive" "$tmp/$archive" || die "could not download $base/$archive"
	retype_verify_release "$tmp/$archive" "$tmp/SHA256SUMS" "$tmp/SHA256SUMS.minisig" "$retype_minisign_public_key" ||
		die 'publisher manifest or archive rejected; installation unchanged'
else
	sums=$(download "$base/SHA256SUMS") || die "could not download checksums: $base/SHA256SUMS"
	expected=$(printf '%s\n' "$sums" | awk -v name="$archive" '$2 == name || $2 == "*" name { print $1; exit }')
	[ -n "$expected" ] || die "release $tag has no checksum for $archive"
	download_file "$base/$archive" "$tmp/$archive" || die "could not download $base/$archive"
	actual=$(sha256_of "$tmp/$archive")
	[ "$actual" = "$expected" ] || die "checksum mismatch for $archive: expected $expected, got $actual"
fi

case $target in
*-apple-darwin)
	extract_macos "$tmp/$archive" "$tmp/unpack" "$name"
	src=$tmp/unpack/$name
	[ "$install_mode" != signed ] || retype_verify_macos "$src/share/retype/macos/retype.app" \
		Contents/Resources/retype "$retype_macos_team_id" com.lapilliworks.retype.cli com.lapilliworks.retype.cli
	cmp -s "$src/bin/retype" "$src/share/retype/macos/retype.app/Contents/Resources/retype" ||
		die 'macOS archive CLI differs from the bundled CLI'
	;;
*-unknown-linux-gnu)
	extract_linux "$tmp/$archive" "$tmp/unpack" "$name"
	src=$tmp/unpack/$name
	;;
esac
[ -f "$src/bin/retype" ] || die "$archive does not contain bin/retype"

mkdir -p "$bin_dir" "$prefix/share"
[ -w "$bin_dir" ] || die "cannot write to $bin_dir; set RETYPE_PREFIX or fix the permissions"

staged_bin=$(mktemp "$bin_dir/.retype.XXXXXX")
cp "$src/bin/retype" "$staged_bin"
chmod 0755 "$staged_bin"
staged_share=$(mktemp -d "$prefix/share/.retype.XXXXXX")
if [ -d "$src/share/retype" ]; then
	cp -R "$src/share/retype/." "$staged_share/"
fi
case $target in *-apple-darwin)
	[ "$install_mode" != signed ] || retype_verify_macos "$staged_share/macos/retype.app" \
		Contents/Resources/retype "$retype_macos_team_id" com.lapilliworks.retype.cli com.lapilliworks.retype.cli
	;;
esac
output=$("$staged_bin" --version 2>&1) || die "the staged binary does not run; installation unchanged: $output"
case $target in
*-unknown-linux-gnu)
	[ -f "$staged_share/packaging/linux/integrate.py" ] || die 'the release lacks Linux desktop integration assets'
	python3 "$staged_share/packaging/linux/integrate.py" check --prefix "$prefix"
	;;
*-apple-darwin)
	[ -f "$staged_share/$integration_asset" ] || die 'release lacks macOS integration assets'
	bash "$staged_share/$integration_asset" check --prefix "$prefix" --source "$staged_share" \
		${integration_options[@]+"${integration_options[@]}"}
	;;
esac

# Keep the previous installation on the destination filesystem, including after success.
backup=$(mktemp -d "$prefix/share/retype-backup.XXXXXX")
case $target in
*-unknown-linux-gnu)
	integration_helper=$backup/integrate.py
	cp "$staged_share/packaging/linux/integrate.py" "$integration_helper"
	;;
*-apple-darwin)
	integration_helper=$backup/integrate.sh
	cp "$staged_share/$integration_asset" "$integration_helper"
	if [ -e "$bin_dir/retype" ] || [ -L "$bin_dir/retype" ]; then
		cp -pP "$bin_dir/retype" "$backup/retype"
	fi
	bash "$integration_helper" prepare --prefix "$prefix" --backup "$backup" --source "$staged_share" \
		${integration_options[@]+"${integration_options[@]}"}
	;;
esac
if [ -e "$bin_dir/retype" ] || [ -L "$bin_dir/retype" ]; then
	cp -pP "$bin_dir/retype" "$backup/retype"
fi
if [ -e "$share_dir" ] || [ -L "$share_dir" ]; then
	had_share=true
	changed_share=true
	mv "$share_dir" "$backup/share"
fi
changed_share=true
mv "$staged_share" "$share_dir"
changed_bin=true
mv -f "$staged_bin" "$bin_dir/retype"
output=$("$bin_dir/retype" --version 2>&1) || die "the installed binary does not run: $output"
if [ -n "$integration_helper" ]; then
	"$integration_runtime" "$integration_helper" install --prefix "$prefix" --backup "$backup" \
		${integration_options[@]+"${integration_options[@]}"}
fi

printf 'retype installed at %s\n' "$bin_dir/retype"
printf '  %s\n' "$output"
printf 'Previous installation backup: %s\n' "$backup"
case ":$PATH:" in
*":$bin_dir:"*) ;;
*) printf '\nAdd it to PATH:\n  export PATH="%s:$PATH"\n' "$bin_dir" ;;
esac
printf '\nNext: retype doctor\n'
