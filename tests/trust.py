#!/usr/bin/env python3
"""Synthetic verifier/embedding checks. No publisher key or native signature is used."""
import argparse
from datetime import datetime, timezone
import hashlib
import json
import os
from pathlib import Path
import platform
import shutil
import subprocess
import sys

ROOT = Path(__file__).resolve().parent.parent
# Invalid algorithm bytes: this is not a minisign public key or publisher identity.
NON_KEY = 'A' * 56
NAME = 'retype-v0.0.0-synthetic-x86_64-unknown-linux-gnu.tar.gz'
DATA = b'Synthetic bytes, not an archive or executable.\n'
DIGEST = hashlib.sha256(DATA).hexdigest()
SOURCES = ['packaging/trust/verify.sh', 'packaging/trust/verify.ps1',
	'packaging/trust/verify-windows.ps1', 'packaging/trust/verify-macos.sh',
	'scripts/embed-trust.py', 'tests/trust.py']

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--report', required=True, type=Path, help='Fresh persistent report directory, outside Cargo target')
args = parser.parse_args()
REPORT = args.report.resolve()
target = Path(os.environ.get('CARGO_TARGET_DIR', ROOT / 'target')).resolve()
if REPORT.is_relative_to(target):
	parser.error('Reports must be outside Cargo target')
REPORT.mkdir()
BASH = shutil.which('bash')
if BASH is None:
	raise SystemExit('bash is required for synthetic tests')
RESULTS = []


def tool(directory, name, source):
	path = directory / name
	path.write_text('#!' + BASH + '\nset -eu\n' + source)
	path.chmod(0o700)


def check(label, command, succeeds=True, environment=None, diagnostic=None):
	env = os.environ.copy()
	if environment:
		env.update(environment)
	process = subprocess.run([str(item) for item in command], env=env, cwd=ROOT,
		stdin=subprocess.DEVNULL, capture_output=True, text=True, timeout=15)
	(REPORT / (label + '.stdout')).write_text(process.stdout)
	(REPORT / (label + '.stderr')).write_text(process.stderr)
	passed = (process.returncode == 0) == succeeds
	if diagnostic is not None:
		passed = passed and diagnostic in process.stderr
	RESULTS.append({'case': label, 'scope': 'synthetic', 'exit': process.returncode, 'passed': passed})
	if not passed:
		raise AssertionError(f'{label}: unexpected result; all fixtures/logs retained in {REPORT}')


def manifest_tests():
	bin_dir = REPORT / 'minisign-double'
	bin_dir.mkdir()
	tool(bin_dir, 'minisign', f'''
[[ $# -eq 7 && $1 == -V && $2 == -P && $3 == '{NON_KEY}' && $4 == -m && $6 == -x ]]
[[ $(<"$7") == SYNTHETIC-NOT-A-SIGNATURE ]]
[[ ${{RETYPE_TEST_REJECT:-0}} != 1 ]]
''')
	environment = {'PATH': str(bin_dir) + os.pathsep + os.environ['PATH']}
	cases = {
		'valid': (f'{DIGEST}  {NAME}\n', True),
		'binary-crlf': (f'{DIGEST} *{NAME}\r\n', True),
		'no-final-newline': (f'{DIGEST}  {NAME}', True),
		'duplicate': (f'{DIGEST}  {NAME}\n{DIGEST}  {NAME}\n', False),
		'case-collision': (f'{DIGEST}  {NAME}\n{DIGEST}  {NAME.upper()}\n', False),
		'traversal': (f'{DIGEST}  {NAME}\n{DIGEST}  ../outside\n', False),
		'bad-digest': (f'{"0" * 64}  {NAME}\n', False),
		'blank-line': (f'{DIGEST}  {NAME}\n\n', False),
		'extra-cr': (f'{DIGEST}  {NAME}\r\r\n', False),
		'wrong-name': (f'{DIGEST}  {NAME.upper()}\n', False),
		'malformed': (f'not-a-digest  {NAME}\n', False),
	}
	for label, (contents, succeeds) in cases.items():
		directory = REPORT / ('manifest-' + label)
		directory.mkdir()
		archive, sums, signature = directory / NAME, directory / 'SHA256SUMS', directory / 'SHA256SUMS.minisig'
		archive.write_bytes(DATA)
		sums.write_bytes(contents.encode('ascii'))
		signature.write_text('SYNTHETIC-NOT-A-SIGNATURE\n')
		command = [BASH, ROOT / SOURCES[0], archive, sums, signature, NON_KEY]
		check('manifest-' + label, command, succeeds, environment)
		if label == 'valid':
			check('missing-key', command[:-1] + [''], False, environment, 'pinned minisign public key')
			check('rejected-signature', command, False, {**environment, 'RETYPE_TEST_REJECT': '1'},
				'publisher manifest signature rejected')
			check('missing-signature', command[:4] + [directory / 'absent.minisig', NON_KEY], False, environment)
			no_tool = REPORT / 'without-minisign'
			no_tool.mkdir()
			(no_tool / 'wc').symlink_to(shutil.which('wc'))
			check('missing-minisign', command, False, {'PATH': str(no_tool)}, 'independently trusted minisign')
			link = directory / 'linked.tar.gz'
			link.symlink_to(archive)
			check('archive-symlink', [BASH, ROOT / SOURCES[0], link, sums, signature, NON_KEY],
				False, environment, 'non-symlink file')
			entry = REPORT / 'parser-entry.sh'
			entry.write_text('source "$1"\n_retype_manifest_checksum "$2" "$3"\n')
			check('parser-escaped-name', [BASH, entry, ROOT / SOURCES[0], sums,
				NAME.replace('-', r'\055', 1)], False, environment)


def macos_tests():
	bin_dir = REPORT / 'macos-doubles'
	bin_dir.mkdir()
	tool(bin_dir, 'uname', "printf 'Darwin\\n'\n")
	tool(bin_dir, 'plutil', '''
case $2 in
CFBundleIdentifier) printf 'com.lapilliworks.retype.cli\n' ;;
CFBundleExecutable) printf 'retype-notifier\n' ;;
*) exit 64 ;;
esac
''')
	tool(bin_dir, 'codesign', '''
component=${!#}
case $1 in
--verify)
	if [[ $* == *--check-notarization* ]]; then
		[[ $* == *'=notarized'* && ${RETYPE_TEST_NOTARISED:-1} == 1 ]]
	else
		[[ $* == *--deep* && $* == *--strict* && $* == *'=anchor apple generic'* ]]
		[[ $* == *'certificate leaf[subject.OU] = "0000000000"'* ]]
		id=com.lapilliworks.retype.cli
		[[ $component != */Resources/retype ]] || id=$id.command
		[[ $* == *"identifier = \\\"$id\\\""* ]]
		[[ ${RETYPE_TEST_CODE_REJECT:-0} != 1 ]]
	fi ;;
--display)
	printf 'CodeDirectory v=20500 flags=%s(runtime) hashes=1\n' "${RETYPE_TEST_FLAGS:-0x10000}"
	case ${RETYPE_TEST_TIMESTAMP:-present} in
	present) printf 'Timestamp=synthetic time 2026\n' ;;
	none) printf 'Timestamp=none\n' ;;
	missing) : ;;
	esac ;;
*) exit 64 ;;
esac
''')
	tool(bin_dir, 'spctl', '''
[[ $* == *--ignore-cache* && $* == *--no-cache* ]]
[[ ${RETYPE_TEST_ASSESS_REJECT:-0} != 1 ]]
printf 'accepted\nsource=%s\n' "${RETYPE_TEST_SOURCE:-Notarized Developer ID}"
''')
	app = REPORT / 'synthetic.app'
	(app / 'Contents/MacOS').mkdir(parents=True)
	(app / 'Contents/Resources').mkdir()
	(app / 'Contents/Info.plist').write_text('Not a real app plist.\n')
	(app / 'Contents/MacOS/retype-notifier').write_bytes(DATA)
	(app / 'Contents/Resources/retype').write_bytes(DATA)
	command = [BASH, ROOT / SOURCES[3], app, 'Contents/Resources/retype', '0000000000',
		'com.lapilliworks.retype.cli', 'com.lapilliworks.retype.cli.command']
	environment = {'PATH': str(bin_dir) + os.pathsep + os.environ['PATH']}
	check('macos-adapter-positive', command, True, environment)
	cases = {
		'code-rejected': {'RETYPE_TEST_CODE_REJECT': '1'},
		'runtime-missing': {'RETYPE_TEST_FLAGS': '0x0'},
		'timestamp-missing': {'RETYPE_TEST_TIMESTAMP': 'missing'},
		'timestamp-none': {'RETYPE_TEST_TIMESTAMP': 'none'},
		'not-notarised': {'RETYPE_TEST_NOTARISED': '0'},
		'gatekeeper-rejected': {'RETYPE_TEST_ASSESS_REJECT': '1'},
		'gatekeeper-disabled': {'RETYPE_TEST_SOURCE': 'assessment disabled'},
		'gatekeeper-allow-rule': {'RETYPE_TEST_SOURCE': 'Developer ID'},
	}
	for label, changes in cases.items():
		check('macos-' + label, command, False, {**environment, **changes})
	check('macos-missing-team', command[:4] + [''] + command[5:], False, environment)
	check('macos-wrong-team', command[:4] + ['1111111111'] + command[5:], False, environment)
	check('macos-cli-traversal', command[:3] + ['Contents/Resources/../outside'] + command[4:], False, environment)


def embedding_tests():
	for suffix, native_name in [('.sh', 'MACOS'), ('.ps1', 'WINDOWS')]:
		fixture = REPORT / ('installer' + suffix)
		fixture.write_text('Installer fixture, not a production installer.\n' + ''.join(
			f'# BEGIN RETYPE_{name}_TRUST\nstale code\n# END RETYPE_{name}_TRUST\n'
			for name in ['RELEASE', native_name]))
		output = REPORT / ('rendered' + suffix)
		command = [sys.executable, ROOT / 'scripts/embed-trust.py']
		check('embedding-stale' + suffix, command + ['--check', fixture], False)
		check('embedding-render' + suffix, command + [fixture, output])
		check('embedding-check' + suffix, command + ['--check', output])
		before = output.read_bytes()
		check('embedding-no-replace' + suffix, command + [fixture, output], False)
		assert output.read_bytes() == before
		if suffix == '.sh':
			check('embedded-bash-syntax', [BASH, '-n', output])
	malformed = REPORT / 'malformed.sh'
	malformed.write_text('# BEGIN RETYPE_RELEASE_TRUST\nmissing end\n')
	check('embedding-missing-block', [sys.executable, ROOT / 'scripts/embed-trust.py', malformed,
		REPORT / 'never-created.sh'], False)
	assert not (REPORT / 'never-created.sh').exists()


metadata = {'utc': datetime.now(timezone.utc).isoformat(), 'source': str(ROOT),
	'revision': subprocess.check_output(['git', 'rev-parse', 'HEAD'], cwd=ROOT, text=True).strip(),
	'status': subprocess.check_output(['git', 'status', '--short'], cwd=ROOT, text=True),
	'os': platform.system(), 'architecture': platform.machine(), 'kernel': platform.release(),
	'uid': os.getuid() if hasattr(os, 'getuid') else None,
	'effective_uid': os.geteuid() if hasattr(os, 'geteuid') else None,
	'python': platform.python_version(),
	'tools': {name: shutil.which(name) for name in ['bash', 'minisign', 'pwsh', 'codesign', 'spctl', 'xcrun']},
	'limits': ['Synthetic tool doubles only; no native cryptographic positive',
		'No OS-release read or blocked native/inline probe retried',
		'Publisher material, signing authorization and exact native installed checks remain blocked']}
for name in SOURCES:
	source = ROOT / name
	destination = REPORT / 'source' / name
	destination.parent.mkdir(parents=True, exist_ok=True)
	shutil.copy2(source, destination)
metadata['source_sha256'] = {name: hashlib.sha256((ROOT / name).read_bytes()).hexdigest() for name in SOURCES}
(REPORT / 'metadata.json').write_text(json.dumps(metadata, indent=2) + '\n')
try:
	check('bash-verifier-syntax', [BASH, '-n', ROOT / SOURCES[0]])
	check('bash-macos-syntax', [BASH, '-n', ROOT / SOURCES[3]])
	manifest_tests()
	macos_tests()
	embedding_tests()
finally:
	(REPORT / 'results.json').write_text(json.dumps(RESULTS, indent=2) + '\n')
	(REPORT / 'summary.txt').write_text(
		f'Synthetic checks: {sum(result["passed"] for result in RESULTS)}/{len(RESULTS)} passed\n'
		'Native/publisher signature positives and PowerShell execution: BLOCKED, not passed\n'
		'All fixtures, source snapshots and logs retained; no cleanup performed\n')
print(f'Synthetic checks: {len(RESULTS)} passed. Native/publisher positives BLOCKED. Report: {REPORT}')
