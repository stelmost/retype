"""Exercise the release handoff with synthetic payloads and test-only signing."""
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parent.parent
SPEC = importlib.util.spec_from_file_location('candidate', ROOT / 'scripts/verify-release-candidate.py')
CANDIDATE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(CANDIDATE)
TAG = 'v0.0.0-test'
REVISION = '1' * 40
PINS = {
	'RETYPE_PUBLISHER_KEY': 'A' * 56,
	'RETYPE_MACOS_TEAM_ID': 'FIXTURE000',
	'RETYPE_PUBLISHER_CERTIFICATE_SHA256': '2' * 64,
}


class ReleaseCandidate(unittest.TestCase):
	def setUp(self):
		self.directory = FIXTURES / self._testMethodName
		self.directory.mkdir()
		self.enterContext(patch.dict(os.environ, PINS))
		for target in CANDIDATE.TARGETS:
			archive = f'retype-{TAG}-{target}.tar.gz'
			(self.directory / archive).write_text(f'{target} synthetic payload\n')
			sha = CANDIDATE.digest(self.directory / archive)
			(self.directory / (archive + '.sha256')).write_text(f'{sha}  {archive}\n')
		subprocess.run(['bash', ROOT / 'scripts/assemble-release.sh', '--signed', self.directory],
			check=True, capture_output=True, timeout=10)
		self.approval = {
			'tag': TAG,
			'revision': REVISION,
			'manifest_sha256': CANDIDATE.digest(self.directory / 'SHA256SUMS'),
			'macos_team_id': PINS['RETYPE_MACOS_TEAM_ID'],
			'windows_certificate_sha256': PINS['RETYPE_PUBLISHER_CERTIFICATE_SHA256'],
			'platforms': {target: {'platform': name, 'checks': dict.fromkeys(CANDIDATE.GATES, 'passed'),
				'report_sha256': hashlib.sha256(f'Synthetic report for {target}'.encode()).hexdigest()}
				for target, name in CANDIDATE.TARGETS.items()},
		}
		self.approve()
		for filename in ('QUALIFICATION.json.minisig', 'SHA256SUMS.minisig'):
			(self.directory / filename).write_text('Unusable signature fixture\n')

	def approve(self):
		record = self.directory / 'QUALIFICATION.json'
		record.write_text(json.dumps(self.approval))
		os.environ['RETYPE_CANDIDATE_QUALIFICATION_SHA256'] = CANDIDATE.digest(record)

	def verify(self, edition=REVISION):
		with patch.object(CANDIDATE, 'verify_signatures') as signatures:
			CANDIDATE.verify(self.directory, TAG, edition)
			signatures.assert_called_once_with(self.directory, PINS['RETYPE_PUBLISHER_KEY'])

	def test_accepts_exact_closure_with_authenticated_approval(self):
		self.verify()

	def test_rejects_unsigned_preview(self):
		(self.directory / 'QUALIFICATION.json.minisig').unlink()
		with self.assertRaisesRegex(ValueError, 'Missing or unexpected'):
			self.verify()

	def test_rejects_approval_for_another_revision(self):
		with self.assertRaisesRegex(ValueError, 'different tag or source revision'):
			self.verify('2' * 40)

	def test_rejects_an_incomplete_platform_gate(self):
		self.approval['platforms']['x86_64-pc-windows-msvc']['checks']['notification'] = 'not run'
		self.approve()
		with self.assertRaisesRegex(ValueError, 'Missing exact required platform evidence'):
			self.verify()

	def test_rejects_approval_for_another_manifest(self):
		self.approval['manifest_sha256'] = '0' * 64
		self.approve()
		with self.assertRaisesRegex(ValueError, 'different publisher manifest'):
			self.verify()

	def test_rejects_a_different_authenticated_approval(self):
		os.environ['RETYPE_CANDIDATE_QUALIFICATION_SHA256'] = '9' * 64
		with self.assertRaisesRegex(ValueError, 'independently approved digest'):
			self.verify()

	def test_rejects_even_an_authenticated_noncanonical_installer(self):
		(self.directory / 'install.sh').write_text('Unapproved installer bytes\n')
		with self.assertRaisesRegex(ValueError, 'differs from pinned canonical source'):
			self.verify()

	def test_rejects_archive_changed_after_approval(self):
		archive = next(self.directory.glob('*.tar.gz'))
		archive.write_text('Unapproved archive bytes\n')
		with self.assertRaisesRegex(ValueError, 'differs from the publisher manifest'):
			self.verify()

	@unittest.skipUnless(shutil.which('minisign'), 'minisign is not on PATH')
	def test_checks_both_signatures_with_a_throwaway_key(self):
		key = self.directory.parent / 'synthetic-signing-key'
		public = key.with_suffix('.pub')
		subprocess.run(['minisign', '-G', '-W', '-p', public, '-s', key], check=True, capture_output=True, timeout=10)
		public_key = public.read_text().splitlines()[-1]
		for name in ('SHA256SUMS', 'QUALIFICATION.json'):
			(self.directory / f'{name}.minisig').unlink()
			subprocess.run(['minisign', '-S', '-s', key, '-m', name], cwd=self.directory,
				check=True, capture_output=True, timeout=10)
		CANDIDATE.verify_signatures(self.directory, public_key)
		(self.directory / 'QUALIFICATION.json').write_text('Tampered approval\n')
		with self.assertRaises(subprocess.CalledProcessError):
			CANDIDATE.verify_signatures(self.directory, public_key)


if __name__ == '__main__':
	FIXTURES = Path(sys.argv.pop(1))
	unittest.main()
