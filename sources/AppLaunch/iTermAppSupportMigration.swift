//
//  iTermAppSupportMigration.swift
//  iTerm2
//
//  A build whose executable is not named iTerm2 (CryTerm) gets its own
//  Application Support folder, so it no longer sees the scripts, dynamic
//  profiles, fonts, and ssh_config the user keeps in iTerm2's. On first launch
//  this scans iTerm2's folder and offers to copy those into this app's folder.
//  It copies, never moves, and never overwrites anything already present.
//

import AppKit

@objc(iTermAppSupportMigration)
class AppSupportMigration: NSObject {
    // NoSync: this records a one-time prompt, not a setting.
    private static let offeredKey = "NoSyncDidOfferITerm2AppSupportMigration"

    // User-authored content only. Sockets, session daemons (iTermServer-*),
    // SavedState, the AI chat database, and the Python runtime belong to the
    // running iTerm2 and must not be shared or duplicated.
    private static let itemNames = ["Scripts", "DynamicProfiles", "Fonts", "ssh_config"]

    private struct Copy {
        var source: URL
        var destination: URL
    }

    @objc static func offerIfNeeded() {
        // Instances run under -suite are development or test instances.
        guard iTermUserDefaults.customSuiteName() == nil else {
            return
        }
        let userDefaults = iTermUserDefaults.userDefaults()
        guard !userDefaults.bool(forKey: offeredKey) else {
            return
        }
        let fileManager = FileManager.default
        guard let destinationPath = fileManager.applicationSupportDirectory() else {
            return
        }
        let destinationRoot = URL(fileURLWithPath: destinationPath).standardizedFileURL
        guard let base = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            return
        }
        let sourceRoot = base.appendingPathComponent("iTerm2").standardizedFileURL
        // A build that is itself named iTerm2 already uses this folder.
        guard sourceRoot.path != destinationRoot.path else {
            return
        }
        let copies = plannedCopies(from: sourceRoot, to: destinationRoot)
        DLog("App Support migration: \(copies.count) item(s) from \(sourceRoot.path) to \(destinationRoot.path)")
        guard !copies.isEmpty else {
            userDefaults.set(true, forKey: offeredKey)
            return
        }

        let appName = Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String ?? "CryTerm"
        let names = copies.map { relativeName($0.source, root: sourceRoot) }
        let list = names.prefix(12).map { "\u{2022} \($0)" }.joined(separator: "\n")
        let more = names.count > 12 ? "\n\u{2026}" : ""
        let title = String(localized: "AppSupportMigration.Message",
                           defaultValue: "\(appName) keeps its scripts, dynamic profiles, fonts, and SSH configuration separately from iTerm2. These items were found in iTerm2’s Application Support folder:\n\n\(list)\(more)\n\nCopy them to \(appName)? Nothing in iTerm2’s folder is changed, and nothing already in \(appName)’s folder is replaced.",
                           comment: "Shown on first launch of a renamed build of iTerm2. The first and later placeholders are the app name; the list placeholder is a bulleted list of file names.")
        let selection = iTermWarning.show(
            withTitle: title,
            actions: [String(localized: "AppSupportMigration.Copy", defaultValue: "Copy", comment: "Button that copies files from iTerm2’s Application Support folder"),
                      String(localized: "AppSupportMigration.DontCopy", defaultValue: "Don’t Copy", comment: "Button that declines copying files from iTerm2’s Application Support folder")],
            accessory: nil,
            identifier: nil,
            silenceable: .kiTermWarningTypePersistent,
            heading: String(localized: "AppSupportMigration.Heading", defaultValue: "Copy Files from iTerm2?", comment: "Heading of the first-launch offer to copy files from iTerm2’s Application Support folder"),
            window: nil)
        userDefaults.set(true, forKey: offeredKey)
        guard selection == .kiTermWarningSelection0 else {
            DLog("App Support migration declined")
            return
        }
        let failures = perform(copies, sourceRoot: sourceRoot)
        if !failures.isEmpty {
            iTermWarning.show(
                withTitle: String(localized: "AppSupportMigration.Failed",
                                  defaultValue: "Some items could not be copied:\n\n\(failures.joined(separator: "\n"))",
                                  comment: "Shown when copying files from iTerm2’s Application Support folder partly fails; the placeholder lists the items and errors"),
                actions: [iTermLocalizedOK()],
                accessory: nil,
                identifier: nil,
                silenceable: .kiTermWarningTypePersistent,
                heading: String(localized: "AppSupportMigration.FailedHeading", defaultValue: "Copy Incomplete", comment: "Heading of the alert shown when copying files from iTerm2’s folder partly fails"),
                window: nil)
        }
    }

    // Each top-level item is merged one level deep: a directory that already
    // exists here gets only the children it lacks, so a user's own CryTerm
    // scripts are never replaced.
    private static func plannedCopies(from sourceRoot: URL, to destinationRoot: URL) -> [Copy] {
        let fileManager = FileManager.default
        var result = [Copy]()
        for name in itemNames {
            let source = sourceRoot.appendingPathComponent(name)
            let destination = destinationRoot.appendingPathComponent(name)
            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: source.path, isDirectory: &isDirectory) else {
                continue
            }
            guard fileManager.fileExists(atPath: destination.path) else {
                if !isDirectory.boolValue || !((try? fileManager.contentsOfDirectory(atPath: source.path))?.isEmpty ?? true) {
                    result.append(Copy(source: source, destination: destination))
                }
                continue
            }
            guard isDirectory.boolValue,
                  let children = try? fileManager.contentsOfDirectory(atPath: source.path) else {
                continue
            }
            for child in children.sorted() where child != ".DS_Store" {
                let childDestination = destination.appendingPathComponent(child)
                if !fileManager.fileExists(atPath: childDestination.path) {
                    result.append(Copy(source: source.appendingPathComponent(child),
                                       destination: childDestination))
                }
            }
        }
        return result
    }

    private static func perform(_ copies: [Copy], sourceRoot: URL) -> [String] {
        let fileManager = FileManager.default
        var failures = [String]()
        for copy in copies {
            do {
                try fileManager.createDirectory(at: copy.destination.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
                try fileManager.copyItem(at: copy.source, to: copy.destination)
                DLog("App Support migration copied \(copy.source.path) to \(copy.destination.path)")
            } catch {
                DLog("App Support migration failed for \(copy.source.path): \(error)")
                failures.append("\(relativeName(copy.source, root: sourceRoot)): \(error.localizedDescription)")
            }
        }
        return failures
    }

    private static func relativeName(_ url: URL, root: URL) -> String {
        let prefix = root.path + "/"
        return url.path.hasPrefix(prefix) ? String(url.path.dropFirst(prefix.count)) : url.lastPathComponent
    }
}
