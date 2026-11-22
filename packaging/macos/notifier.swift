import AppKit
import Carbon
import CoreGraphics
import CoreServices
import UserNotifications

let appID = "com.lapilliworks.retype.cli"
let bundle = Bundle.main
let cli = bundle.bundleURL.appendingPathComponent("Contents/Resources/retype")
let receipt = bundle.bundleURL.deletingLastPathComponent().deletingLastPathComponent()
	.appendingPathComponent("macos-installation/environment.plist")

func fail(_ message: String) -> Never {
	fputs("retype notifier: \(message)\n", stderr)
	exit(1)
}

struct URIError: LocalizedError {
	let message: String
	var errorDescription: String? { message }
}

func checkBundle() {
	guard bundle.bundleIdentifier == appID, bundle.bundleURL.pathExtension == "app",
		FileManager.default.isExecutableFile(atPath: cli.path) else {
		fail("run the installed app bundle, with its bundled CLI")
	}
}

func uriEnvironment() throws -> [String: String] {
	var environment = ProcessInfo.processInfo.environment
	let manager = FileManager.default
	guard manager.fileExists(atPath: receipt.path) else {
		throw URIError(message: "installation is not ready for URI dispatch")
	}
	let attributes = try manager.attributesOfItem(atPath: receipt.path)
	guard (attributes[.type] as? FileAttributeType) == .typeRegular,
		(attributes[.ownerAccountID] as? NSNumber)?.uint32Value == getuid(),
		(attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600 else {
		throw URIError(message: "installation environment must be an ordinary-user-owned private file")
	}
	let data = try Data(contentsOf: receipt)
	guard let saved = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: String],
		Set(saved.keys).isSubset(of: ["HOME", "PATH", "RETYPE_CONFIG", "RETYPE_STATE_DIR",
			"XDG_CONFIG_HOME", "XDG_STATE_HOME", "XDG_DATA_HOME"]),
		let account = getpwuid(getuid()), let home = account.pointee.pw_dir,
		saved["HOME"] == String(cString: home), saved["PATH"]?.isEmpty == false else {
		throw URIError(message: "invalid installation environment")
	}
	for (key, value) in saved {
		guard !value.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains),
			key == "PATH" || value.hasPrefix("/") else { throw URIError(message: "invalid environment value") }
	}
	environment.merge(saved) { _, installed in installed }
	return environment
}

@discardableResult
func openURI(_ uri: String, finished: @escaping (Process) -> Void) throws -> Process {
	guard uri.lowercased().hasPrefix("retype://"), uri.utf8.count <= 8192,
		!uri.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
		throw URIError(message: "expected a retype:// URI without control characters")
	}
	let process = Process()
	process.executableURL = cli
	process.arguments = ["--no-spawn", "uri", "--", uri]
	process.environment = try uriEnvironment()
	process.standardInput = FileHandle.nullDevice
	process.terminationHandler = { child in
		child.waitUntilExit()
		finished(child)
	}
	try process.run()
	return process
}

enum ReviewNotification {
	static let categoryID = "retype.job-review"
	static let actionID = "retype.job-review.open"
	static let uriKey = "retype.job-review.uri"

	static func isCanonicalURI(_ uri: String) -> Bool {
		return uri.utf8.count == 39 &&
			uri.range(of: #"\Aretype://job/[0-7][0-9abcdefghjkmnpqrstvwxyz]{25}\z"#, options: .regularExpression) != nil
	}
}

func hasActiveUserSession() -> Bool {
	let uid = getuid()
	guard uid != 0, uid == geteuid(),
		let session = CGSessionCopyCurrentDictionary() as? [String: Any] else { return false }
	return session[kCGSessionUserIDKey] as? UInt32 == uid &&
		session[kCGSessionOnConsoleKey] as? Bool == true && session[kCGSessionLoginDoneKey] as? Bool == true
}

func requireActiveUserSession() {
	guard hasActiveUserSession() else { fail("no active ordinary-user graphical session") }
}

func sendNotification(_ title: String, _ body: String, _ reviewURI: String?) {
	guard title.utf8.count <= 128, body.utf8.count <= 8_192 else { fail("notification text is too long") }
	if let reviewURI, !ReviewNotification.isCanonicalURI(reviewURI) {
		fail("notify Review needs a canonical full-ID URI")
	}
	requireActiveUserSession()
	// Only the app activation mode owns notification responses.
	let center = UNUserNotificationCenter.current()
	let timer = Timer.scheduledTimer(withTimeInterval: 25, repeats: false) { _ in
		fail("notification delivery or permission timed out")
	}
	center.requestAuthorization(options: [.alert]) { allowed, error in
		if let error = error { fail("notification authorization failed: \(error.localizedDescription)") }
		guard allowed else { fail("notifications are not allowed for retype") }
		let content = UNMutableNotificationContent()
		content.title = title
		content.body = body
		if let reviewURI {
			let action = UNNotificationAction(identifier: ReviewNotification.actionID, title: "Review",
				options: [.foreground, .authenticationRequired])
			let category = UNNotificationCategory(identifier: ReviewNotification.categoryID, actions: [action],
				intentIdentifiers: [], options: [])
			center.setNotificationCategories([category])
			content.categoryIdentifier = ReviewNotification.categoryID
			content.userInfo = [ReviewNotification.uriKey: reviewURI]
		}
		let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
		center.add(request) { error in
			if let error = error { fail("notification failed: \(error.localizedDescription)") }
			exit(0)
		}
	}
	withExtendedLifetime(timer) { RunLoop.main.run() }
}

@MainActor
func reviewDecision(_ text: String, _ undoLabel: String?) -> Int32 {
	guard !text.isEmpty, text.utf8.count <= 4_096 else { fail("invalid Review text length") }
	if let undoLabel {
		guard undoLabel.utf8.count <= 80, undoLabel == "Undo" || undoLabel.hasPrefix("Undo "),
			!undoLabel.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else {
			fail("invalid Undo button label")
		}
	}
	requireActiveUserSession()
	let application = NSApplication.shared
	guard application.setActivationPolicy(.accessory) else { fail("cannot open the Review window") }
	application.finishLaunching()

	let alert = NSAlert()
	alert.messageText = "retype Review"
	alert.addButton(withTitle: "Close").keyEquivalent = "\r"
	if let undoLabel { alert.addButton(withTitle: undoLabel).keyEquivalent = "" }

	// Wrap the literal snapshot. Do not offer Undo for a clipped list of files.
	let summary = NSTextField(wrappingLabelWithString: text)
	summary.maximumNumberOfLines = 0
	summary.lineBreakMode = .byCharWrapping
	summary.preferredMaxLayoutWidth = 500
	let height = ceil(summary.intrinsicContentSize.height)
	guard height > 0 else { fail("cannot lay out Review text") }
	summary.frame.size = NSSize(width: summary.preferredMaxLayoutWidth, height: height)
	alert.accessoryView = summary
	alert.layout()
	guard let screen = alert.window.screen ?? NSScreen.main,
		summary.frame.width >= summary.preferredMaxLayoutWidth, summary.frame.height >= height,
		alert.window.frame.width <= screen.visibleFrame.width,
		alert.window.frame.height <= screen.visibleFrame.height else { fail("Review does not fit on screen") }

	application.activate()
	let dismissMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
		let key = event.charactersIgnoringModifiers
		guard key == "\r" || key == "\u{1b}" else { return event }
		MainActor.assumeIsolated { application.stopModal(withCode: .cancel) }
		return nil
	}
	guard let dismissMonitor else { fail("cannot bind Review dismiss keys") }
	let timeout: TimeInterval = 60
	let deadline = ContinuousClock.now.advanced(by: .seconds(timeout))
	let timer = Timer(timeInterval: timeout, repeats: false) { _ in
		MainActor.assumeIsolated { application.stopModal(withCode: .cancel) }
	}
	RunLoop.main.add(timer, forMode: .common)
	defer {
		timer.invalidate()
		NSEvent.removeMonitor(dismissMonitor)
	}
	guard alert.runModal() == .alertSecondButtonReturn, undoLabel != nil,
		ContinuousClock.now < deadline else { return 0 }
	requireActiveUserSession()
	return 42
}

final class URLDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
	var children: [Process] = []

	func applicationDidFinishLaunching(_ notification: Notification) {
		// A notification click or Finder launch alone must not start a daemon.
		DispatchQueue.main.asyncAfter(deadline: .now() + 2) { self.terminateIfIdle() }
	}

	func terminateIfIdle() {
		if children.isEmpty { NSApp.terminate(nil) }
	}

	nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
		withCompletionHandler completion: @escaping (UNNotificationPresentationOptions) -> Void) {
		completion([.banner, .list])
	}

	nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
		withCompletionHandler completion: @escaping () -> Void) {
		let content = response.notification.request.content
		guard response.actionIdentifier == ReviewNotification.actionID,
			content.categoryIdentifier == ReviewNotification.categoryID, content.userInfo.count == 1,
			let uri = content.userInfo[ReviewNotification.uriKey] as? String,
			ReviewNotification.isCanonicalURI(uri) else {
			completion()
			return
		}
		DispatchQueue.main.async {
			defer { completion() }
			guard hasActiveUserSession() else {
				NSLog("retype Review unavailable: no active ordinary-user graphical session")
				return
			}
			self.dispatchURI(uri)
		}
	}

	@objc func getURL(_ event: NSAppleEventDescriptor, withReplyEvent reply: NSAppleEventDescriptor) {
		guard let uri = event.paramDescriptor(forKeyword: keyDirectObject)?.stringValue else {
			NSLog("retype URL Apple Event has no URI")
			return
		}
		dispatchURI(uri)
	}

	func dispatchURI(_ uri: String) {
		do {
			let child = try openURI(uri) { finished in
				if finished.terminationStatus != 0 {
					NSLog("retype URI handler exited %d", finished.terminationStatus)
				}
				DispatchQueue.main.async {
					self.children.removeAll { $0 === finished }
					self.terminateIfIdle()
				}
			}
			children.append(child)
		} catch {
			NSLog("retype cannot handle URL: %@", error.localizedDescription)
		}
	}
}

checkBundle()
let arguments = Array(CommandLine.arguments.dropFirst())
switch arguments.first {
case "--check":
	guard arguments.count == 1 else { fail("--check takes no arguments") }
	if FileManager.default.fileExists(atPath: receipt.deletingLastPathComponent().path) {
		do { _ = try uriEnvironment() } catch { fail(error.localizedDescription) }
	}
	print("retype notifier: \(appID)")
	exit(0)
case "user-home":
	guard arguments.count == 1, let entry = getpwuid(getuid()), let home = entry.pointee.pw_dir else {
		fail("cannot identify the ordinary user's home")
	}
	print(String(cString: home))
	exit(0)
case "handler":
	guard arguments.count == 1 else { fail("handler takes no arguments") }
	let handler = LSCopyDefaultHandlerForURLScheme("retype" as CFString)?.takeRetainedValue()
	print(handler.map { $0 as String } ?? "")
	exit(0)
case "set-handler":
	guard arguments.count == 2, arguments[1].range(of: "^[A-Za-z0-9][A-Za-z0-9.-]*$",
		options: .regularExpression) != nil else { fail("expected a bundle identifier") }
	let status = LSSetDefaultHandlerForURLScheme("retype" as CFString, arguments[1] as CFString)
	guard status == noErr else { fail("cannot set URI handler (OSStatus \(status))") }
	exit(0)
case "register":
	guard arguments.count == 1 else { fail("register takes no arguments") }
	let status = LSRegisterURL(bundle.bundleURL as CFURL, true)
	guard status == noErr else { fail("cannot register app (OSStatus \(status))") }
	exit(0)
case "uri":
	guard arguments.count == 2 else { fail("uri needs one URI") }
	do {
		let child = try openURI(arguments[1]) { finished in exit(finished.terminationStatus) }
		withExtendedLifetime(child) { RunLoop.main.run() }
	} catch { fail(error.localizedDescription) }
case "notify":
	guard arguments.count == 3 || arguments.count == 4 else { fail("notify needs a title, body and optional Review URI") }
	let reviewURI = arguments.count == 4 ? arguments[3] : nil
	sendNotification(arguments[1], arguments[2], reviewURI)
case "review":
	guard arguments.count == 2 || arguments.count == 3 else { fail("review needs text and an optional Undo label") }
	let undoLabel = arguments.count == 3 ? arguments[2] : nil
	exit(MainActor.assumeIsolated { reviewDecision(arguments[1], undoLabel) })
case nil:
	requireActiveUserSession()
	let delegate = URLDelegate()
	let application = NSApplication.shared
	application.setActivationPolicy(.accessory)
	application.delegate = delegate
	UNUserNotificationCenter.current().delegate = delegate
	NSAppleEventManager.shared().setEventHandler(delegate, andSelector: #selector(URLDelegate.getURL(_:withReplyEvent:)),
		forEventClass: AEEventClass(kInternetEventClass), andEventID: AEEventID(kAEGetURL))
	withExtendedLifetime(delegate) { application.run() }
default:
	fail("unknown notifier argument")
}
