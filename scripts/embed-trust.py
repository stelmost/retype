#!/usr/bin/env python3
"""Generate standalone installers with the complete canonical verifier blocks."""
import argparse
import os
from pathlib import Path
import re
import sys

ROOT = Path(__file__).resolve().parent.parent
HELPERS = {
	'.sh': {'RETYPE_RELEASE_TRUST': 'verify.sh', 'RETYPE_MACOS_TRUST': 'verify-macos.sh'},
	'.ps1': {'RETYPE_RELEASE_TRUST': 'verify.ps1', 'RETYPE_WINDOWS_TRUST': 'verify-windows.ps1'},
}

PIN_FIELDS = {
	'RETYPE_PUBLISHER_KEY': r'[A-Za-z0-9+/]{56}',
	'RETYPE_MACOS_TEAM_ID': r'[A-Z0-9]{10}',
	'RETYPE_PUBLISHER_CERTIFICATE_SHA256': r'[a-fA-F0-9]{64}',
}

PIN_ASSIGNMENTS = {
	'.sh': {'retype_minisign_public_key=': 'RETYPE_PUBLISHER_KEY', 'retype_macos_team_id=': 'RETYPE_MACOS_TEAM_ID'},
	'.ps1': {'$publisherKey = ': 'RETYPE_PUBLISHER_KEY', '$publisherCertificateSha256 = ': 'RETYPE_PUBLISHER_CERTIFICATE_SHA256'},
}


def release_pins():
	pins = {name: os.environ.get(name, '') for name in PIN_FIELDS}
	for name, value in pins.items():
		if not re.fullmatch(PIN_FIELDS[name], value):
			raise ValueError(f'An independently approved {name} is required')
	return pins


def pin_installer(source, suffix):
	pins = release_pins()
	for assignment, name in PIN_ASSIGNMENTS[suffix].items():
		placeholder = f"{assignment}''\n"
		if source.count(placeholder) != 1:
			raise ValueError(f'Expected one empty pin assignment for {name}')
		source = source.replace(placeholder, f"{assignment}'{pins[name]}'\n")
	return source


def block(source, name):
	begin = f'# BEGIN {name}'
	end = f'# END {name}'
	if source.count(begin) != 1 or source.count(end) != 1:
		raise ValueError(f'Expected one complete {name} block')
	pattern = re.compile(rf'^{re.escape(begin)}\n.*?^{re.escape(end)}$', re.MULTILINE | re.DOTALL)
	match = pattern.search(source)
	if match is None:
		raise ValueError(f'Malformed {name} markers')
	return match


def embed(installer):
	if installer.suffix not in HELPERS:
		raise ValueError('Expected a .sh or .ps1 installer')
	source = installer.read_text(encoding='utf-8')
	for name, filename in HELPERS[installer.suffix].items():
		canonical = (ROOT / 'packaging' / 'trust' / filename).read_text(encoding='utf-8')
		contents = block(canonical, name).group()
		region = block(source, name)
		source = source[:region.start()] + contents + source[region.end():]
	return source


def main():
	parser = argparse.ArgumentParser(description=__doc__)
	parser.add_argument('--check', action='store_true', help='Refuse non-canonical embedded source')
	parser.add_argument('--signed', action='store_true', help='Embed explicitly supplied approved release pins')
	parser.add_argument('installer', type=Path)
	parser.add_argument('output', type=Path, nargs='?')
	args = parser.parse_args()
	if args.check == (args.output is not None):
		parser.error('Use --check with one installer, or an installer and fresh output path')
	if args.check and args.signed:
		parser.error('--signed requires a fresh output path')
	try:
		contents = embed(args.installer)
		if args.signed:
			contents = pin_installer(contents, args.installer.suffix)
		if args.check:
			if contents != args.installer.read_text(encoding='utf-8'):
				raise ValueError('Embedded trust code differs from canonical helper sources')
		else:
			# Exclusive creation preserves any existing installer, including on a failed retry.
			with args.output.open('x', encoding='utf-8', newline='\n') as output:
				output.write(contents)
		print(f'Trust embedding checked: {args.installer}' if args.check else f'Installer generated: {args.output}')
	except (OSError, ValueError) as error:
		print(f'retype trust embedding: {error}', file=sys.stderr)
		return 1
	return 0


if __name__ == '__main__':
	sys.exit(main())
