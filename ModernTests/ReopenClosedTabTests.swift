//
//  ReopenClosedTabTests.swift
//  ModernTests
//
//  Undo Close (⌘⇧T) brings back a closed tab even after its undo window ran
//  out without an archive, the way a browser reopens a closed tab: a new
//  session in the same place, from the closed tab's arrangement.
//

import XCTest
@testable import iTerm2SharedARC

final class ReopenClosedTabTests: XCTestCase {
    private var fixture: TerminalWindowTestFixture!
    private let controller = iTermController.sharedInstance()!

    override func setUpWithError() throws {
        try super.setUpWithError()
        try OnscreenTestGate.skipUnlessEnabled()
        while controller.popRestorableSession() != nil {}
        fixture = TerminalWindowTestFixture()
    }

    override func tearDown() {
        fixture?.close()
        fixture = nil
        while controller.popRestorableSession() != nil {}
        super.tearDown()
    }

    func testClosedTabReopensAfterUndoWindowRunsOut() throws {
        let terminal = fixture.terminal
        let closed = fixture.addTab()
        let following = fixture.addTab()
        XCTAssertEqual(terminal.numberOfTabs(), 3)

        terminal.close(try XCTUnwrap(terminal.tab(for: closed)))
        XCTAssertEqual(terminal.numberOfTabs(), 2)
        // The undo window runs out. The default profile doesn't archive.
        closed.hardStop()
        XCTAssertFalse(controller.hasRestorableSessionInUndoWindow)
        XCTAssertTrue(controller.hasRestorableSession)

        let delegate = try XCTUnwrap(NSApp.delegate as? iTermApplicationDelegate)
        // The Shell > Undo Close menu action, which ⌘⇧T triggers.
        _ = delegate.perform(NSSelectorFromString("undoCloseSession:"), with: nil)

        XCTAssertEqual(terminal.numberOfTabs(), 3)
        // Back where it was: after the first tab, before the one that followed it.
        let tabs = try XCTUnwrap(terminal.tabs())
        let reopened = try XCTUnwrap(tabs[1].sessions().first as? PTYSession)
        XCTAssertFalse(reopened === closed, "the closed session was freed; a new one takes its place")
        XCTAssertTrue(try XCTUnwrap(tabs[2].sessions().first as? PTYSession) === following)
        XCTAssertFalse(controller.hasRestorableSession)
    }
}
