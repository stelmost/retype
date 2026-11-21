#!/usr/bin/env bash
# Per-user macOS integration. The caller verifies the archive/app before invoking this helper.
set -euo pipefail

operation=${1:?needs an operation}
shift
prefix=
backup=
source=
enable_startup=false
while [ "$#" -gt 0 ]; do
	case $1 in
	--prefix) prefix=${2:?needs a prefix}; shift 2 ;;
	--backup) backup=${2:?needs a backup}; shift 2 ;;
	--source) source=${2:?needs staged assets}; shift 2 ;;
	--enable-startup) enable_startup=true; shift ;;
	*) printf 'macOS integration: unknown option: %s\n' "$1" >&2; exit 2 ;;
	esac
done

fail() { printf 'macOS integration: %s\n' "$*" >&2; exit 1; }
exists() { [ -e "$1" ] || [ -L "$1" ]; }
read_value() {
	[ -f "$1" ] && [ ! -L "$1" ] || fail "invalid installation record: $1"
	local value
	IFS= read -r value <"$1"
	printf '%s' "$value"
}
hash() {
	if command -v sha256sum >/dev/null 2>&1; then
		sha256sum "$1" | awk '{ print $1; exit }'
	else
		shasum -a 256 "$1" | awk '{ print $1; exit }'
	fi
}
xml_escape() {
	local value=$1
	value=${value//&/\&amp;}
	value=${value//</\&lt;}
	value=${value//>/\&gt;}
	value=${value//\"/\&quot;}
	value=${value//\'/\&apos;}
	printf '%s' "$value"
}

[ -n "$prefix" ] || fail 'needs --prefix'
share=$prefix/share/retype
app=$share/macos/retype.app
notifier=$app/Contents/MacOS/retype-notifier
receipt=$share/macos-installation
link=${HOME:?HOME is not set}/Applications/retype.app
agent=$HOME/Library/LaunchAgents/com.lapilliworks.retype.cli.plist
label=com.lapilliworks.retype.cli
uid=$(id -u)
domain=gui/$uid
job=$domain/$label
unregister=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
journal=${backup:+$backup/macos-integration}
source=${source:-$share}
probe=$source/macos/retype.app/Contents/MacOS/retype-notifier

job_state() {
	loaded=false
	pid=
	local output program
	if output=$(launchctl print "$job" 2>/dev/null); then
		loaded=true
		program=$(printf '%s\n' "$output" | awk -F ' = ' '$1 ~ /^[ \t]*program$/ { print $2; exit }')
		[ "$program" = "$prefix/bin/retype" ] || fail "refusing to control an unowned launchd job: $job"
		pid=$(printf '%s\n' "$output" | awk -F ' = ' '$1 ~ /^[ \t]*pid$/ { print $2; exit }')
		case $pid in '' | *[!0-9]*) [ -z "$pid" ] || fail 'invalid launchd pid' ;; esac
		if [ -n "$pid" ]; then
			[ "${#pid}" -le 10 ] && [ "$pid" -gt 1 ] && [ "$pid" -le 2147483647 ] || fail 'unsafe launchd pid'
		fi
	fi
}

check() {
	[ "$(uname -s)" = Darwin ] || fail 'needs macOS'
	[ "$uid" -ne 0 ] || fail 'refusing a per-user installation as root'
	case $prefix:$HOME in *$'\n'* | *$'\r'* | *$'\t'*) fail 'paths must not contain control characters' ;; esac
	case $prefix in /*) ;; *) fail 'needs an absolute prefix' ;; esac
	case /${prefix#/}/ in *'/../'* | *'/./'* | '//') fail 'unsupported installation prefix' ;; esac
	for path in "$prefix" "$prefix/bin" "$prefix/share" "$share" "$receipt" "$HOME/Applications" \
		"$HOME/Library" "$HOME/Library/LaunchAgents" "$agent"; do
		[ ! -L "$path" ] || fail "refusing a symlinked installation path: $path"
	done
	[ -x "$probe" ] || fail 'release lacks the native notifier app'
	[ "$("$probe" user-home)" = "$HOME" ] || fail 'HOME does not match the ordinary user account'
	[ -x "$unregister" ] || fail 'macOS LaunchServices unregister tool is unavailable'
	if [ -d "$receipt" ]; then
		[ "$(read_value "$receipt/home")" = "$HOME" ] || fail 'use the original installation user'
		[ "$(read_value "$receipt/prefix")" = "$prefix" ] || fail 'installation receipt names another prefix'
		"$notifier" --check >/dev/null || fail 'invalid installed notifier or environment receipt'
	fi
	if exists "$link"; then
		[ -L "$link" ] && [ "$(readlink "$link")" = "$app" ] || fail "another installation owns $link"
	fi
	if exists "$agent"; then
		[ -d "$receipt" ] && [ "$(hash "$agent")" = "$(read_value "$receipt/agent-sha256")" ] ||
			fail "preserved modified or unowned LaunchAgent: $agent"
	fi
	job_state
	if $loaded; then
		[ -d "$receipt" ] || fail 'loaded LaunchAgent has no installation receipt'
	fi
	if $enable_startup || exists "$agent"; then
		launchctl print "$domain" >/dev/null 2>&1 || fail 'native startup needs an ordinary-user GUI session'
	fi
	if [ -x "$prefix/bin/retype" ] && ! $loaded &&
		"$prefix/bin/retype" daemon status --no-spawn --json >/dev/null 2>&1; then
		fail 'stop the unsupervised daemon before updating or removing this installation'
	fi
}

stop_job() {
	job_state
	if ! $loaded; then return; fi
	if [ -n "$pid" ]; then
		# One SIGTERM drains; never escalate or let launchd forcibly kill a conversion.
		kill -TERM "$pid"
		local deadline=$((SECONDS + 300))
		while kill -0 "$pid" 2>/dev/null; do
			[ "$SECONDS" -lt "$deadline" ] || fail 'daemon is still draining; installation and backups retained'
			sleep 0.1
		done
	fi
	launchctl bootout "$job"
}

prepare() {
	check
	[ -n "$journal" ] || fail 'needs --backup'
	mkdir -m 0700 "$journal"
	cp -R "$source/macos/retype.app" "$journal/notifier.app"
	printf '%s\n' "$("$probe" handler)" >"$journal/handler-current"
	printf '%s\n' "$loaded" >"$journal/loaded"
	if exists "$link"; then printf '%s\n' yes >"$journal/link-before"; fi
	if exists "$agent"; then cp -p "$agent" "$journal/agent-before"; fi
	# Record intent before stopping, so a failure still has a rollback record.
	touch "$journal/stopped"
	stop_job
}

make_environment() {
	local destination=$1 key value
	printf '%s\n' '<?xml version="1.0" encoding="UTF-8"?><plist version="1.0"><dict>' >"$destination"
	for key in HOME PATH RETYPE_CONFIG RETYPE_STATE_DIR XDG_CONFIG_HOME XDG_STATE_HOME XDG_DATA_HOME; do
		value=${!key-}
		[ -n "$value" ] || continue
		case $value in *$'\n'* | *$'\r'* | *$'\t'*) fail "control characters in $key" ;; esac
		if [ "$key" != PATH ]; then
			case $value in /*) ;; *) fail "$key must be absolute for native URL/startup dispatch" ;; esac
		fi
		printf '<key>%s</key><string>%s</string>\n' "$key" "$(xml_escape "$value")" >>"$destination"
	done
	printf '%s\n' '</dict></plist>' >>"$destination"
	chmod 0600 "$destination"
	plutil -lint "$destination" >/dev/null
}

write_agent() {
	local template value staged
	if exists "$agent"; then
		[ -f "$journal/agent-before" ] && [ "$(hash "$agent")" = "$(hash "$journal/agent-before")" ] ||
			fail "preserved a LaunchAgent changed during installation: $agent"
	fi
	template=$(<"$share/packaging/macos/com.lapilliworks.retype.cli.plist")
	value=$(xml_escape "$prefix")
	template=${template//@PREFIX@/"$value"}
	mkdir -p "$(dirname "$agent")"
	staged=$(mktemp "$agent.retype.XXXXXX")
	printf '%s\n' "$template" >"$staged"
	plutil -insert EnvironmentVariables -xml "$(<"$receipt/environment.plist")" "$staged"
	plutil -lint "$staged" >/dev/null
	chmod 0644 "$staged"
	printf '%s\n' "$(hash "$staged")" >"$journal/agent-written"
	mv -f "$staged" "$agent"
	printf '%s\n' "$(hash "$agent")" >"$receipt/agent-sha256"
}

install() {
	local old=$backup/share/macos-installation current
	mkdir -m 0700 "$receipt"
	if [ -d "$old" ]; then
		cp -p "$old/environment.plist" "$old/handler-before" "$receipt/"
	else
		make_environment "$receipt/environment.plist"
		cp "$journal/handler-current" "$receipt/handler-before"
	fi
	printf '%s\n' "$HOME" >"$receipt/home"
	printf '%s\n' "$prefix" >"$receipt/prefix"
	"$notifier" --check >/dev/null || fail 'invalid installed notifier or environment receipt'
	mkdir -p "$(dirname "$link")"
	touch "$journal/link-written"
	if exists "$link"; then
		[ -L "$link" ] && [ "$(readlink "$link")" = "$app" ] || fail "preserved an unowned app link: $link"
	else ln -s "$app" "$link"; fi
	touch "$journal/registered"
	"$notifier" register
	current=$("$notifier" handler)
	if [ "$current" = "$(read_value "$journal/handler-current")" ] &&
		{ [ ! -d "$old" ] || [ "$current" = "$label" ]; }; then
		printf '%s\n' "$label" >"$journal/handler-written"
		"$notifier" set-handler "$label"
		[ "$("$notifier" handler)" = "$label" ] || fail 'macOS did not accept the URI association'
	else
		printf 'Preserved changed URI preference\n'
	fi
	if $enable_startup || exists "$agent"; then
		write_agent
		if $enable_startup || [ "$(read_value "$journal/loaded")" = true ]; then
			touch "$journal/started"
			launchctl bootstrap "$domain" "$agent"
		fi
	fi
	printf 'macOS app/URI integration installed; native startup is explicit opt-in\n'
}

remove() {
	[ -d "$receipt" ] || fail 'this installation has no macOS integration receipt'
	if exists "$link"; then
		[ -L "$link" ] && [ "$(readlink "$link")" = "$app" ] || fail "preserved an unowned app link: $link"
	fi
	if exists "$agent"; then
		[ "$(hash "$agent")" = "$(read_value "$receipt/agent-sha256")" ] || fail 'preserved a changed LaunchAgent'
	fi
	local current previous
	current=$("$notifier" handler)
	previous=$(read_value "$receipt/handler-before")
	touch "$journal/registered"
	"$unregister" -u "$app"
	if [ "$current" = "$label" ] && [ -n "$previous" ]; then
		printf '%s\n' "$previous" >"$journal/handler-written"
		"$notifier" set-handler "$previous"
	fi
	if exists "$agent"; then
		printf '%s\n' removed >"$journal/agent-written"
		rm -f "$agent"
	fi
	touch "$journal/link-written"
	if exists "$link"; then rm -f "$link"; fi
	printf 'macOS integration removed; configuration and recovery data are untouched\n'
}

rollback() {
	[ -d "$journal" ] || return
	if [ -f "$journal/link-written" ]; then
		if [ -f "$journal/link-before" ]; then
			if ! exists "$link"; then ln -s "$app" "$link"; fi
		elif [ -L "$link" ] && [ "$(readlink "$link")" = "$app" ]; then rm -f "$link"; fi
	fi
	if [ -f "$journal/agent-written" ]; then
		if exists "$agent" && [ "$(hash "$agent")" != "$(read_value "$journal/agent-written")" ]; then
			fail "rollback preserved a changed LaunchAgent: $agent"
		fi
		if [ -f "$journal/agent-before" ]; then
			cp -p "$journal/agent-before" "$agent"
		else rm -f "$agent"; fi
	fi
	if [ -f "$journal/registered" ]; then
		if [ -x "$notifier" ]; then "$notifier" register; else "$unregister" -u "$app"; fi
	fi
	if [ -f "$journal/handler-written" ]; then
		local previous current recovery_probe
		recovery_probe=$journal/notifier.app/Contents/MacOS/retype-notifier
		previous=$(read_value "$journal/handler-current")
		current=$("$recovery_probe" handler)
		if [ "$current" = "$(read_value "$journal/handler-written")" ] && [ -n "$previous" ]; then
			"$recovery_probe" set-handler "$previous"
		elif [ "$current" != "$previous" ]; then printf 'Preserved changed URI preference during rollback\n'; fi
	fi
	if [ -f "$journal/stopped" ] && [ "$(read_value "$journal/loaded")" = true ]; then
		job_state
		if $loaded; then
			[ -z "$pid" ] || fail 'previous daemon is still draining; resume from the retained backup after it stops'
			launchctl bootout "$job"
		fi
		launchctl bootstrap "$domain" "$agent"
	fi
}

case $operation in
check) check ;;
prepare) prepare ;;
install) install ;;
remove) remove ;;
abort) [ ! -f "$journal/started" ] || stop_job ;;
rollback) rollback ;;
*) fail "unknown operation: $operation" ;;
esac
