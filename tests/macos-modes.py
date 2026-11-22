#!/usr/bin/env python3
"""Source-only guard for the macOS shim's separate delivery, activation and Review modes."""
import argparse
import hashlib
import json
import re
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent


def between(source, start, end):
	return source.split(start, 1)[1].split(end, 1)[0]


def check_modes(source):
	worker = between(source, 'func sendNotification(', '@MainActor\nfunc reviewDecision')
	notification = between(source, 'case "notify":', 'case "review":')
	url_mode = between(source, 'case nil:', 'default:')
	url_delegate = between(source, 'final class URLDelegate', 'checkBundle()\nlet arguments')
	uri = between(source, 'func openURI(', 'enum ReviewNotification')
	for forbidden in ('NSApplication', 'NSAppleEventManager', 'NSApp.', 'URLDelegate', 'openURI(',
		'Process(', 'children.', 'delegate =', 'didReceive', 'reviewDecision('):
		assert forbidden not in worker and forbidden not in notification, forbidden
	assert 'arguments.count == 4 ? arguments[3] : nil' in notification
	assert 'sendNotification(arguments[1], arguments[2], reviewURI)' in notification
	assert 'requireActiveUserSession()' in url_mode
	assert 'NSApplication.shared' in url_mode and 'setEventHandler' in url_mode
	assert 'URLDelegate()' in url_mode
	assert url_mode.index('UNUserNotificationCenter.current().delegate = delegate') < url_mode.index('application.run()')
	assert 'withExtendedLifetime(delegate) { application.run() }' in url_mode
	assert 'process.executableURL = cli' in uri
	assert 'process.arguments = ["uri", uri, "--no-spawn"]' in uri
	assert 'child.waitUntilExit()' in uri and 'finished(child)' in uri
	assert 'throws -> Process' in uri
	assert 'var children: [Process] = []' in url_delegate
	assert 'children.append(child)' in url_delegate
	assert 'self.children.removeAll { $0 === finished }' in url_delegate
	assert 'if children.isEmpty { NSApp.terminate(nil) }' in url_delegate
	assert 'openURI(uri)' in url_delegate and url_delegate.count('dispatchURI(uri)') == 2
	assert 'exit(' not in url_delegate and 'fail(' not in url_delegate


def check_notification_review(source):
	worker = between(source, 'func sendNotification(', '@MainActor\nfunc reviewDecision')
	action = between(worker, '\n\t\tif let reviewURI {', '\n\t\t}')
	response = between(source, 'didReceive response: UNNotificationResponse', '@objc func getURL')
	assert worker.index('!ReviewNotification.isCanonicalURI(reviewURI)') < worker.index('requestAuthorization(')
	assert worker.index('requireActiveUserSession()') < worker.index('UNUserNotificationCenter.current()')
	assert 'title.utf8.count <= 128' in worker and 'body.utf8.count <= 8_192' in worker
	assert 'content.title = title' in worker and 'content.body = body' in worker
	assert 'title: "Review"' in action and 'options: [.foreground' in action and 'actions: [action]' in action
	assert 'content.categoryIdentifier = ReviewNotification.categoryID' in action
	assert 'content.userInfo = [ReviewNotification.uriKey: reviewURI]' in action
	assert worker.count('content.categoryIdentifier =') == worker.count('content.userInfo =') == 1
	assert 'response.actionIdentifier == ReviewNotification.actionID' in response
	assert 'content.categoryIdentifier == ReviewNotification.categoryID' in response
	assert 'content.userInfo.count == 1' in response
	assert 'let uri = content.userInfo[ReviewNotification.uriKey] as? String' in response
	assert 'ReviewNotification.isCanonicalURI(uri) else {\n\t\t\tcompletion()\n\t\t\treturn' in response
	assert 'DispatchQueue.main.async' in response and 'defer { completion() }' in response
	assert response.index('guard hasActiveUserSession() else') < response.index('self.dispatchURI(uri)')
	assert 'Process(' not in response and 'reviewDecision(' not in response


def check_uri_pattern(source):
	validator = between(source, 'static func isCanonicalURI(', 'func hasActiveUserSession(')
	matcher = re.search(
		r'uri\.utf8\.count == (\d+) &&\s+uri\.range\(of: #"(.*?)"#, options: \.regularExpression\)', validator)
	assert matcher is not None
	length, pattern = matcher.groups()
	assert pattern.startswith(r'\A') and pattern.endswith(r'\z')
	# Check examples against the Swift literal, mapping ICU's end anchor to Python's.
	regex = re.compile(pattern[:-2] + r'\Z')

	def matches(uri):
		return len(uri.encode()) == int(length) and regex.fullmatch(uri) is not None

	prefix = 'retype://job/'
	job_id = '01m6b4rararx3wrttkrgpp1783'
	valid = prefix + job_id
	assert matches(valid) and matches(prefix + '7' + 'z' * 25)
	invalid = (
		valid[:-1], valid + '0', prefix + job_id.upper(), prefix.upper() + job_id,
		valid.replace('/01', '/81'), valid.replace('/01', '/%301'), valid + '#fragment',
		*(valid[:-1] + char for char in 'ilou*\n'),
		*(valid + '?action=' + action for action in ('review', 'undo', 'cancel', 'resolve')),
	)
	for uri in invalid:
		assert not matches(uri), repr(uri)


def check_review_dialog(source):
	dialog = between(source, 'func reviewDecision(', 'final class URLDelegate')
	review_mode = between(source, 'case "review":', 'case nil:')
	session = between(source, 'func hasActiveUserSession(', 'func requireActiveUserSession(')
	for forbidden in ('Process(', 'openURI(', 'dispatchURI(', 'FileManager', 'NSAppleEventManager',
		'UNUserNotificationCenter'):
		assert forbidden not in dialog and forbidden not in review_mode, forbidden
	assert 'arguments.count == 3 ? arguments[2] : nil' in review_mode
	assert 'reviewDecision(arguments[1], undoLabel)' in review_mode
	assert 'uid != 0, uid == geteuid()' in session and 'CGSessionCopyCurrentDictionary()' in session
	assert 'session[kCGSessionUserIDKey] as? UInt32 == uid' in session
	assert 'session[kCGSessionOnConsoleKey] as? Bool == true' in session
	assert 'session[kCGSessionLoginDoneKey] as? Bool == true' in session
	assert dialog.index('requireActiveUserSession()') < dialog.index('NSApplication.shared')
	assert 'text.utf8.count <= 4_096' in dialog and 'undoLabel.utf8.count <= 80' in dialog
	assert 'NSAlert()' in dialog and 'NSTextField(wrappingLabelWithString: text)' in dialog
	assert 'alert.accessoryView = summary' in dialog and 'summary.frame.height >= height' in dialog
	assert 'alert.window.frame.height <= screen.visibleFrame.height' in dialog
	close = r'alert.addButton(withTitle: "Close").keyEquivalent = "\r"'
	undo = 'if let undoLabel { alert.addButton(withTitle: undoLabel).keyEquivalent = "" }'
	assert dialog.index(close) < dialog.index(undo)
	assert r'key == "\r" || key == "\u{1b}"' in dialog
	assert dialog.count('application.stopModal(withCode: .cancel)') == 2
	assert 'timeout: TimeInterval = 60' in dialog and 'RunLoop.main.add(timer, forMode: .common)' in dialog
	assert 'guard alert.runModal() == .alertSecondButtonReturn, undoLabel != nil,' in dialog
	assert 'ContinuousClock.now < deadline else { return 0 }' in dialog
	assert 'requireActiveUserSession()\n\treturn 42' in dialog and source.count('return 42') == 1


def check_source(source):
	check_modes(source)
	check_notification_review(source)
	check_uri_pattern(source)
	check_review_dialog(source)


def main():
	parser = argparse.ArgumentParser(description=__doc__)
	parser.add_argument('--report', required=True, type=Path)
	args = parser.parse_args()
	source = (ROOT / 'packaging/macos/notifier.swift').read_text()
	check_source(source)
	mutations = (
		('case "notify":', 'case "notify", nil:'),
		('let center = UNUserNotificationCenter.current()', 'let app = NSApplication.shared'),
		('child.waitUntilExit()', '/* Missing reaping */'),
		('self.children.removeAll { $0 === finished }', 'self.children.removeAll { !$0.isRunning }'),
		('[0-7][0-9abcdefghjkmnpqrstvwxyz]', '[0-9][0-9abcdefghjkmnpqrstvwxyz]'),
		('response.actionIdentifier == ReviewNotification.actionID',
			'response.actionIdentifier == UNNotificationDefaultActionIdentifier'),
		('content.categoryIdentifier == ReviewNotification.categoryID', 'true'),
		('self.dispatchURI(uri)', 'self.dispatchURI(content.body)'),
		(r'alert.addButton(withTitle: "Close").keyEquivalent = "\r"', 'alert.addButton(withTitle: "Close")'),
		('alert.runModal() == .alertSecondButtonReturn', 'alert.runModal() == .alertFirstButtonReturn'),
		('RunLoop.main.add(timer, forMode: .common)', 'RunLoop.main.add(timer, forMode: .default)'),
	)
	for before, after in mutations:
		assert before in source, before
		try:
			check_source(source.replace(before, after, 1))
		except (AssertionError, IndexError, ValueError):
			continue
		raise AssertionError(f'Source guard missed regression: {after}')
	checks = 1 + len(mutations)
	args.report.mkdir(parents=True, exist_ok=True)
	(args.report / 'result.json').write_text(json.dumps({
		'checks': checks,
		'notifier_sha256': hashlib.sha256(source.encode()).hexdigest(),
		'scope': 'Source structure, canonical URI pattern examples and rejected source mutations',
		'native': False,
		'limits': 'Swift/macOS uncompiled: no AppKit, WindowServer, notification, LaunchServices or child reaping proof',
	}, indent=2) + '\n')
	print(f'{checks} source-only macOS mode checks passed; Swift/macOS uncompiled and native behavior unproved')


if __name__ == '__main__':
	main()
