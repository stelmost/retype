#!/usr/bin/env python3
"""Source-only guard for the native shim's mode and child-lifecycle separation."""
import argparse
import hashlib
import json
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent


def check_modes(source):
	worker = source.split('func sendNotification(', 1)[1].split('final class URLDelegate', 1)[0]
	worker = '\n'.join(line for line in worker.splitlines() if not line.lstrip().startswith('//'))
	notification = source.split('case "notify":', 1)[1].split('case nil:', 1)[0]
	url_mode = source.split('case nil:', 1)[1].split('default:', 1)[0]
	url_delegate = source.split('final class URLDelegate', 1)[1].split('checkBundle()\nlet arguments', 1)[0]
	uri = source.split('func openURI(', 1)[1].split('final class NotificationDelegate', 1)[0]
	for forbidden in ('NSApplication', 'NSAppleEventManager', 'NSApp.', 'URLDelegate', 'openURI(',
		'Process(', 'children.'):
		assert forbidden not in worker and forbidden not in notification, forbidden
	assert 'sendNotification(arguments[1], arguments[2])' in notification
	assert 'NSApplication.shared' in url_mode and 'setEventHandler' in url_mode
	assert 'URLDelegate()' in url_mode
	assert 'process.executableURL = cli' in uri
	assert 'process.arguments = ["uri", uri, "--no-spawn"]' in uri
	assert 'child.waitUntilExit()' in uri and 'finished(child)' in uri
	assert 'throws -> Process' in uri
	assert 'var children: [Process] = []' in url_delegate
	assert 'children.append(child)' in url_delegate
	assert 'self.children.removeAll { $0 === finished }' in url_delegate
	assert 'if children.isEmpty { NSApp.terminate(nil) }' in url_delegate
	assert 'exit(' not in url_delegate and 'fail(' not in url_delegate


def main():
	parser = argparse.ArgumentParser(description=__doc__)
	parser.add_argument('--report', required=True, type=Path)
	args = parser.parse_args()
	source = (ROOT / 'packaging/macos/notifier.swift').read_text()
	check_modes(source)
	mutants = (
		source.replace('case "notify":', 'case "notify", nil:', 1),
		source.replace('func sendNotification(_ title: String, _ body: String) {',
			'func sendNotification(_ title: String, _ body: String) {\n\tlet app = NSApplication.shared', 1),
		source.replace('child.waitUntilExit()', '/* Missing reaping */', 1),
		source.replace('self.children.removeAll { $0 === finished }',
			'self.children.removeAll { !$0.isRunning }', 1),
	)
	for mutant in mutants:
		try:
			check_modes(mutant)
		except (AssertionError, IndexError):
			continue
		raise AssertionError('Mode/lifecycle regression escaped the source guard')
	args.report.mkdir(parents=True, exist_ok=True)
	(args.report / 'result.json').write_text(json.dumps({
		'checks': 5,
		'notifier_sha256': hashlib.sha256(source.encode()).hexdigest(),
		'scope': 'Source structure and four rejected regression mutations only',
		'native': False,
		'limits': 'No Swift compilation, Foundation reaping, LaunchServices reuse or notification permission proof',
	}, indent=2) + '\n')
	print('5 source-only macOS mode/lifecycle checks passed; native behavior unproved')


if __name__ == '__main__':
	main()
