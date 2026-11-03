//
//  SettingsWindowReuseTests.swift
//  ModernTests
//
//  Settings used to throw its window away on close, so every ⌘, rebuilt
//  every tab from the nib and took seconds. It is now kept. Closing used to
//  unbind each tab's controls, so a kept window must stay wired up, and a
//  setting changed while it was closed must show when it reopens.
//

import AppKit
import XCTest
@testable import iTerm2SharedARC

final class SettingsWindowReuseTests: XCTestCase {
    private let key = kPreferenceKeyAlwaysOpenWindowAtStartup

    private func generalViewController(_ panel: PreferencePanel) throws -> iTermPreferencesBaseViewController {
        return try XCTUnwrap(panel.value(forKey: "generalPreferencesViewController") as? iTermPreferencesBaseViewController)
    }

    private func checkbox(for key: String, in viewController: iTermPreferencesBaseViewController) -> NSButton? {
        for case let control as NSView in viewController.keyMap.keyEnumerator().allObjects {
            if let info = viewController.keyMap.object(forKey: control) as? PreferenceInfo, info.key == key {
                return info.control as? NSButton
            }
        }
        return nil
    }

    // Closing defers part of its teardown to the next main-queue turn.
    private func drainMainQueue() {
        let drained = expectation(description: "main queue drained")
        DispatchQueue.main.async { drained.fulfill() }
        wait(for: [drained], timeout: 10)
    }

    private func openAndClose() throws -> PreferencePanel {
        let panel = PreferencePanel.sharedInstance()
        panel.run()
        try XCTUnwrap(panel.window).close()
        drainMainQueue()
        return panel
    }

    func testReopeningReturnsTheSameWindow() throws {
        let panel = try openAndClose()
        let window = panel.window
        XCTAssertTrue(PreferencePanel.sharedInstance() === panel)
        XCTAssertTrue(PreferencePanel.sharedInstance().window === window)
    }

    func testControlsStayBoundAfterClose() throws {
        let panel = try openAndClose()
        let general = try generalViewController(panel)
        XCTAssertNotNil(checkbox(for: key, in: general))
    }

    func testSettingChangedWhileClosedShowsOnReopen() throws {
        let original = iTermPreferences.bool(forKey: key)
        defer { iTermPreferences.setBool(original, forKey: key) }

        let panel = try openAndClose()
        iTermPreferences.setBool(!original, forKey: key)
        panel.run()
        defer { panel.window?.close() }

        let button = try XCTUnwrap(checkbox(for: key, in: try generalViewController(panel)))
        XCTAssertEqual(button.state, original ? .off : .on)
    }

    func testReopeningClearsAnOldSearch() throws {
        let panel = PreferencePanel.sharedInstance()
        panel.run()
        let field = try XCTUnwrap(panel.value(forKey: "searchField") as? NSSearchField)
        field.stringValue = "font"
        try XCTUnwrap(panel.window).close()
        drainMainQueue()
        panel.run()
        defer { panel.window?.close() }
        XCTAssertEqual(field.stringValue, "")
    }
}
