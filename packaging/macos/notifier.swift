import AppKit
import Carbon
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
	process.arguments = ["uri", uri, "--no-spawn"]
	process.environment = try uriEnvironment()
	process.standardInput = FileHandle.nullDevice
	process.terminationHandler = { child in
		child.waitUntilExit()
		finished(child)
	}
	try process.run()
	return process
}

final class NotificationDelegate: NSObject, UNUserNotificationCenterDelegate {
	func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
		withCompletionHandler completion: @escaping (UNNotificationPresentationOptions) -> Void) {
		completion([.banner, .list])
	}
}

func sendNotification(_ title: String, _ body: String) {
	// Keep NSApplication and URL event handling out of notification-only workers.
	let center = UNUserNotificationCenter.current()
	let delegate = NotificationDelegate()
	center.delegate = delegate
	let timer = Timer.scheduledTimer(withTimeInterval: 25, repeats: false) { _ in
		fail("notification delivery or permission timed out")
	}
	center.requestAuthorization(options: [.alert]) { allowed, error in
		if let error = error { fail("notification authorization failed: \(error.localizedDescription)") }
		guard allowed else { fail("notifications are not allowed for retype") }
		let content = UNMutableNotificationContent()
		content.title = title
		content.body = body
		let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
		center.add(request) { error in
			if let error = error { fail("notification failed: \(error.localizedDescription)") }
			exit(0)
		}
	}
	withExtendedLifetime((delegate, timer)) { RunLoop.main.run() }
}

final class URLDelegate: NSObject, NSApplicationDelegate {
	var children: [Process] = []

	func applicationDidFinishLaunching(_ notification: Notification) {
		// A notification click or Finder launch alone must not start a daemon.
		DispatchQueue.main.asyncAfter(deadline: .now() + 2) { self.terminateIfIdle() }
	}

	func terminateIfIdle() {
		if children.isEmpty { NSApp.terminate(nil) }
	}

	@objc func getURL(_ event: NSAppleEventDescriptor, withReplyEvent reply: NSAppleEventDescriptor) {
		guard let uri = event.paramDescriptor(forKeyword: keyDirectObject)?.stringValue else {
			NSLog("retype URL Apple Event has no URI")
			terminateIfIdle()
			return
		}
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
			terminateIfIdle()
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
	guard arguments.count == 3 else { fail("notify needs a title and body") }
	sendNotification(arguments[1], arguments[2])
case nil:
	let delegate = URLDelegate()
	let application = NSApplication.shared
	application.setActivationPolicy(.accessory)
	application.delegate = delegate
	NSAppleEventManager.shared().setEventHandler(delegate, andSelector: #selector(URLDelegate.getURL(_:withReplyEvent:)),
		forEventClass: AEEventClass(kInternetEventClass), andEventID: AEEventID(kAEGetURL))
	application.run()
default:
	fail("unknown notifier argument")
}
