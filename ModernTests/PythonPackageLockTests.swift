//
//  PythonPackageLockTests.swift
//  ModernTests
//
//  The bundled hash-pinned lock and the parsing iTerm2 does on it. If someone
//  regenerates the lock without hashes or markers, these fail.
//

import XCTest
@testable import iTerm2SharedARC

final class PythonPackageLockTests: XCTestCase {
    private let sample = """
    certifi==2026.10.23 \\
        --hash=sha256:aaaa \\
        --hash=sha256:bbbb
        # via -r tmp/python-lock/requirements.in
    iterm2==2.30 \\
        --hash=sha256:cccc
    pyobjc==11.1 ; python_full_version == '3.9.*' \\
        --hash=sha256:dddd
    pyobjc==13.0 ; python_full_version >= '3.11' \\
        --hash=sha256:eeee
    pyobjc-framework-libdispatch==13.0 ; python_full_version >= '3.11' and platform_release >= '12.0' \\
        --hash=sha256:ffff
        # via pyobjc

    """

    func testRequirementsKeepMarkersAndSkipHashes() {
        XCTAssertEqual(PythonPackageLock.requirements(inLockContents: sample).map(\.line), [
            "certifi==2026.10.23",
            "iterm2==2.30",
            "pyobjc==11.1 ; python_full_version == '3.9.*'",
            "pyobjc==13.0 ; python_full_version >= '3.11'",
            "pyobjc-framework-libdispatch==13.0 ; python_full_version >= '3.11' and platform_release >= '12.0'",
        ])
    }

    func testMarkerEvaluationForDisplay() {
        XCTAssertTrue(PythonPackageLock.appliesTo(pythonMinor: "3.9", marker: "python_full_version == '3.9.*'"))
        XCTAssertFalse(PythonPackageLock.appliesTo(pythonMinor: "3.10", marker: "python_full_version == '3.9.*'"))
        XCTAssertTrue(PythonPackageLock.appliesTo(pythonMinor: "3.11", marker: "python_full_version >= '3.11'"))
        XCTAssertFalse(PythonPackageLock.appliesTo(pythonMinor: "3.10", marker: "python_full_version >= '3.11'"))
        XCTAssertTrue(PythonPackageLock.appliesTo(pythonMinor: "3.8", marker: "python_full_version < '3.9'"))
        XCTAssertFalse(PythonPackageLock.appliesTo(pythonMinor: "3.9", marker: "python_full_version < '3.9'"))
        // Non-Python clauses don't hide a pin from display.
        XCTAssertTrue(PythonPackageLock.appliesTo(pythonMinor: "3.12",
                                                  marker: "python_full_version >= '3.11' and platform_release >= '12.0'"))
        XCTAssertTrue(PythonPackageLock.appliesTo(pythonMinor: "3.12", marker: nil))
    }

    func testPinsForAPythonVersionAndConstraints() throws {
        let directory = NSTemporaryDirectory() + "PythonPackageLockTests-\(UUID().uuidString)"
        defer { try? FileManager.default.removeItem(atPath: directory) }
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        let lockPath = (directory as NSString).appendingPathComponent("python.lock")
        try sample.write(toFile: lockPath, atomically: true, encoding: .utf8)

        XCTAssertEqual(PythonPackageLock.pins(named: ["iterm2", "pyobjc"], forPythonMinor: "3.12", inLockAt: lockPath),
                       ["iterm2==2.30", "pyobjc==13.0"])
        XCTAssertEqual(PythonPackageLock.pins(named: ["iterm2", "pyobjc"], forPythonMinor: "3.9", inLockAt: lockPath),
                       ["iterm2==2.30", "pyobjc==11.1"])

        // Constraints keep markers so uv applies the right pin per Python version.
        let constraintsPath = try PythonPackageLock.writeConstraints(forLockAt: lockPath, in: directory)
        let constraints = try String(contentsOfFile: constraintsPath, encoding: .utf8)
        XCTAssertTrue(constraints.contains("pyobjc==13.0 ; python_full_version >= '3.11'\n"))
        XCTAssertFalse(constraints.contains("--hash"))
    }

    // Every requirement in the bundled lock is pinned with == and carries at least one
    // hash; otherwise --require-hashes refuses it, or a hand edit could slip an
    // unpinned package in. Each always-installed package must resolve for every
    // Python version scripts can use, and pyobjc's Darwin-gated frameworks must be
    // present (they were silently dropped when resolving for a fixed target triple).
    func testBundledLockIsFullyPinnedAndHashed() throws {
        let path = try XCTUnwrap(PythonPackageLock.path())
        let contents = try String(contentsOfFile: path, encoding: .utf8)
        var current: String?
        var hashes = [String: Int]()
        for line in contents.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if let first = line.first, first.isLetter || first.isNumber {
                current = line
                hashes[line] = 0
            } else if trimmed.hasPrefix("--hash=sha256:"), let current {
                hashes[current, default: 0] += 1
            }
        }
        XCTAssertFalse(hashes.isEmpty)
        for (line, count) in hashes {
            XCTAssertTrue(line.contains("=="), "Unpinned requirement: \(line)")
            XCTAssertGreaterThan(count, 0, "No hash for: \(line)")
        }
        for minor in ["3.8", "3.9", "3.10", "3.11", "3.12", "3.13", "3.14"] {
            for package in iTermUvProvisioner.alwaysInstalledPackages {
                XCTAssertEqual(PythonPackageLock.pins(named: [package], forPythonMinor: minor, inLockAt: path).count, 1,
                               "\(package) should have exactly one pin for Python \(minor)")
            }
        }
        XCTAssertTrue(PythonPackageLock.requirements(inLockAt: path).contains {
            $0.name == "pyobjc-framework-libdispatch" && ($0.marker ?? "").contains("platform_release")
        }, "Darwin-gated pyobjc frameworks are missing from the lock")
    }
}
