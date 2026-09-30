//
//  VPNStatusMenuUITests.swift
//  VPNStatusUITests
//
//  Real end-to-end UI tests: launch the actual VPNStatus menu-bar app, open its
//  real status-item menu, read the real rows, activate real rows, and observe
//  the real VPN state change and the real app termination.
//
//  How this automates an NSStatusItem menu on macOS:
//
//  1. READING works. Once the status item is clicked, XCUITest can see the
//     menu's rows and read their stable identifiers and titles. The app sets
//     these identifiers in AppDelegate.m:
//        service.action.<UUID>  Connect/Disconnect <name>
//        static.settings        Settings…
//        static.quit            Quit VPNStatus
//     A row's checkmark (NSMenuItem state) is NOT exposed — isSelected/value are
//     always empty for popped-up status-menu rows — so assert on the title,
//     which encodes the same state.
//
//  2. ACTIVATING rows goes through a UI-test hook, not a click. Clicking a
//     popped-up row DOES work (a row has a real frame and .click() dispatches
//     its real action in ~1.3s), but the tests activate rows deterministically
//     by asking the app — launched with UITEST_AUTOMATION=1 — to perform the
//     row's action by identifier via a distributed notification. The app calls
//     -[NSMenu performActionForItemAtIndex:], the exact code path a user click
//     triggers (connectService:/disconnectService:/doQuit:). The menu CONTENTS
//     the tests assert on are read from the live menu by XCUITest.
//
//  Note: a CLOSED status menu still lists its rows in the AX tree but with
//  zero-size frames, so "open" must be gated on a row having a real, non-zero
//  frame (see openStatusMenu()), never mere existence.
//

import XCTest

final class VPNStatusMenuUITests: XCTestCase {

	// Must match kUITestActivateRequest in AppDelegate.m.
	private let activateNotification = "org.timac.VPNStatus.uitest.activate"

	var app: XCUIApplication!

	override func setUpWithError() throws {
		continueAfterFailure = false
		app = XCUIApplication()
		app.launchEnvironment["UITEST_AUTOMATION"] = "1"
		app.launch()
	}

	override func tearDownWithError() throws {
		app?.terminate()
	}

	// MARK: - Helpers

	private func statusItem() -> XCUIElement {
		return app.statusItems["VPNStatusItem"]
	}

	// Opens the status-item menu and HARD-GATES on it actually being open: this
	// is a throwing precondition, so if the menu does not open the test aborts
	// right here (before any measuring or assertions). A test must call this as
	// its first step and `try` it.
	//
	// Clicking a menu-bar status item can register without opening the menu, so
	// we activate the app and retry. A closed status menu still exposes its rows
	// in the AX tree but with zero-size frames, so "open" is defined as the Quit
	// row having a real (non-zero) on-screen frame — never mere existence.
	@discardableResult
	private func openStatusMenu(file: StaticString = #file, line: UInt = #line) throws -> XCUIElement {
		let item = statusItem()
		XCTAssertTrue(item.waitForExistence(timeout: 10),
					  "VPNStatus status item should appear in the menu bar", file: file, line: line)

		let quit = item.menuItems["static.quit"]
		func menuIsOpen() -> Bool {
			return quit.exists && quit.frame.size.height > 1 && quit.frame.size.width > 1
		}

		for _ in 0..<8 {
			if menuIsOpen() { break }
			app.activate()
			usleep(400_000)
			item.click()
			let deadline = Date().addingTimeInterval(3)
			while Date() < deadline && !menuIsOpen() {
				usleep(150_000)
			}
			if menuIsOpen() { break }
			app.typeKey(.escape, modifierFlags: [])
			usleep(400_000)
		}

		// HARD GATE: fail AND abort the test if the menu is not open. Nothing
		// downstream is meaningful unless the menu actually rendered.
		guard menuIsOpen() else {
			XCTFail("MENU DID NOT OPEN — aborting. Quit row frame=\(quit.frame). Every menu test must fail here before measuring anything.",
					file: file, line: line)
			throw MenuError.didNotOpen
		}
		return item
	}

	private enum MenuError: Error {
		case didNotOpen
	}

	private func dismissMenu() {
		app.typeKey(.escape, modifierFlags: [])
	}

	// Width of the currently-open status menu, measured from the on-screen frames
	// of its rows (the widest row spans the menu's content width). Only rows with
	// a real, non-zero frame are considered — a closed menu still lists its rows
	// with zero frames.
	private func openMenuWidth() -> CGFloat {
		let rows = statusItem().menuItems.allElementsBoundByIndex
		var maxRight: CGFloat = 0
		var minLeft: CGFloat = .greatestFiniteMagnitude
		var sawReal = false
		for row in rows {
			let f = row.frame
			if f.size.width > 1 && f.size.height > 1 {
				sawReal = true
				minLeft = min(minLeft, f.origin.x)
				maxRight = max(maxRight, f.origin.x + f.size.width)
			}
		}
		return sawReal ? (maxRight - minLeft) : 0
	}

	// Activates a menu row (by identifier) through the app's UI-test hook, which
	// performs the row's real NSMenuItem action just like a click.
	private func activateRow(_ identifier: String) {
		DistributedNotificationCenter.default().postNotificationName(
			NSNotification.Name(activateNotification),
			object: identifier,
			userInfo: nil,
			deliverImmediately: true)
	}

	// Identifier of the per-service action row currently in the menu, or nil.
	// Prefers a service that is currently Connected (title "Disconnect <name>"):
	// such a row is provably a real togglable tunnel. Some NE configurations
	// (e.g. DNS-over-HTTPS / content-filter proxies) expose a "Connect <name>"
	// row but never report a Connected ne_session, so activating them can never
	// satisfy a Connected assertion. Falling back to the first service row keeps
	// the earlier behavior when nothing is currently connected.
	private func serviceActionIdentifier() -> String? {
		let rows = statusItem().menuItems.allElementsBoundByIndex.filter {
			$0.identifier.hasPrefix("service.action.") && !$0.identifier.hasSuffix(".sep")
		}
		if let connected = rows.first(where: { $0.title.hasPrefix("Disconnect ") }) {
			return connected.identifier
		}
		return rows.first?.identifier
	}

	// The identifier of the per-service row for a specific VPN name, or nil if no
	// such row is currently in the (open) menu.
	private func serviceRowIdentifier(forName name: String) -> String? {
		let rows = statusItem().menuItems.allElementsBoundByIndex.filter {
			$0.identifier.hasPrefix("service.action.") && !$0.identifier.hasSuffix(".sep")
		}
		return rows.first(where: { $0.title.contains(name) })?.identifier
	}

	// Reopens the status menu in the same session (dismiss first), hard-gating on
	// it actually rendering. Reopening a status menu and re-reading its rows works
	// (verified): use this to observe the menu keeping up to date across state
	// changes without relaunching the app.
	@discardableResult
	private func reopenStatusMenu(file: StaticString = #file, line: UInt = #line) throws -> XCUIElement {
		dismissMenu()
		usleep(500_000)
		return try openStatusMenu(file: file, line: line)
	}

	// Opens the menu and reads a specific service row's rendered title, then
	// dismisses. Returns nil if the row is not present. (The NSMenuItem checkmark
	// is NOT exposed to XCUITest for popped-up status-menu rows — isSelected and
	// value are always empty — so the title is the observable state indicator.
	// It fully encodes the checkmark anyway: "Disconnect <name>" is checked,
	// "Connect <name>" is unchecked.)
	private func readServiceRowTitle(name: String) throws -> String? {
		try openStatusMenu()
		defer { dismissMenu() }
		guard let rowID = serviceRowIdentifier(forName: name) else { return nil }
		return statusItem().menuItems[rowID].title
	}

	// MARK: - Tests

	// The status item exists and is clickable — the menu-bar agent launched.
	func testStatusItemAppears() throws {
		XCTAssertTrue(statusItem().waitForExistence(timeout: 10),
					  "VPNStatus status item should appear in the menu bar")
	}

	// Opening the menu shows the static Settings and Quit items, located by their
	// stable identifiers within the status item's own menu.
	func testMenuShowsStaticItems() throws {
		let item = try openStatusMenu()

		let quit = item.menuItems["static.quit"]
		let settings = item.menuItems["static.settings"]

		XCTAssertTrue(quit.exists, "Quit item should be visible in the status menu")
		XCTAssertEqual(quit.title, "Quit VPNStatus")
		XCTAssertTrue(settings.exists, "Settings item should be visible in the status menu")
		XCTAssertEqual(settings.title, "Settings…")

		dismissMenu()
	}

	// With a real VPN configured, the menu shows a per-service action row whose
	// title is one of: "Connect <name>", "Disconnect <name>",
	// "Disconnect <name> - Connecting...", or "Disconnecting <name>...". The
	// service name is carried in the action row's own title (there is no separate
	// name label row any more), and the row is a plain NSMenuItem in every state.
	func testMenuShowsAServiceActionRow() throws {
		try openStatusMenu()

		guard let actionID = serviceActionIdentifier() else {
			let none = statusItem().menuItems["service.none"]
			XCTAssertTrue(none.exists,
						  "With no VPN configured, the 'No VPN available' placeholder should be shown")
			dismissMenu()
			return
		}

		let title = statusItem().menuItems[actionID].title
		let looksLikeServiceRow =
			title.hasPrefix("Connect ") || title.hasPrefix("Disconnect ") ||
			title.hasPrefix("Disconnecting ")
		XCTAssertTrue(looksLikeServiceRow,
					  "Service action row should read Connect/Disconnect/Disconnecting <name>, got: \(title)")

		dismissMenu()
	}

	// End-to-end connect/disconnect: activate the service action row (the real
	// NSMenuItem action, exactly what a click dispatches) and verify the real VPN
	// transitions to the opposite state, then activate again and verify it returns
	// to the original state. The effect is confirmed via the vpnutil CLI, which
	// reads the same ne_session status the menu reflects.
	func testClickingServiceTogglesConnection() throws {
		try openStatusMenu()

		guard let actionID = serviceActionIdentifier() else {
			dismissMenu()
			throw XCTSkip("No VPN service configured on this machine; skipping connect/disconnect test.")
		}
		let uuid = actionID.replacingOccurrences(of: "service.action.", with: "")
		let startTitle = statusItem().menuItems[actionID].title
		let isSettled =
			(startTitle.hasPrefix("Connect ") || startTitle.hasPrefix("Disconnect ")) &&
			!startTitle.hasSuffix("- Connecting...")
		guard isSettled else {
			dismissMenu()
			throw XCTSkip("Service is in a transitional state (\(startTitle)); skipping toggle test.")
		}
		let startedConnected = startTitle.hasPrefix("Disconnect ")
		// The row title is "Connect <name>" / "Disconnect <name>".
		let vpnName = startTitle
			.replacingOccurrences(of: "Connect ", with: "")
			.replacingOccurrences(of: "Disconnect ", with: "")
		dismissMenu()

		guard let vpnutil = vpnutilPath() else {
			throw XCTSkip("vpnutil not found; install it with `brew install timac/vpnstatus/vpnutil` to run the connect/disconnect test.")
		}

		// Sanity: the CLI agrees with the menu about the starting state.
		let initialStatus = vpnStatus(vpnutil: vpnutil, name: vpnName)
		XCTAssertEqual(initialStatus == "Connected", startedConnected,
					   "vpnutil (\(initialStatus)) should agree with the menu (\(startTitle)) on the starting state")

		// Activate the row (real Connect/Disconnect action) and verify the VPN
		// actually transitions to the opposite state.
		activateRow("service.action.\(uuid)")
		let want1 = startedConnected ? "Disconnected" : "Connected"
		let seen1 = waitForVPNStatus(vpnutil: vpnutil, name: vpnName, desired: want1, timeout: 60)
		XCTAssertEqual(seen1, want1,
					   "After activating the row, the VPN should be \(want1) (was \(initialStatus))")

		// Activate again and verify it returns to the original state.
		activateRow("service.action.\(uuid)")
		let want2 = startedConnected ? "Connected" : "Disconnected"
		let seen2 = waitForVPNStatus(vpnutil: vpnutil, name: vpnName, desired: want2, timeout: 60)
		XCTAssertEqual(seen2, want2,
					   "After the second activation, the VPN should return to \(want2)")
	}

	// Clean-disconnect disables auto-connect. Connect the test VPN through the
	// app (which arms auto-connect and, on reaching Connected, commits it), then
	// disconnect it OUT-OF-BAND via the vpnutil CLI — a clean, user-initiated
	// stop. The app must NOT auto-reconnect it, and the menu row must track the
	// state the whole time via its title: "Connect <name>" -> "Disconnect <name>"
	// -> back to "Connect <name>", staying disconnected. (The title fully encodes
	// the checkmark: Connected shows "Disconnect <name>" with a checkmark; the
	// checkmark itself is not readable through XCUITest, the title is.)
	//
	// Requires the local test VPN target (test/target_vpn) reachable. Skips if it
	// is absent or won't connect.
	func testCleanCLIDisconnectDisablesAutoConnect() throws {
		guard let vpnutil = vpnutilPath() else {
			throw XCTSkip("vpnutil not found; install it with `brew install timac/vpnstatus/vpnutil`.")
		}

		// Locate the test-vpn row (only the local strongSwan target is safe to
		// drive) and learn its name + UUID.
		try openStatusMenu()
		let testRows = statusItem().menuItems.allElementsBoundByIndex.filter {
			$0.identifier.hasPrefix("service.action.") && !$0.identifier.hasSuffix(".sep") &&
			$0.title.contains("test-vpn-")
		}
		guard let startRow = testRows.first else {
			dismissMenu()
			throw XCTSkip("No 'test-vpn-*' service present; stand up test/target_vpn to run this test.")
		}
		let connectRowID = startRow.identifier
		let uuid = connectRowID.replacingOccurrences(of: "service.action.", with: "")
		let vpnName = startRow.title
			.replacingOccurrences(of: "Connect ", with: "")
			.replacingOccurrences(of: "Disconnect ", with: "")
		dismissMenu()

		// Establish a clean baseline that survives app relaunch: terminate the
		// app, disconnect the VPN, and clear ITS persisted always-auto-connect
		// flag (a prior run may have committed it, which would make the app
		// auto-reconnect on launch). Then relaunch fresh.
		app.terminate()
		runVpnutil(vpnutil, ["stop", vpnName])
		_ = waitForVPNStatus(vpnutil: vpnutil, name: vpnName, desired: "Disconnected", timeout: 30)
		clearPersistedAutoConnect(uuid: uuid)
		app.launch()

		guard vpnStatus(vpnutil: vpnutil, name: vpnName) == "Disconnected" else {
			throw XCTSkip("Test VPN '\(vpnName)' would not settle Disconnected for a clean baseline.")
		}

		// Before: Connect <name>.
		if let beforeTitle = try readServiceRowTitle(name: vpnName) {
			XCTAssertTrue(beforeTitle.hasPrefix("Connect "),
						  "Before connecting, row should read 'Connect <name>', got: \(beforeTitle)")
		} else {
			XCTFail("test-vpn row disappeared before connecting")
		}

		// Connect THROUGH THE APP (arms auto-connect; commits on Connected).
		try openStatusMenu()
		activateRow(connectRowID)
		dismissMenu()

		let connected = waitForVPNStatus(vpnutil: vpnutil, name: vpnName, desired: "Connected", timeout: 60)
		guard connected == "Connected" else {
			throw XCTSkip("Test VPN '\(vpnName)' did not connect (saw \(connected)); target may be unreachable.")
		}

		// Menu tracks Connected: Disconnect <name>.
		if let midTitle = try readServiceRowTitle(name: vpnName) {
			XCTAssertTrue(midTitle.hasPrefix("Disconnect "),
						  "While connected, row should read 'Disconnect <name>', got: \(midTitle)")
		} else {
			XCTFail("test-vpn row disappeared while connected")
		}

		// Now disconnect OUT-OF-BAND via the CLI — a clean, user-initiated stop.
		runVpnutil(vpnutil, ["stop", vpnName])

		let disconnected = waitForVPNStatus(vpnutil: vpnutil, name: vpnName, desired: "Disconnected", timeout: 60)
		XCTAssertEqual(disconnected, "Disconnected",
					   "The clean CLI stop should leave the VPN Disconnected")

		// The core assertion: it must STAY disconnected — no auto-reconnect. Poll
		// long enough to cover an immediate backoff retry (the loop's first retry
		// is immediate). Any Connecting/Connected observed here is a failure.
		let watchDeadline = Date().addingTimeInterval(30)
		while Date() < watchDeadline {
			let s = vpnStatus(vpnutil: vpnutil, name: vpnName)
			XCTAssertEqual(s, "Disconnected",
						   "After a clean CLI disconnect the app must NOT reconnect; saw \(s)")
			usleep(2_000_000)
		}

		// After: back to Connect <name> — the menu kept up to date.
		if let afterTitle = try readServiceRowTitle(name: vpnName) {
			XCTAssertTrue(afterTitle.hasPrefix("Connect "),
						  "After the clean disconnect, row should return to 'Connect <name>', got: \(afterTitle)")
		} else {
			XCTFail("test-vpn row disappeared after disconnect")
		}
	}

	// A connecting service renders as a plain NSMenuItem titled
	// "Disconnect <name> - Connecting..." (with a checkmark). This asserts the
	// row's title reads through XCUITest accessibility. Skips (does not fail)
	// when no service is currently Connecting.
	func testConnectingRowShowsConnectingTitle() throws {
		let item = try openStatusMenu()

		// Find a connecting service row by its menu-item title.
		let rows = item.menuItems.allElementsBoundByIndex.filter {
			$0.identifier.hasPrefix("service.action.") && !$0.identifier.hasSuffix(".sep")
		}
		guard let connectingRow = rows.first(where: { $0.title.hasSuffix("- Connecting...") }) else {
			dismissMenu()
			throw XCTSkip("No service is currently Connecting; start a slow/unreachable VPN to exercise this row.")
		}

		let title = connectingRow.title
		XCTAssertTrue(title.hasPrefix("Disconnect "),
					  "Connecting row should start with 'Disconnect ', got: \(title)")
		XCTAssertTrue(title.hasSuffix(" - Connecting..."),
					  "Connecting row should end with ' - Connecting...', got: \(title)")
		XCTAssertFalse(title.contains("\u{2026}"),
					   "Connecting title must use three literal periods, not an ellipsis character: \(title)")

		dismissMenu()
	}

	// Diagnostic: dumps the REAL open-menu geometry and rendered label contents
	// for every readable row. Reads only external accessibility (frames + label
	// values).
	func testDumpOpenMenuMetrics() throws {
		let item = try openStatusMenu()

		usleep(600_000)

		let shot = XCUIScreen.main.screenshot()
		let att = XCTAttachment(screenshot: shot)
		att.name = "open-menu"
		att.lifetime = .keepAlways
		add(att)

		let rows = item.menuItems.allElementsBoundByIndex
		print("=== OPEN MENU METRICS BEGIN (rowCount=\(rows.count)) ===")
		for row in rows {
			let f = row.frame
			print(String(format: "ROW id='%@' title='%@' frame={x=%.1f y=%.1f w=%.1f h=%.1f}",
						 row.identifier, row.title, f.origin.x, f.origin.y, f.size.width, f.size.height))
		}
		print("=== OPEN MENU METRICS END ===")

		print("=== STATICTEXTS BEGIN ===")
		for st in item.staticTexts.allElementsBoundByIndex {
			let f = st.frame
			print(String(format: "STATICTEXT id='%@' value='%@' label='%@' frame={x=%.1f y=%.1f w=%.1f h=%.1f}",
						 st.identifier, (st.value as? String) ?? "", st.label, f.origin.x, f.origin.y, f.size.width, f.size.height))
		}
		print("=== STATICTEXTS END ===")

		dismissMenu()
	}

	// Activating Quit terminates the app: the app process reports not-running and
	// the status item disappears.
	func testQuitTerminatesApp() throws {
		try openStatusMenu()
		XCTAssertTrue(statusItem().menuItems["static.quit"].exists, "Quit row should exist")
		dismissMenu()

		// Activate the real Quit action.
		activateRow("static.quit")

		XCTAssertTrue(statusItem().waitForNonExistence(timeout: 15),
					  "The status item should disappear after Quit")
	}

	// Opening the menu, dismissing it, and opening it AGAIN (same app session, no
	// relaunch) must render the menu at the SAME width when the content has not
	// changed. This reproduces "the menu shrinks the second time you open it".
	//
	// Everything is observed through XCUITest accessibility: the width each time
	// is the span of the open menu's row frames (see openMenuWidth()). We open by
	// clicking the real status item, dismiss with Escape, then click the real
	// status item again — no close/relaunch of the app in between.
	func testMenuWidthIsSameOnReopen() throws {
		// First open (hard-gated) and its width, read via accessibility.
		try openStatusMenu()
		let firstWidth = openMenuWidth()
		XCTAssertGreaterThan(firstWidth, 1, "First open should have a real, measurable menu width")

		// Dismiss the menu (content unchanged) — app keeps running.
		dismissMenu()
		usleep(600_000)

		// Second open: click the SAME real status item again and gate on the menu
		// actually being on screen (Quit row has a real, non-zero frame).
		let item = statusItem()
		let quit = item.menuItems["static.quit"]
		func menuIsOpen() -> Bool {
			return quit.exists && quit.frame.size.height > 1 && quit.frame.size.width > 1
		}
		var reopened = false
		for _ in 0..<8 {
			if menuIsOpen() { reopened = true; break }
			app.activate()
			usleep(400_000)
			item.click()
			let deadline = Date().addingTimeInterval(3)
			while Date() < deadline && !menuIsOpen() {
				usleep(150_000)
			}
			if menuIsOpen() { reopened = true; break }
			app.typeKey(.escape, modifierFlags: [])
			usleep(400_000)
		}
		XCTAssertTrue(reopened, "Menu must reopen in the same session so we can measure its width the second time")

		let secondWidth = openMenuWidth()
		XCTAssertGreaterThan(secondWidth, 1, "Second open should have a real, measurable menu width")

		// The core assertion: same content ⇒ same width every open. No shrinking.
		XCTAssertEqual(secondWidth, firstWidth, accuracy: 0.5,
					   "Menu width changed on reopen with unchanged content: first=\(firstWidth) second=\(secondWidth). It must be identical every open.")

		dismissMenu()
	}

	// MARK: - VPN state via the vpnutil CLI

	// Locates the vpnutil binary. vpnutil is NOT part of this repo any more; it
	// is installed independently from Homebrew (`brew install
	// timac/vpnstatus/vpnutil`) and used here purely for independent
	// verification of the real VPN state.
	private func vpnutilPath() -> String? {
		let candidates = [
			"/opt/homebrew/bin/vpnutil", // Apple-silicon Homebrew
			"/usr/local/bin/vpnutil",    // Intel Homebrew
		]
		return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
	}

	// Runs vpnutil with the given arguments, ignoring output. Used for `stop`.
	@discardableResult
	private func runVpnutil(_ vpnutil: String, _ args: [String]) -> Bool {
		let proc = Process()
		proc.executableURL = URL(fileURLWithPath: vpnutil)
		proc.arguments = args
		proc.standardOutput = Pipe()
		proc.standardError = Pipe()
		do {
			try proc.run()
			proc.waitUntilExit()
			return true
		} catch {
			return false
		}
	}

	// Clears the persisted always-auto-connect flag for one service UUID so a
	// fresh app launch won't auto-reconnect it. The app stores a `Services` array
	// of {Identifier, AlwaysConnected} dicts in its NSUserDefaults domain; edit
	// the matching element in place via PlistBuddy while the app is not running.
	// Best-effort: no-ops if the plist or service isn't present.
	private func clearPersistedAutoConnect(uuid: String) {
		let domain = "org.timac.VPNStatus"
		let plist = ("~/Library/Preferences/\(domain).plist" as NSString).expandingTildeInPath
		guard let count = plistBuddyInt("Print :Services", plist: plist) else { return }
		for i in 0..<count {
			if let id = plistBuddyString("Print :Services:\(i):Identifier", plist: plist), id == uuid {
				_ = plistBuddy("Set :Services:\(i):AlwaysConnected 0", plist: plist)
				// cfprefsd caches this domain; a direct plist edit can be ignored
				// or clobbered unless the cache is dropped. Restarting cfprefsd
				// forces the next launch to re-read from disk.
				let kill = Process()
				kill.executableURL = URL(fileURLWithPath: "/usr/bin/killall")
				kill.arguments = ["cfprefsd"]
				kill.standardOutput = Pipe()
				kill.standardError = Pipe()
				try? kill.run()
				kill.waitUntilExit()
				return
			}
		}
	}

	@discardableResult
	private func plistBuddy(_ command: String, plist: String) -> String? {
		let proc = Process()
		proc.executableURL = URL(fileURLWithPath: "/usr/libexec/PlistBuddy")
		proc.arguments = ["-c", command, plist]
		let pipe = Pipe()
		proc.standardOutput = pipe
		proc.standardError = Pipe()
		do {
			try proc.run()
			proc.waitUntilExit()
		} catch {
			return nil
		}
		let data = pipe.fileHandleForReading.readDataToEndOfFile()
		return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
	}

	private func plistBuddyString(_ command: String, plist: String) -> String? {
		guard let out = plistBuddy(command, plist: plist), !out.contains("Does Not Exist"), !out.isEmpty else { return nil }
		return out
	}

	// Counts the elements of the Services array by probing indices (PlistBuddy has
	// no direct count for an array via one command that returns an int cleanly).
	private func plistBuddyInt(_ command: String, plist: String) -> Int? {
		// `Print :Services` prints the whole array; count "Identifier =" entries.
		guard let out = plistBuddy(command, plist: plist) else { return nil }
		return out.components(separatedBy: "Identifier =").count - 1
	}

	// Runs `vpnutil status <name>` and returns the reported status word
	// (e.g. "Connected", "Disconnected", "Connecting"), or "" on failure.
	private func vpnStatus(vpnutil: String, name: String) -> String {
		let proc = Process()
		proc.executableURL = URL(fileURLWithPath: vpnutil)
		proc.arguments = ["status", name]
		let pipe = Pipe()
		proc.standardOutput = pipe
		proc.standardError = Pipe()
		do {
			try proc.run()
			proc.waitUntilExit()
		} catch {
			return ""
		}
		let data = pipe.fileHandleForReading.readDataToEndOfFile()
		let out = String(data: data, encoding: .utf8) ?? ""
		// Output form: "<name> <Status>"
		for word in ["Connected", "Disconnecting", "Disconnected", "Connecting", "Invalid"] {
			if out.contains(word) { return word }
		}
		return out.trimmingCharacters(in: .whitespacesAndNewlines)
	}

	// Polls vpnutil until the VPN reaches `desired`, tolerating transitional
	// states. Returns the last observed status.
	private func waitForVPNStatus(vpnutil: String, name: String, desired: String, timeout: TimeInterval) -> String {
		let deadline = Date().addingTimeInterval(timeout)
		var last = ""
		while Date() < deadline {
			last = vpnStatus(vpnutil: vpnutil, name: name)
			if last == desired { return last }
			usleep(1_500_000)
		}
		return last
	}
}
