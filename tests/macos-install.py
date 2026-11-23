#!/usr/bin/env python3
"""Synthetic macOS installer contracts only: no native OS, signing or desktop proof."""
import argparse
import hashlib
import io
import json
import os
from pathlib import Path
import plistlib
import shlex
import shutil
import subprocess
import sys
import tarfile
import tempfile

ROOT = Path(__file__).resolve().parent.parent
TARGET = 'aarch64-apple-darwin'
APP_ID = 'com.lapilliworks.retype.cli'

FAKE_TOOLS = r'''import json, os, plistlib, sys, tarfile
from pathlib import Path
name = Path(sys.argv[0]).name
args = sys.argv[1:]
root = Path(os.environ['RETYPE_FIXTURE'])
state_path = root / 'native-state.json'
state = json.loads(state_path.read_text())
with (root / 'native-calls.jsonl').open('a') as output:
 output.write(json.dumps([name, *args]) + '\n')
def save(): state_path.write_text(json.dumps(state))
def fail_once(key):
 if state.pop(key, False): save(); sys.exit(1)
if name == 'uname':
 print('Darwin' if args == ['-s'] else 'arm64')
elif name == 'id': print(state.get('uid', 1000))
elif name == 'sw_vers': print(state.get('os_version', '15.0'))
elif name == 'minisign':
 signature = Path(args[args.index('-x') + 1]).read_text()
 sys.exit(0 if signature == 'SYNTHETIC-NOT-A-PUBLISHER-SIGNATURE\n' else 1)
elif name == 'codesign':
 fail_once('fail_codesign')
 if '--display' in args: print('CodeDirectory v=20500 size=1 flags=0x10000(runtime)\nTimestamp=fixture timestamp')
elif name == 'spctl':
 fail_once('fail_spctl'); print('source=Notarized Developer ID')
elif name == 'launchctl':
 if args[0] == 'print':
  if args[1].count('/') == 1: sys.exit(1 if state.get('no_gui') else 0)
  if not state.get('loaded'): sys.exit(1)
  print('\tprogram = ' + state['program'])
  if state.get('pid') is not None: print('\tpid = ' + str(state['pid']))
 elif args[0] == 'bootout': state['loaded'] = False; save()
 elif args[0] == 'bootstrap':
  value = plistlib.loads(Path(args[2]).read_bytes())
  state['program'] = value['ProgramArguments'][0]; state['loaded'] = True; save(); fail_once('fail_bootstrap')
 else: raise AssertionError(args)
elif name == 'lsregister':
 assert args[0] == '-u'; state['registered'] = False
 if state['handler'] == 'com.lapilliworks.retype.cli': state['handler'] = ''
 save()
elif name == 'plutil':
 path = Path(args[-1]); value = plistlib.loads(path.read_bytes())
 if args[0] == '-extract': print(value[args[1]])
 elif args[0] == '-insert':
  value[args[1]] = plistlib.loads(args[args.index('-xml') + 1].encode())
  path.write_bytes(plistlib.dumps(value))
 elif args[0] == '-replace':
  value[args[1]] = args[args.index('-string') + 1]; path.write_bytes(plistlib.dumps(value))
 else: assert args[0] == '-lint'
elif name == 'tar':
 if args == ['--version']: print('bsdtar SYNTHETIC TOOL DOUBLE, not native libarchive'); sys.exit(0)
 if args[0] in ('-tzf', '-tvzf'):
  with tarfile.open(args[1]) as archive:
   for entry in archive.getmembers():
    if args[0] == '-tzf': print(entry.name + ('/' if entry.isdir() and not entry.name.endswith('/') else ''))
    else:
     kind = 'd' if entry.isdir() else '-' if entry.isfile() else 'l' if entry.issym() else 'h'
     print(kind + 'rwxr-xr-x fixture ' + entry.name)
 else:
  assert args[:4] == ['--safe-writes', '--no-same-owner', '--no-same-permissions', '--xattrs']
  archive_path = args[args.index('-xzf') + 1]; destination = args[args.index('-C') + 1]
  with tarfile.open(archive_path) as archive: archive.extractall(destination, filter='data')
elif name == 'retype-notifier':
 if args == ['user-home']: print(state.get('account_home', os.environ['HOME']))
 elif args == ['handler']: print(state['handler'])
 elif args[0] == 'set-handler': state['handler'] = args[1]; save()
 elif args == ['register']: fail_once('fail_register'); state['registered'] = True; save()
 elif args == ['--check']:
  app = Path(sys.argv[0]).resolve().parents[2]
  assert (app / 'Contents/Resources/retype').is_file()
 else: raise AssertionError(args)
else: raise AssertionError(name)
'''


def sha(path):
	return hashlib.sha256(path.read_bytes()).hexdigest()


def main():
	parser = argparse.ArgumentParser(description=__doc__)
	parser.add_argument('--report', required=True, type=Path)
	args = parser.parse_args()
	report = args.report.resolve()
	report.mkdir(parents=True, exist_ok=True)
	fixture = Path(tempfile.mkdtemp(prefix='macos-synthetic-', dir=report))
	tools = fixture / 'tools'
	tools.mkdir()
	script = '#!' + sys.executable + '\n' + FAKE_TOOLS
	for name in ('uname', 'id', 'sw_vers', 'minisign', 'codesign', 'spctl', 'launchctl', 'plutil', 'tar', 'lsregister'):
		path = tools / name
		path.write_text(script)
		path.chmod(0o755)
	state_path = fixture / 'native-state.json'
	state_path.write_text(json.dumps({'handler': 'org.example.previous', 'loaded': False}))
	home = fixture / 'home'
	home.mkdir()
	prefix = fixture / 'prefix with spaces % & \' $cash'
	config = fixture / 'config.toml'
	config.write_text('Retained fixture configuration\n')
	recovery = fixture / 'recovery'
	recovery.mkdir()
	(recovery / 'original').write_bytes(b'Retained original bytes\0\xff')
	original_config, original_recovery = config.read_bytes(), (recovery / 'original').read_bytes()
	env = os.environ.copy()
	env.update(HOME=str(home), PATH=str(tools) + os.pathsep + env['PATH'], RETYPE_FIXTURE=str(fixture),
		RETYPE_CONFIG=str(config), RETYPE_STATE_DIR=str(recovery), RETYPE_TARGET=TARGET,
		RETYPE_RELEASE_BASE=(fixture / 'releases').as_uri(), RETYPE_INSTALL_MODE='preview')
	installer_source = (ROOT / 'packaging/install.sh').read_text()
	installer_source = installer_source.replace('/usr/bin/tar', shlex.quote(str(tools / 'tar')))
	unconfigured = fixture / 'unconfigured-install.sh'
	unconfigured.write_text(installer_source)
	installer = fixture / 'install.sh'
	installer.write_text(installer_source.replace("retype_minisign_public_key=''",
		"retype_minisign_public_key='" + 'A' * 56 + "'").replace("retype_macos_team_id=''",
		"retype_macos_team_id='FIXTURE000'"))
	checks = []
	completed = False

	def check(label, condition):
		assert condition, label
		checks.append(label)
		(report / 'checks.json').write_text(json.dumps(checks, indent=2) + '\n')
		print('PASS synthetic:', label, flush=True)

	def state(**updates):
		value = json.loads(state_path.read_text())
		value.update(updates)
		state_path.write_text(json.dumps(value))
		return value

	def run(label, *options, success=True, mode='preview', script_path=installer, destination=prefix, reason=None):
		process = subprocess.run(['bash', str(script_path), '--prefix', str(destination), *options],
			env={**env, 'RETYPE_INSTALL_MODE': mode}, stdin=subprocess.DEVNULL, capture_output=True, timeout=30)
		(report / (label + '.stdout.log')).write_bytes(process.stdout)
		(report / (label + '.stderr.log')).write_bytes(process.stderr)
		error = process.stderr.decode(errors='replace')
		assert (process.returncode == 0) == success, (label, process.returncode, error)
		if reason is not None:
			assert reason in error, (label, reason, error)

	def release(tag, *, broken=False, late=False, mismatch=False, extra=None):
		name = 'retype-' + tag + '-' + TARGET
		mirror = fixture / 'releases' / tag
		package = mirror / name
		app = package / 'share/retype/macos/retype.app'
		assets = package / 'share/retype/packaging/macos'
		(app / 'Contents/MacOS').mkdir(parents=True)
		(app / 'Contents/Resources').mkdir()
		(package / 'bin').mkdir()
		cli = '#!/bin/sh\n'
		if broken: cli += 'exit 1\n'
		if late: cli += 'case $0 in */bin/retype) exit 1 ;; esac\n'
		cli += 'case $1 in --version) printf "%s\\n" "retype ' + tag + '" ;; *) exit 1 ;; esac\n'
		(package / 'bin/retype').write_text(cli)
		(package / 'bin/retype').chmod(0o755)
		(app / 'Contents/Resources/retype').write_text(cli + ('# Mismatch\n' if mismatch else ''))
		(app / 'Contents/Resources/retype').chmod(0o755)
		(app / 'Contents/MacOS/retype-notifier').write_text(script)
		(app / 'Contents/MacOS/retype-notifier').chmod(0o755)
		shutil.copy2(ROOT / 'packaging/macos/Info.plist', app / 'Contents/Info.plist')
		shutil.copytree(ROOT / 'packaging/macos', assets, ignore=shutil.ignore_patterns('notifier.swift', 'build.sh'))
		helper = assets / 'integrate.sh'
		helper.write_text(helper.read_text().replace(
			'/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister',
			shlex.quote(str(tools / 'lsregister'))))
		(package / 'share/retype/fidelity.toml').write_text('Synthetic fixture, not earned fidelity\n')
		archive_path = mirror / (name + '.tar.gz')
		with tarfile.open(archive_path, 'w:gz') as archive:
			archive.add(package, arcname=name)
			if extra is not None:
				entry_name, kind = extra
				entry = tarfile.TarInfo(entry_name.replace('@ROOT@', name))
				if kind == 'file':
					entry.size = 5
					archive.addfile(entry, io.BytesIO(b'probe'))
				elif kind == 'link':
					entry.type = tarfile.SYMTYPE
					entry.linkname = str(fixture / 'outside-canary')
					archive.addfile(entry)
				else:
					entry.type = tarfile.FIFOTYPE
					archive.addfile(entry)
		(mirror / 'SHA256SUMS').write_text(sha(archive_path) + '  ' + archive_path.name + '\n')
		(mirror / 'SHA256SUMS.minisig').write_text('SYNTHETIC-NOT-A-PUBLISHER-SIGNATURE\n')
		return mirror, archive_path

	try:
		release('v0.0.0-fixture')
		release('v0.0.1-fixture')
		run('missing-publisher-pin', '--version', 'v0.0.0-fixture', success=False, mode='signed',
			script_path=unconfigured, reason='no approved publisher key')
		check('Production pins stay empty; signed default refuses before installation', not (prefix / 'bin/retype').exists())
		state(no_gui=True)
		run('install', '--version', 'v0.0.0-fixture')
		binary = prefix / 'bin/retype'
		app = prefix / 'share/retype/macos/retype.app'
		agent = home / 'Library/LaunchAgents' / (APP_ID + '.plist')
		link = home / 'Applications/retype.app'
		receipt = prefix / 'share/retype/macos-installation'
		environment = (receipt / 'environment.plist').read_bytes()
		check('Default install owns app link, not a startup definition/job', link.is_symlink() and link.resolve() == app and
			not agent.exists() and not state()['loaded'])
		check('Exact packaged CLI and private retained environment', sha(binary) == sha(app / 'Contents/Resources/retype') and
			(receipt / 'environment.plist').stat().st_mode & 0o777 == 0o600 and
			plistlib.loads(environment)['RETYPE_STATE_DIR'] == str(recovery))
		initial = sha(binary)
		run('no-gui-startup', '--version', 'v0.0.0-fixture', '--enable-startup', success=False, reason='GUI session')
		check('Startup without a GUI session refuses without enabling or replacing files',
			sha(binary) == initial and not agent.exists() and not state()['loaded'])
		state(no_gui=False, uid=0)
		run('root-refusal', '--version', 'v0.0.0-fixture', success=False, reason='as root')
		state(uid=1000, os_version='14.7')
		run('os-floor-refusal', '--version', 'v0.0.0-fixture', success=False, reason='macOS 15')
		state(os_version='15.0', account_home=str(fixture / 'other-account'))
		run('home-refusal', '--version', 'v0.0.0-fixture', success=False, reason='HOME does not match')
		state(account_home=str(home))
		check('Root, older OS and mismatched account HOME refuse without changing the install', sha(binary) == initial)
		run('update', '--version', 'v0.0.1-fixture')
		check('Update retains environment and persistent original binary backup',
			(receipt / 'environment.plist').read_bytes() == environment and
			any((path / 'retype').is_file() for path in (prefix / 'share').glob('retype-backup.*')))
		run('second-owner', '--version', 'v0.0.0-fixture', success=False, destination=fixture / 'other-prefix')
		check('A second prefix cannot take over owned user definitions', link.resolve() == app)
		run('startup', '--version', 'v0.0.1-fixture', '--enable-startup')
		unit = plistlib.loads(agent.read_bytes())
		check('Startup requires explicit opt-in and literal escaped path/environment',
			state()['loaded'] and unit['ProgramArguments'] == [str(binary), 'daemon'] and
			unit['EnvironmentVariables'] == plistlib.loads(environment) and unit['ExitTimeOut'] == 0 and
			unit['LimitLoadToSessionType'] == 'Aqua')
		run('active-update', '--version', 'v0.0.0-fixture')
		check('Owned active startup is reloaded across update', state()['loaded'])
		state(loaded=False)
		run('stopped-update', '--version', 'v0.0.1-fixture')
		check('Stopped startup stays stopped across update', not state()['loaded'])
		before = sha(binary)
		state(loaded=True, program=str(fixture / 'unowned-program'))
		run('unowned-job-refusal', '--version', 'v0.0.1-fixture', success=False, reason='unowned launchd job')
		state(program=str(binary), pid=0)
		run('unsafe-pid-refusal', '--version', 'v0.0.1-fixture', success=False, reason='unsafe launchd pid')
		state(loaded=False, pid=None)
		check('Unowned loaded jobs and process-group PID zero are never controlled', sha(binary) == before)
		for tag, options in (('v0.0.2-broken', {'broken': True}), ('v0.0.3-late', {'late': True}),
			('v0.0.4-mismatch', {'mismatch': True})):
			release(tag, **options)
			run(tag, '--version', tag, success=False)
			check('Refusal/rollback preserves old CLI: ' + tag, sha(binary) == before)
		state(fail_register=True)
		run('register-rollback', '--version', 'v0.0.0-fixture', success=False)
		check('Registration failure rolls back binary, assets and definitions', sha(binary) == before and link.resolve() == app)
		state(fail_bootstrap=True)
		run('bootstrap-rollback', '--version', 'v0.0.0-fixture', '--enable-startup', success=False)
		check('Partially loaded startup is unloaded before rollback', sha(binary) == before and not state()['loaded'])
		original_agent = agent.read_bytes()
		agent.write_bytes(original_agent + b'<!-- User modification -->\n')
		run('modified-definition', '--version', 'v0.0.0-fixture', success=False, reason='modified or unowned LaunchAgent')
		run('modified-removal', '--uninstall', success=False, reason='modified or unowned LaunchAgent')
		check('Modified native definition refuses both update and removal and is preserved',
			sha(binary) == before and agent.read_bytes() != original_agent)
		agent.write_bytes(original_agent)
		mirror = fixture / 'releases/v0.0.0-fixture'
		(mirror / 'SHA256SUMS.minisig').write_text('corrupt fixture signature\n')
		run('signature-refusal', '--version', 'v0.0.0-fixture', success=False, mode='signed')
		check('Signed hook rejects invalid signature before replacement', sha(binary) == before)
		(mirror / 'SHA256SUMS.minisig').write_text('SYNTHETIC-NOT-A-PUBLISHER-SIGNATURE\n')
		sums = (mirror / 'SHA256SUMS').read_text()
		(mirror / 'SHA256SUMS').write_text(sums + sums)
		run('duplicate-manifest', '--version', 'v0.0.0-fixture', success=False, mode='signed')
		check('Signed hook rejects duplicate digest entries', sha(binary) == before)
		(mirror / 'SHA256SUMS').write_text('0' * 64 + sums[64:])
		run('preview-checksum-refusal', '--version', 'v0.0.0-fixture', success=False, reason='checksum mismatch')
		check('Explicit preview still refuses a bad digest without replacing files', sha(binary) == before)
		(mirror / 'SHA256SUMS').write_text(sums)
		run('signed-contract', '--version', 'v0.0.1-fixture', mode='signed')
		calls = [json.loads(line) for line in (fixture / 'native-calls.jsonl').read_text().splitlines()]
		check('Signed fixture exercises exact embedded manifest and notarization hooks, not real trust',
			any(call[0] == 'minisign' for call in calls) and
			any(call[0] == 'codesign' and '--check-notarization' in call for call in calls))
		(fixture / 'outside-canary').write_bytes(b'Owned outside-staging canary')
		for index, extra in enumerate((('../outside-canary', 'file'), ('@ROOT@/escape', 'link'),
			('@ROOT@/bin/retype', 'file'), ('@ROOT@/bin/RETYPE', 'file'), ('@ROOT@/fifo', 'special'))):
			tag = 'v0.0.' + str(index + 10) + '-refusal'
			release(tag, extra=extra)
			run(tag, '--version', tag, success=False)
			check('Synthetic unsafe entry refusal: ' + extra[0], sha(binary) == before and
				(fixture / 'outside-canary').read_bytes() == b'Owned outside-staging canary')
		run('owned-offline-uninstall', '--uninstall')
		check('Owned removal restores the prior URI handler and keeps recovery/configuration',
			state()['handler'] == 'org.example.previous' and not binary.exists() and not link.exists() and
			config.read_bytes() == original_config and (recovery / 'original').read_bytes() == original_recovery)
		run('reinstall', '--version', 'v0.0.1-fixture')
		state(handler='org.example.changed')
		run('changed-uri-update', '--version', 'v0.0.1-fixture')
		run('offline-uninstall', '--uninstall')
		check('Uninstall preserves changed URI choice and removes only owned integration',
			state()['handler'] == 'org.example.changed' and not binary.exists() and not link.exists() and not agent.exists())
		check('Configuration and recovery bytes are never replaced or removed',
			config.read_bytes() == original_config and (recovery / 'original').read_bytes() == original_recovery)
		completed = True
	finally:
		(report / 'source-sha256.json').write_text(json.dumps({
			str(path.relative_to(ROOT)): sha(path) for path in (ROOT / 'packaging/install.sh',
				ROOT / 'packaging/macos/integrate.sh', ROOT / 'packaging/macos/notifier.swift')
		}, indent=2) + '\n')
		(report / 'result.json').write_text(json.dumps({
			'ok': completed, 'checks': len(checks), 'fixture': str(fixture), 'native': False, 'publisher_trust': False,
			'limits': 'Python/tar/tool doubles; no native libarchive, Mac SDK, URI, notification, real login or signature proof',
		}, indent=2) + '\n')
	print(str(len(checks)) + ' synthetic macOS installer checks passed; fixture retained at ' + str(fixture))


if __name__ == '__main__':
	main()
