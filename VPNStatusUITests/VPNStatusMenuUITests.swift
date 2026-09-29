//
//  VPNStatusMenuUITests.swift
//  VPNStatusUITests
//
//  Real end-to-end UI tests: launch the actual VPNStatus menu-bar app, open its
//  real status-item menu, read the real rows, activate real rows, and observe
//  the real VPN state change and the real app termination.
//
//  Two facts about automating an NSStatusItem menu on macOS drive this design:
//
//  1. READING works. Once the status item is clicked, XCUITest can see the
//     menu's rows and read their stable identifiers and titles. The app sets
//     these identifiers in AppDelegate.m:
//        service.action.<UUID>  Connect/Disconnect <name>
//        static.settings        Settings…
//        static.quit            Quit VPNStatus
//
//  2. CLICKING does NOT work. A popped-up status-item menu exposes its rows with
//     zero-size, non-hittable frames; XCUITest's click()/hover() on a row hangs
//     ~60s waiting for a "menu open" notification that never fires, coordinate
//     clicks don't land, keyboard events don't route to the tracking menu, and
//     raw AXUIElementPerformAction requires Accessibility TCC trust the transient
//     test runner does not have.
//
//     So to activate a row we ask the app (launched with UITEST_AUTOMATION=1) to
//     perform the row's action by identifier via a distributed notification. The
//     app calls -[NSMenu performActionForItemAtIndex:], which dispatches the row's
//     real target/action — the exact code path a user click triggers
//     (connectService:/disconnectService:/doQuit:). The menu CONTENTS that we act
//     on are the ones XCUITest actually read from the live menu.
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
	// title is Connect/Disconnect/Connecting/Disconnecting <name>. The service
	// name is carried in the action row's own title (there is no separate name
	// label row any more).
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
			title.hasPrefix("Connecting ") || title.hasPrefix("Disconnecting ")
		XCTAssertTrue(looksLikeServiceRow,
					  "Service action row should read Connect/Disconnect/Connecting/Disconnecting <name>, got: \(title)")

		dismissMenu()
	}

	// End-to-end connect/disconnect: activate the service action row (the real
	// NSMenuItem action, exactly what a click dispatches) and verify the real VPN
	// transitions to the opposite state, then activate again and verify it returns
	// to the original state.
	//
	// We confirm the *effect* (the real VPN's connection state) via the vpnutil
	// CLI, which reads the same ne_session status the menu reflects. We do not
	// re-open the status menu to read the new title, because XCUITest can only
	// see a popped-up NSStatusItem menu on the first open per session: after the
	// first open/close cycle the app's statusItems query returns empty (the app
	// keeps running and functioning — verified by appState — but XCUITest can no
	// longer see the status item). Reading the live VPN state is a stronger
	// end-to-end assertion than re-reading the menu title anyway.
	func testClickingServiceTogglesConnection() throws {
		try openStatusMenu()

		guard let actionID = serviceActionIdentifier() else {
			dismissMenu()
			throw XCTSkip("No VPN service configured on this machine; skipping connect/disconnect test.")
		}
		let uuid = actionID.replacingOccurrences(of: "service.action.", with: "")
		let startTitle = statusItem().menuItems[actionID].title
		guard startTitle.hasPrefix("Connect ") || startTitle.hasPrefix("Disconnect ") else {
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

	// A connecting service renders a custom two-label row: the full "Connecting
	// <name>..." title on the left and a grey "cancel" on the right. This asserts
	// — reading the labels' rendered contents through XCUITest accessibility (by
	// the identifiers set on the labels), NOT by any internal state — that the
	// FULL title text is shown (never truncated) and the trailing text is exactly
	// "cancel". Skips (does not fail) when no service is currently Connecting.
	func testConnectingRowShowsFullTitleAndCancel() throws {
		let item = try openStatusMenu()

		// Find a connecting service row by its menu-item title.
		let rows = item.menuItems.allElementsBoundByIndex.filter {
			$0.identifier.hasPrefix("service.action.") && !$0.identifier.hasSuffix(".sep")
		}
		guard let connectingRow = rows.first(where: { $0.title.hasPrefix("Connecting ") }) else {
			dismissMenu()
			throw XCTSkip("No service is currently Connecting; start a slow/unreachable VPN to exercise this row.")
		}

		// The expected full title is the row's own menu-item title.
		let expectedTitle = connectingRow.title
		XCTAssertTrue(expectedTitle.hasSuffix("..."),
					  "Connecting title should end with '...', got: \(expectedTitle)")

		// Read the two labels' rendered contents via accessibility identifiers.
		let primary = item.staticTexts["menuitem.primary"]
		let secondary = item.staticTexts["menuitem.secondary"]
		XCTAssertTrue(primary.waitForExistence(timeout: 3),
					  "Connecting row should expose a 'menuitem.primary' label")
		XCTAssertTrue(secondary.waitForExistence(timeout: 3),
					  "Connecting row should expose a 'menuitem.secondary' label")

		let shownTitle = (primary.value as? String) ?? primary.label
		let shownTrailing = (secondary.value as? String) ?? secondary.label

		// The rendered primary label must be the ENTIRE title — no truncation.
		XCTAssertEqual(shownTitle, expectedTitle,
					   "Primary label must show the full title with no truncation. expected='\(expectedTitle)' shown='\(shownTitle)'")
		XCTAssertFalse(shownTitle.contains("\u{2026}"),
					   "Primary label must not contain an ellipsis character (visual truncation): \(shownTitle)")
		XCTAssertEqual(shownTrailing, "cancel",
					   "Secondary label must show exactly 'cancel', got: \(shownTrailing)")

		dismissMenu()
	}

	// Diagnostic: dumps the REAL open-menu geometry and rendered label contents
	// for every readable row. Kept for tuning the custom row's layout; run it
	// manually. Reads only external accessibility (frames + label values).
	func testDumpOpenMenuMetrics() throws {
		let item = try openStatusMenu()

		// Wait for the custom row's label to actually render before reading/shooting.
		let primary = item.staticTexts["menuitem.primary"]
		_ = primary.waitForExistence(timeout: 5)
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
