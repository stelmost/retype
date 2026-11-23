#!/usr/bin/env python3
"""Native macOS 15 arm64 archive negatives in explicitly owned, retained staging."""
import argparse
import hashlib
import io
import json
import os
from pathlib import Path
import platform
import shutil
import subprocess
import tarfile
import tempfile

ROOT = Path(__file__).resolve().parent.parent
FLAGS = ['--safe-writes', '--no-same-owner', '--no-same-permissions', '--xattrs']


def main():
	parser = argparse.ArgumentParser(description=__doc__)
	parser.add_argument('--report', required=True, type=Path)
	parser.add_argument('--allow-native-staging', action='store_true',
		help='Acknowledge native extraction only inside this owned report directory')
	args = parser.parse_args()
	if not args.allow_native_staging:
		parser.error('Native staging acknowledgment is required')
	assert platform.system() == 'Darwin' and platform.machine() == 'arm64', 'Requires native macOS arm64, not a skipped pass'
	assert os.getuid() != 0, 'Requires an ordinary-user token'
	version = subprocess.check_output(['sw_vers', '-productVersion'], text=True).strip()
	assert version.split('.')[0] == '15', 'This qualification fixture targets macOS 15'
	report = args.report.resolve()
	report.mkdir(parents=True, exist_ok=True)
	fixture = Path(tempfile.mkdtemp(prefix='native-archive-', dir=report))
	fixture.chmod(0o700)
	name = 'retype-fixture-aarch64-apple-darwin'
	installer = (ROOT / 'packaging/install.sh').read_text()
	block = installer.split('# BEGIN RETYPE_MACOS_EXTRACTION\n', 1)[1].split('# END RETYPE_MACOS_EXTRACTION', 1)[0]
	wrapper = fixture / 'extract.sh'
	wrapper.write_text('#!/bin/bash\nset -euo pipefail\ndie() { printf "%s\\n" "$*" >&2; exit 1; }\n' +
		block + '\nextract_macos "$@"\n')
	checks = []

	def run(label, command, success=None):
		result = subprocess.run(command, stdin=subprocess.DEVNULL, capture_output=True, timeout=30)
		(report / (label + '.stdout.log')).write_bytes(result.stdout)
		(report / (label + '.stderr.log')).write_bytes(result.stderr)
		if success is not None:
			assert (result.returncode == 0) == success, (label, result.returncode, result.stderr.decode(errors='replace'))
		return result

	def check(label, condition):
		assert condition, label
		checks.append(label)
		(report / 'checks.json').write_text(json.dumps(checks, indent=2) + '\n')
		print('PASS native archive:', label, flush=True)

	def snapshot(path):
		info = path.stat()
		return (hashlib.sha256(path.read_bytes()).hexdigest(), info.st_mode, info.st_nlink, info.st_uid)

	try:
		tool = run('tar-version', ['/usr/bin/tar', '--version'], True).stdout.decode()
		assert 'bsdtar' in tool, 'Requires the supported native libarchive tool'
		canary = fixture / 'outside-canary'
		canary.write_bytes(b'Owned original outside the extraction staging directory')
		shutil.copy2(canary, fixture / 'outside-canary.backup')
		before = snapshot(canary)
		cases = (
			('absolute', str(canary), 'file', ''),
			('traversal', '../outside-canary', 'file', ''),
			('symlink', name + '/escape', 'symlink', str(fixture)),
			('hardlink', name + '/hardlink', 'hardlink', str(canary)),
			('duplicate', name + '/payload', 'file', ''),
			('case-collision', name + '/PAYLOAD', 'file', ''),
			('special', name + '/fifo', 'fifo', ''),
		)
		for label, entry_name, kind, target in cases:
			archive = fixture / (label + '.tar.gz')
			with tarfile.open(archive, 'w:gz') as package:
				root = tarfile.TarInfo(name)
				root.type = tarfile.DIRTYPE
				root.mode = 0o755
				package.addfile(root)
				payload = tarfile.TarInfo(name + '/payload')
				payload.size = 4
				payload.mode = 0o644
				package.addfile(payload, io.BytesIO(b'safe'))
				entry = tarfile.TarInfo(entry_name)
				if kind == 'file':
					entry.size = 6
					package.addfile(entry, io.BytesIO(b'attack'))
				else:
					entry.type = {'symlink': tarfile.SYMTYPE, 'hardlink': tarfile.LNKTYPE, 'fifo': tarfile.FIFOTYPE}[kind]
					entry.linkname = target
					package.addfile(entry)
					if kind == 'symlink':
						child = tarfile.TarInfo(name + '/escape/outside-canary')
						child.size = 6
						package.addfile(child, io.BytesIO(b'attack'))
			stage = fixture / (label + '-raw-stage')
			stage.mkdir(mode=0o700)
			# Exercise native secure extraction independently of the listing validator.
			run(label + '-raw', ['/usr/bin/tar', *FLAGS, '-xzf', str(archive), '-C', str(stage)])
			check(label + ' native extraction does not change outside bytes/mode/link count/owner', snapshot(canary) == before)
			run(label + '-wrapper', ['bash', str(wrapper), str(archive), str(fixture / (label + '-checked-stage')), name], False)
			check(label + ' wrapper refuses before installed code or destination mutation', snapshot(canary) == before)
		producer = fixture / 'producer' / name
		producer.mkdir(parents=True)
		(producer / 'payload').write_bytes(b'Native metadata round trip')
		run('set-fixture-xattr', ['/usr/bin/xattr', '-w', 'com.retype.qualification', 'fixture only', str(producer / 'payload')], True)
		archive = fixture / 'native-metadata.tar.gz'
		run('produce-native-metadata', ['/usr/bin/tar', '-czf', str(archive), '-C', str(producer.parent), name], True)
		stage = fixture / 'metadata-stage'
		run('extract-native-metadata', ['bash', str(wrapper), str(archive), str(stage), name], True)
		value = run('read-fixture-xattr', ['/usr/bin/xattr', '-p', 'com.retype.qualification', str(stage / name / 'payload')], True)
		check('Native producer/extractor retains ordinary fixture xattr and bytes', value.stdout.strip() == b'fixture only' and
			(stage / name / 'payload').read_bytes() == (producer / 'payload').read_bytes())
	finally:
		(report / 'result.json').write_text(json.dumps({
			'checks': len(checks), 'fixture': str(fixture), 'os_version': version, 'architecture': platform.machine(),
			'uid': os.getuid(), 'installer_sha256': hashlib.sha256(installer.encode()).hexdigest(),
			'limits': 'No signed-app/notarization-staple, installed URI, notification, login or physical-hardware proof',
		}, indent=2) + '\n')
	print(str(len(checks)) + ' native archive checks passed; all fixtures and failed attempts retained')


if __name__ == '__main__':
	main()
