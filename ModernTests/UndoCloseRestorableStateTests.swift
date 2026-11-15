//
//  UndoCloseRestorableStateTests.swift
//  ModernTests
//
//  Undo close entries whose sessions were all archived are saved in app
//  restorable state so undo close works after a restart.
//

import XCTest
@testable import iTerm2SharedARC

final class UndoCloseRestorableStateTests: XCTestCase {
    private let controller = iTermController.sharedInstance()!

    override func setUp() {
        super.setUp()
        drain()
    }

    override func tearDown() {
        drain()
        super.tearDown()
    }

    private func drain() {
        while controller.popRestorableSession() != nil {}
    }

    private func archivedEntry(_ path: String) -> iTermRestorableSession {
        let entry = iTermRestorableSession()
        entry.sessions = []
        entry.group = .kiTermRestorableSessionGroupTab
        entry.terminalGuid = "no-such-window"
        entry.arrangement = ["Root": [String: Any]()]
        entry.archivePathsBySessionGUID = ["guid-" + path: path]
        return entry
    }

    func testRoundTrip() throws {
        controller.add(archivedEntry("/a"))
        let state = controller.undoCloseRestorableState() ?? []
        XCTAssertEqual(state.count, 1)
        drain()

        controller.restoreUndoClose(fromState: state)
        let restored = try XCTUnwrap(controller.popRestorableSession())
        XCTAssertEqual(restored.group, .kiTermRestorableSessionGroupTab)
        XCTAssertEqual(restored.terminalGuid, "no-such-window")
        XCTAssertEqual(restored.archivePathsBySessionGUID, ["guid-/a": "/a"])
        XCTAssertEqual(restored.sessions.count, 0)
        // The tab is gone, so it has no unique ID.
        XCTAssertEqual(restored.tabUniqueId, 0)
        XCTAssertNil(restored.tabGUID)
        XCTAssertNil(controller.popRestorableSession())
    }

    // Entries restored at launch keep their tab GUIDs until undone, since
    // windows may not have been restored yet, and save them again unchanged.
    func testTabGUIDsSurviveAnotherSave() throws {
        let entry = archivedEntry("/a")
        controller.add(entry)
        var state = controller.undoCloseRestorableState() ?? []
        drain()
        state[0]["tabGUID"] = "tab-guid"
        state[0]["predecessorTabGUIDs"] = ["p1", "p2"]

        controller.restoreUndoClose(fromState: state)
        let resaved = controller.undoCloseRestorableState() ?? []
        XCTAssertEqual(resaved.first?["tabGUID"] as? String, "tab-guid")
        XCTAssertEqual(resaved.first?["predecessorTabGUIDs"] as? [String], ["p1", "p2"])
    }

    func testKeepsMostRecentTwenty() {
        for i in 0..<25 {
            controller.add(archivedEntry("/\(i)"))
        }
        let state = controller.undoCloseRestorableState() ?? []
        XCTAssertEqual(state.count, 20)
        let firstPaths = state.first?["archivePathsBySessionGUID"] as? [String: String]
        let lastPaths = state.last?["archivePathsBySessionGUID"] as? [String: String]
        XCTAssertEqual(firstPaths?.values.first, "/5")
        XCTAssertEqual(lastPaths?.values.first, "/24")
    }

    func testRestoredEntriesGoBelowNewerOnes() throws {
        controller.add(archivedEntry("/old"))
        let state = controller.undoCloseRestorableState() ?? []
        drain()

        controller.add(archivedEntry("/new"))
        controller.restoreUndoClose(fromState: state)
        XCTAssertEqual(try XCTUnwrap(controller.popRestorableSession()).archivePathsBySessionGUID.values.first, "/new")
        XCTAssertEqual(try XCTUnwrap(controller.popRestorableSession()).archivePathsBySessionGUID.values.first, "/old")
    }

    func testEntriesWithoutArchivesAreNotSaved() {
        let entry = archivedEntry("/a")
        entry.archivePathsBySessionGUID = [:]
        controller.add(entry)
        XCTAssertEqual(controller.undoCloseRestorableState()?.count ?? 0, 0)
    }

    // MARK: - Reopening closed tabs after the undo window

    // A tab arrangement with one pane for the session with this GUID.
    private func tabArrangement(sessionGUID: String) -> [AnyHashable: Any] {
        return [TAB_ARRANGEMENT_ROOT: [TAB_ARRANGEMENT_VIEW_TYPE: VIEW_TYPE_SESSIONVIEW,
                                       TAB_ARRANGEMENT_SESSION: ["Session GUID": sessionGUID]] as [String: Any]]
    }

    private func liveEntry(_ session: PTYSession, arrangement: [AnyHashable: Any]) -> iTermRestorableSession {
        let entry = iTermRestorableSession()
        entry.sessions = [session]
        entry.group = .kiTermRestorableSessionGroupTab
        entry.terminalGuid = "no-such-window"
        entry.arrangement = arrangement
        return entry
    }

    func testExpiredSessionWithoutArchiveIsKeptToReopen() throws {
        let session = try XCTUnwrap(PTYSession(synthetic: false))
        let guid = try XCTUnwrap(session.guid)
        controller.add(liveEntry(session, arrangement: tabArrangement(sessionGUID: guid)))
        XCTAssertTrue(controller.hasRestorableSessionInUndoWindow)

        controller.removeSession(fromRestorableSessions: session, archivePath: nil)

        XCTAssertFalse(controller.hasRestorableSessionInUndoWindow)
        let entry = try XCTUnwrap(controller.popRestorableSession())
        XCTAssertEqual(entry.sessions.count, 0)
        XCTAssertEqual(entry.reopenSessionGUIDs, [guid])
        XCTAssertEqual(entry.archivePathsBySessionGUID?.count ?? 0, 0)
    }

    func testExpiredSessionMissingFromArrangementIsForgotten() throws {
        let session = try XCTUnwrap(PTYSession(synthetic: false))
        controller.add(liveEntry(session, arrangement: tabArrangement(sessionGUID: "someone-else")))
        controller.removeSession(fromRestorableSessions: session, archivePath: nil)
        XCTAssertNil(controller.popRestorableSession())
    }

    func testReopenEntryRoundTrip() throws {
        let entry = archivedEntry("/a")
        entry.archivePathsBySessionGUID = [:]
        entry.reopenSessionGUIDs = ["g"]
        controller.add(entry)
        let state = controller.undoCloseRestorableState() ?? []
        XCTAssertEqual(state.count, 1)
        drain()

        controller.restoreUndoClose(fromState: state)
        let restored = try XCTUnwrap(controller.popRestorableSession())
        XCTAssertEqual(restored.reopenSessionGUIDs, ["g"])
        XCTAssertEqual(restored.archivePathsBySessionGUID?.count ?? 0, 0)
    }

    // Closed entries are capped like a browser’s recently closed tabs.
    func testClosedEntriesAreCapped() throws {
        for i in 0..<25 {
            controller.add(archivedEntry("/\(i)"))
        }
        let session = try XCTUnwrap(PTYSession(synthetic: false))
        controller.add(liveEntry(session, arrangement: tabArrangement(sessionGUID: try XCTUnwrap(session.guid))))
        controller.removeSession(fromRestorableSessions: session, archivePath: nil)

        var count = 0
        var newest: iTermRestorableSession?
        while let entry = controller.popRestorableSession() {
            newest = newest ?? entry
            count += 1
        }
        XCTAssertEqual(count, 20)
        XCTAssertEqual(newest?.reopenSessionGUIDs?.count, 1)
    }

    func testMalformedStateIsIgnored() {
        controller.restoreUndoClose(fromState: [["group": 99], ["restorableSession": "x"]])
        XCTAssertNil(controller.popRestorableSession())
    }
}
