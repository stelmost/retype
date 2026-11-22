#!/usr/bin/env python3
"""Verify one exact, publisher-signed and qualified initial-release candidate."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parent.parent
TARGETS = {
	'x86_64-unknown-linux-gnu': 'Debian 13 amd64',
	'aarch64-apple-darwin': 'macOS 15 arm64',
	'x86_64-pc-windows-msvc': 'Windows 10 22H2 amd64',
}
INSTALLERS = ('install.sh', 'install.ps1')
GATES = ('native_trust', 'recovery', 'uri', 'startup', 'notification', 'session', 'removal')
TRUST_FILES = ('SHA256SUMS', 'SHA256SUMS.minisig', 'QUALIFICATION.json', 'QUALIFICATION.json.minisig')
SHA256 = r'[a-f0-9]{64}'


def digest(path):
	with path.open('rb') as file:
		return hashlib.file_digest(file, 'sha256').hexdigest()


def verify_signatures(directory, key):
	if not re.fullmatch(r'[A-Za-z0-9+/]{56}', key):
		raise ValueError('An independently approved RETYPE_PUBLISHER_KEY is required')
	for name in TRUST_FILES:
		if not 0 < (directory / name).stat().st_size <= 1024 * 1024:
			raise ValueError(f'Empty or oversized trust file: {name}')
	for name in ('SHA256SUMS', 'QUALIFICATION.json'):
		subprocess.run(['minisign', '-V', '-P', key, '-m', name, '-x', name + '.minisig'],
			cwd=directory, check=True, timeout=30)


def verify_payloads(directory, payloads):
	manifest = {}
	for line in (directory / 'SHA256SUMS').read_text(encoding='ascii').splitlines():
		entry = re.fullmatch(rf'({SHA256}) [ *]([A-Za-z0-9][A-Za-z0-9._+-]*)', line)
		if not entry or entry[2] in manifest:
			raise ValueError('Malformed or duplicate publisher manifest entry')
		manifest[entry[2]] = entry[1]
	if manifest.keys() != payloads:
		raise ValueError('Publisher manifest must cover the exact required archives and both installers')
	for name, expected in manifest.items():
		if digest(directory / name) != expected:
			raise ValueError(f'Asset differs from the publisher manifest: {name}')
		checksum = (directory / f'{name}.sha256').read_bytes()
		if checksum not in (f'{expected}  {name}\n'.encode(), f'{expected} *{name}\n'.encode()):
			raise ValueError(f'Bad asset checksum file: {name}.sha256')


def unique_fields(pairs):
	values = dict(pairs)
	if len(values) != len(pairs):
		raise ValueError('Duplicate qualification field')
	return values


def verify_qualification(directory, tag, revision):
	approval_path = directory / 'QUALIFICATION.json'
	if digest(approval_path) != os.environ.get('RETYPE_CANDIDATE_QUALIFICATION_SHA256', ''):
		raise ValueError('Qualification does not match the independently approved digest')
	approval = json.loads(approval_path.read_bytes(), object_pairs_hook=unique_fields)
	if approval['tag'] != tag or approval['revision'] != revision:
		raise ValueError('Qualification is for a different tag or source revision')
	if approval['manifest_sha256'] != digest(directory / 'SHA256SUMS'):
		raise ValueError('Qualification is for a different publisher manifest')
	if (approval['macos_team_id'] != os.environ.get('RETYPE_MACOS_TEAM_ID')
			or approval['windows_certificate_sha256'].lower() != os.environ.get('RETYPE_PUBLISHER_CERTIFICATE_SHA256', '').lower()):
		raise ValueError('Qualification did not use the independently pinned native publishers')
	platforms = approval['platforms']
	if platforms.keys() != TARGETS.keys():
		raise ValueError('Qualification must cover all three primary targets')
	for target, system in TARGETS.items():
		report = platforms[target]
		if (report['platform'] != system or report['checks'] != dict.fromkeys(GATES, 'passed')
				or not re.fullmatch(SHA256, report['report_sha256'])):
			raise ValueError(f'Missing exact required platform evidence: {target}')


def verify_installers(directory):
	with tempfile.TemporaryDirectory(prefix='retype-installer-check-') as temporary:
		for name in INSTALLERS:
			expected = Path(temporary) / name
			subprocess.run([sys.executable, ROOT / 'scripts/embed-trust.py', '--signed', ROOT / 'packaging' / name, expected],
				check=True, timeout=30)
			if expected.read_bytes() != (directory / name).read_bytes():
				raise ValueError(f'Signed installer differs from pinned canonical source: {name}')


def verify(directory, tag, revision):
	if not re.fullmatch(r'v[0-9][A-Za-z0-9.+-]*', tag) or not re.fullmatch(r'[a-f0-9]{40}', revision):
		raise ValueError('Expected a version tag and complete source revision')
	if directory.is_symlink():
		raise ValueError('Candidate directory must not be a symlink')
	payloads = {f'retype-{tag}-{target}.tar.gz' for target in TARGETS} | set(INSTALLERS)
	files = payloads | {f'{name}.sha256' for name in payloads} | set(TRUST_FILES)
	if {path.name for path in directory.iterdir()} != files:
		raise ValueError('Missing or unexpected candidate assets; unsigned previews cannot be promoted')
	for name in files:
		path = directory / name
		if not path.is_file() or path.is_symlink() or not path.stat().st_size:
			raise ValueError(f'Not a nonempty regular candidate asset: {name}')
	verify_signatures(directory, os.environ.get('RETYPE_PUBLISHER_KEY', ''))
	verify_qualification(directory, tag, revision)
	verify_installers(directory)
	verify_payloads(directory, payloads)


def main():
	parser = argparse.ArgumentParser(description=__doc__)
	parser.add_argument('directory', type=Path)
	parser.add_argument('tag')
	parser.add_argument('revision')
	args = parser.parse_args()
	try:
		verify(args.directory, args.tag, args.revision)
	except (OSError, ValueError, AttributeError, KeyError, TypeError, subprocess.SubprocessError) as error:
		raise SystemExit(f'retype release candidate: {error}') from error
	print(f'Exact signed and qualified candidate verified: {args.tag} at {args.revision}')


if __name__ == '__main__':
	main()
