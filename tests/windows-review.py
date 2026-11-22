#!/usr/bin/env python3
"""Check the Windows Review refusal paths in source, without running PowerShell or WinForms."""
from base64 import b64encode
from pathlib import Path
import re


def check_source(source):
	_, program = source.split("-TypeDefinition @'\n", 1)
	native, wrapper = program.split("\n'@\n", 1)
	assert re.findall(r"GetEnvironmentVariable\('([^']+)'\)", wrapper) == [
		'RETYPE_REVIEW_TEXT', 'RETYPE_REVIEW_UNDO_LABEL',
	]
	assert 'exit ([RetypeReview]::Show(' in wrapper and 'catch { exit 1 }' in wrapper
	assert len(b64encode(source.encode('utf-16-le'))) < 30_000, 'Encoded command must fit the Windows command line'

	assert native.count('UseMnemonic = false') == 2, 'The summary and button labels are literal'
	assert 'form.AcceptButton = form.CancelButton = close;' in native
	assert 'form.ActiveControl = close;' in native
	assert 'Keys.Enter' in native and 'DialogResult = DialogResult.Cancel;' in native
	assert re.findall(r'\bDialogResult\s*=\s*DialogResult\.(\w+)', native) == ['Cancel', 'Cancel', 'Yes']
	assert '!String.IsNullOrWhiteSpace(undoLabel)' in native
	assert re.search(r'last\.Click \+= [^\n]+\n\s*if \(!Fits\(form\)\)[^\n]+\n'
		r'\s*form\.DialogResult = DialogResult\.Yes;', native)

	for guard in ('!Environment.UserInteractive', 'session == 0', '!= WTSActive',
		'IsDefaultDesktop(GetThreadDesktop(GetCurrentThreadId()))', 'return IsDefaultDesktop(input);',
		'IsInRole(WindowsBuiltInRole.Administrator)'):
		assert guard in native, guard
	assert 'const int TimeoutMs = 60000;' in native
	assert 'Timer(_ => Environment.Exit(0), null, TimeoutMs, -1)' in native
	assert len(re.findall(r'\b(?:exit|return)\s+42\b', source)) == 1
	decision = native.split('if (!Layout(form, text, undoLabel) || !OnInteractiveDesktop()) return 1;', 1)[1]
	assert [line.strip() for line in decision.strip().splitlines()][:5] == [
		'if (form.ShowDialog() != DialogResult.Yes || String.IsNullOrWhiteSpace(undoLabel)) return 0;',
		'if (!OnInteractiveDesktop()) return 1;',
		'}',
		'if (clock.ElapsedMilliseconds >= TimeoutMs) return 0;',
		'return 42;',
	]


if __name__ == '__main__':
	helper = Path(__file__).resolve().parents[1] / 'packaging/windows/review.ps1'
	check_source(helper.read_text(encoding='utf-8'))
	print('Windows Review source guard passed; no native behavior tested.')
