//
//  PythonInstallConsent.swift
//  iTerm2
//
//  The single gate in front of every Python package installation iTerm2 starts.
//  Nothing is fetched from PyPI (or a Python interpreter downloaded) until the user
//  has seen exactly what will be installed and agreed to it.
//

import AppKit

@objc(iTermPythonInstallConsent)
final class PythonInstallConsent: NSObject {
    // Replaceable so tests can answer without a modal. Called on the main thread.
    static var prompt: (_ packages: [String], _ pythonVersion: String) -> Bool = showPrompt

    // Asks the user to approve installing `packages` into a Python `pythonVersion`
    // environment. Blocks until answered. Safe to call from any thread except one the
    // main thread is synchronously waiting on (the provisioning queue never is).
    @objc(confirmInstallingPackages:pythonVersion:)
    static func confirm(packages: [String], pythonVersion: String) -> Bool {
        RLog("Asking to install \(packages) for Python \(pythonVersion)")
        let approved: Bool
        if Thread.isMainThread {
            approved = prompt(packages, pythonVersion)
        } else {
            var answer = false
            DispatchQueue.main.sync {
                answer = prompt(packages, pythonVersion)
            }
            approved = answer
        }
        RLog(approved ? "Python install approved" : "Python install declined")
        return approved
    }

    private static func showPrompt(packages: [String], pythonVersion: String) -> Bool {
        if TestHostIsolation.isTestHost(environment: ProcessInfo.processInfo.environment) {
            // A modal would hang an unattended run. Tests that exercise consent replace
            // `prompt`; the live harness runs installs it was asked to run.
            return true
        }
        // Localization unneeded: a bulleted list of package names.
        let list = packages.map { "• \($0)" }.joined(separator: "\n")
        let body = String(localized: "PythonInstallConsent.Body",
                          defaultValue: "iTerm2 is about to download Python \(pythonVersion) if it is not already installed, and install these packages from PyPI into it:\n\n\(list)\n\nNothing is installed unless you allow it.",
                          comment: "Body of the dialog asking before installing Python packages. First placeholder is a Python version such as 3.12; second is a bulleted list of package names, one per line")
        let selection = iTermWarning.show(
            withTitle: body,
            actions: [String(localized: "PythonInstallConsent.Install",
                             defaultValue: "Install",
                             comment: "Button that approves installing the listed Python packages"),
                      iTermLocalizedCancel()],
            actionMapping: nil,
            accessory: nil,
            identifier: nil,
            silenceable: .kiTermWarningTypePersistent,
            heading: String(localized: "PythonInstallConsent.Heading",
                            defaultValue: "Install Python Packages?",
                            comment: "Heading of the dialog asking before installing Python packages"),
            cancelLabel: iTermLocalizedCancel(),
            window: nil)
        return selection == .kiTermWarningSelection0
    }
}
