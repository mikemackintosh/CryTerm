//
//  PythonPackageLock.swift
//  iTerm2
//
//  The hash-pinned package set iTerm2 installs into script environments (iterm2,
//  certifi, pyobjc and their dependencies), bundled as PythonLocks/python.lock and
//  regenerated with tools/update_python_lock.sh. Installing with --require-hashes
//  means uv installs exactly the files recorded there and nothing PyPI serves later.
//
//  The lock is universal: one file for every Python version, with environment
//  markers (python_full_version, platform_release) that uv evaluates at install time.
//

import Foundation

enum PythonPackageLock {
    static let directoryName = "PythonLocks"

    struct Requirement: Equatable {
        let pin: String      // "name==version"
        let marker: String?  // e.g. "python_full_version >= '3.11'", or nil

        var name: String {
            return pin.components(separatedBy: "==").first ?? pin
        }

        // The requirement line as pip reads it, marker included.
        var line: String {
            guard let marker else {
                return pin
            }
            return "\(pin) ; \(marker)"
        }
    }

    // Path to the bundled lock, or nil if it is missing (a damaged app bundle).
    static func path(bundle: Bundle = .main) -> String? {
        return bundle.path(forResource: "python", ofType: "lock", inDirectory: directoryName)
    }

    // The requirement lines in a lock, without hashes or comments.
    static func requirements(inLockContents contents: String) -> [Requirement] {
        return contents.components(separatedBy: .newlines).compactMap { line in
            guard let first = line.first, first.isLetter || first.isNumber else {
                // Comments, blank lines, and indented hash/continuation lines.
                return nil
            }
            var text = line.trimmingCharacters(in: .whitespaces)
            if text.hasSuffix("\\") {
                text = String(text.dropLast()).trimmingCharacters(in: .whitespaces)
            }
            let parts = text.components(separatedBy: " ; ")
            let pin = parts[0].trimmingCharacters(in: .whitespaces)
            guard pin.contains("==") else {
                return nil
            }
            let marker = parts.count > 1 ? parts.dropFirst().joined(separator: " ; ") : nil
            return Requirement(pin: pin, marker: marker)
        }
    }

    static func requirements(inLockAt path: String) -> [Requirement] {
        guard let contents = try? String(contentsOfFile: path, encoding: .utf8) else {
            return []
        }
        return requirements(inLockContents: contents)
    }

    // The pins for `names` (case-insensitive) that apply to a Python minor such as
    // "3.12", in lock order. Only for showing the user what will be installed; uv
    // itself evaluates the full markers when installing.
    static func pins(named names: [String], forPythonMinor minor: String, inLockAt path: String) -> [String] {
        let wanted = Set(names.map { $0.lowercased() })
        return requirements(inLockAt: path)
            .filter { wanted.contains($0.name.lowercased()) && appliesTo(pythonMinor: minor, marker: $0.marker) }
            .map(\.pin)
    }

    // Whether a marker's python_full_version clauses admit a Python minor. Clauses on
    // other variables (platform_release, sys_platform) count as true: this decides
    // only which pins to display.
    static func appliesTo(pythonMinor minor: String, marker: String?) -> Bool {
        guard let marker else {
            return true
        }
        for clause in marker.components(separatedBy: " and ") {
            let words = clause.trimmingCharacters(in: CharacterSet(charactersIn: " ()"))
                .components(separatedBy: " ")
            guard words.count == 3, words[0] == "python_full_version" || words[0] == "python_version" else {
                continue
            }
            let op = words[1]
            let value = words[2].trimmingCharacters(in: CharacterSet(charactersIn: "'\""))
            if !satisfies(minor: minor, op: op, value: value) {
                return false
            }
        }
        return true
    }

    private static func satisfies(minor: String, op: String, value: String) -> Bool {
        if value.hasSuffix(".*") {
            let prefix = String(value.dropLast(2))
            let matches = (minor == prefix)
            return op == "!=" ? !matches : matches
        }
        // Compare against the first release of the minor (e.g. 3.12 as 3.12.0).
        let order = iTermDottedVersion.compare(minor + ".0", value)
        switch op {
        case "<": return order == .orderedAscending
        case "<=": return order != .orderedDescending
        case ">": return order == .orderedDescending
        case ">=": return order != .orderedAscending
        case "==": return order == .orderedSame
        case "!=": return order != .orderedSame
        default: return true
        }
    }

    // Writes the lock's pins, markers kept and hashes dropped, as a constraints file,
    // so a script's own dependencies can't replace a hash-verified package with a
    // different version. Returns the file's path.
    static func writeConstraints(forLockAt lockPath: String, in directory: String) throws -> String {
        let constraints = requirements(inLockAt: lockPath).map(\.line).joined(separator: "\n") + "\n"
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        let path = (directory as NSString).appendingPathComponent("constraints-\(UUID().uuidString).txt")
        try constraints.write(toFile: path, atomically: true, encoding: .utf8)
        return path
    }

    // The error when the bundled lock is missing. Installing unpinned instead would
    // defeat the point, so this fails closed.
    static func missingLockError() -> NSError {
        return NSError(domain: "com.iterm2.python-lock",
                       code: 1,
                       userInfo: [NSLocalizedDescriptionKey: String(
                        localized: "PythonPackageLock.Missing",
                        defaultValue: "iTerm2’s list of verified Python packages is missing, so it won’t install any. Reinstalling iTerm2 restores it.",
                        comment: "Error when the bundled hash-pinned Python package lock file cannot be found")])
    }
}
