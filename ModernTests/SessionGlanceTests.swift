//
//  SessionGlanceTests.swift
//  ModernTests
//
//  The cockpit's per-session summary: which line counts as the last output,
//  how paths and elapsed times read, and the state a plain shell gets from
//  shell integration when the program reports none.
//

import XCTest
@testable import iTerm2SharedARC

final class SessionGlanceTests: XCTestCase {
    func testLastMeaningfulLineSkipsBlankAndDecorationLines() {
        let bottomUp = [
            "",
            "   ",
            "╰──────────────────╯",
            "│                  │",
            "-----",
            "  ready   on   http://localhost:5173  ",
            "older output",
        ]
        XCTAssertEqual(SessionGlance.lastMeaningfulLine(bottomUp: bottomUp),
                       "ready on http://localhost:5173")
    }

    func testLastMeaningfulLineIsNilWhenNothingQualifies() {
        XCTAssertNil(SessionGlance.lastMeaningfulLine(bottomUp: ["", "═══", " "]))
        XCTAssertNil(SessionGlance.lastMeaningfulLine(bottomUp: []))
    }

    func testLastMeaningfulLineIsTruncated() {
        let long = String(repeating: "x", count: SessionGlance.maximumLineLength + 50)
        let line = SessionGlance.lastMeaningfulLine(bottomUp: [long])
        XCTAssertEqual(line?.count, SessionGlance.maximumLineLength + 1)
        XCTAssertEqual(line?.hasSuffix("…"), true)
    }

    func testAbbreviatePath() {
        XCTAssertEqual(SessionGlance.abbreviate(path: "/Users/me/src/api", home: "/Users/me"), "~/src/api")
        XCTAssertEqual(SessionGlance.abbreviate(path: "/Users/me", home: "/Users/me/"), "~")
        // A sibling whose name starts with the home directory's isn't inside it.
        XCTAssertEqual(SessionGlance.abbreviate(path: "/Users/meg/src", home: "/Users/me"), "/Users/meg/src")
        XCTAssertEqual(SessionGlance.abbreviate(path: "/tmp", home: "/"), "/tmp")
    }

    func testFormatElapsed() {
        XCTAssertEqual(SessionGlance.formatElapsed(-5), "0s")
        XCTAssertEqual(SessionGlance.formatElapsed(45), "45s")
        XCTAssertEqual(SessionGlance.formatElapsed(3 * 60 + 59), "3m")
        XCTAssertEqual(SessionGlance.formatElapsed(2 * 3600), "2h")
        XCTAssertEqual(SessionGlance.formatElapsed(2 * 3600 + 5 * 60), "2h 5m")
        XCTAssertEqual(SessionGlance.formatElapsed(3 * 86400 + 4 * 3600), "3d 4h")
    }

    func testIsShell() {
        XCTAssertTrue(SessionGlance.isShell(job: "zsh"))
        XCTAssertTrue(SessionGlance.isShell(job: "-zsh"))
        XCTAssertTrue(SessionGlance.isShell(job: "/bin/bash"))
        XCTAssertFalse(SessionGlance.isShell(job: "vim"))
        XCTAssertFalse(SessionGlance.isShell(job: "claude"))
    }

    func testStateWithShellIntegration() {
        let start = Date(timeIntervalSince1970: 1000)
        XCTAssertEqual(SessionGlance.state(commandIsRunning: true, commandStart: start, exitCode: nil, foregroundJob: "make"),
                       .running(since: start))
        XCTAssertEqual(SessionGlance.state(commandIsRunning: false, commandStart: start, exitCode: 2, foregroundJob: "zsh"),
                       .failed(code: 2))
        XCTAssertEqual(SessionGlance.state(commandIsRunning: false, commandStart: start, exitCode: 0, foregroundJob: "zsh"),
                       .idle)
    }

    func testStateWithoutShellIntegrationFallsBackToTheForegroundJob() {
        XCTAssertEqual(SessionGlance.state(commandIsRunning: nil, commandStart: nil, exitCode: nil, foregroundJob: "vim"),
                       .running(since: nil))
        XCTAssertEqual(SessionGlance.state(commandIsRunning: nil, commandStart: nil, exitCode: nil, foregroundJob: "-zsh"),
                       .idle)
        XCTAssertEqual(SessionGlance.state(commandIsRunning: nil, commandStart: nil, exitCode: nil, foregroundJob: nil),
                       .idle)
    }

    func testSummary() {
        let now = Date(timeIntervalSince1970: 10_000)
        let running = SessionGlance(directory: "~/src/web", job: "npm run dev",
                                    state: .running(since: now.addingTimeInterval(-41 * 60)), lastLine: nil)
        XCTAssertEqual(running.summary(now: now), "~/src/web · npm run dev · 41m")

        let failed = SessionGlance(directory: "~/src/app", job: nil, state: .failed(code: 1), lastLine: nil)
        XCTAssertEqual(failed.summary(now: now), "~/src/app · exit 1")

        let empty = SessionGlance(directory: nil, job: nil, state: .idle, lastLine: "x")
        XCTAssertNil(empty.summary(now: now))
    }
}
