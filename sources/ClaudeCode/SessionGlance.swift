//
//  SessionGlance.swift
//  iTerm2SharedARC
//
//  What a session is doing, readable at a glance: where it is, what it's
//  running and for how long, whether its last command failed, and the last
//  thing it printed. The cockpit shows it on every session row and the
//  session overview captions each tile with it.
//
//  Programs that report their own status (Claude Code's hooks, OSC 21337,
//  OSC 7501) keep using it. The state here is a fallback for everything
//  else, derived from shell integration's command marks, so a plain shell
//  running `make` reads as Running instead of having no status at all.
//

import AppKit

struct SessionGlance: Equatable {
    enum State: Equatable {
        // A command is running. `since` is nil without shell integration,
        // when all we know is that the foreground job isn't the shell.
        case running(since: Date?)
        // The last command exited with a nonzero status.
        case failed(code: Int32)
        case idle
    }

    var directory: String?
    // The running command line, or the foreground job when it isn't the shell.
    var job: String?
    var state: State
    var lastLine: String?

    // MARK: - Presentation

    static var runningLabel: String {
        String(localized: "SessionGlance.Running", defaultValue: "Running", comment: "Status of a session whose shell is running a command")
    }
    static var errorLabel: String {
        String(localized: "SessionGlance.Error", defaultValue: "Error", comment: "Status of a session whose last command exited with a nonzero status")
    }
    static var idleLabel: String {
        String(localized: "SessionGlance.Idle", defaultValue: "Idle", comment: "Status of a session sitting at its shell prompt")
    }

    var statusText: String {
        switch state {
        case .running: return Self.runningLabel
        case .failed: return Self.errorLabel
        case .idle: return Self.idleLabel
        }
    }

    var statusColor: NSColor {
        switch state {
        case .running: return .systemBlue
        case .failed: return .systemRed
        case .idle: return .secondaryLabelColor
        }
    }

    // "~/src/api · npm run dev · 41m", or "~/src/app · exit 2".
    func summary(now: Date = Date()) -> String? {
        var parts: [String] = []
        if let directory, !directory.isEmpty {
            parts.append(directory)
        }
        if let job, !job.isEmpty {
            parts.append(job)
        }
        switch state {
        case .running(let since):
            if let since {
                parts.append(Self.formatElapsed(now.timeIntervalSince(since)))
            }
        case .failed(let code):
            parts.append(String(localized: "SessionGlance.ExitCode", defaultValue: "exit \(code)", comment: "Shown after a session’s directory when its last command failed; the number is the exit status"))
        case .idle:
            break
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    // Everything a type-to-filter search should match besides the title.
    var searchableText: String {
        return [directory, job, lastLine].compactMap { $0 }.joined(separator: "\n")
    }

    // MARK: - Pure helpers (unit-tested)

    static let maximumLineLength = 200
    // How far up from the cursor to look for a line worth showing.
    static let linesToScan = 40

    // The first line, scanning bottom-up, that has real text in it. Lines
    // that are blank or only box drawing and rules (a TUI's frame, a
    // separator) are skipped. Runs of whitespace collapse to one space.
    static func lastMeaningfulLine(bottomUp lines: [String]) -> String? {
        for line in lines {
            let collapsed = line.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
            guard !collapsed.isEmpty, !isDecoration(collapsed) else {
                continue
            }
            if collapsed.count > maximumLineLength {
                return String(collapsed.prefix(maximumLineLength)) + "…"
            }
            return collapsed
        }
        return nil
    }

    private static let decorationCharacters = CharacterSet(charactersIn: "-=_~|:.*·•>+#")
        .union(CharacterSet(charactersIn: "\u{2500}"..."\u{259F}"))  // box drawing, block elements
        .union(.whitespaces)

    static func isDecoration(_ line: String) -> Bool {
        return line.unicodeScalars.allSatisfy { decorationCharacters.contains($0) }
    }

    static func abbreviate(path: String, home: String) -> String {
        guard !home.isEmpty, home != "/" else {
            return path
        }
        let trimmedHome = home.hasSuffix("/") ? String(home.dropLast()) : home
        if path == trimmedHome {
            return "~"
        }
        if path.hasPrefix(trimmedHome + "/") {
            return "~" + path.dropFirst(trimmedHome.count)
        }
        return path
    }

    // 45s, 3m, 2h 5m, 3d 4h.
    static func formatElapsed(_ interval: TimeInterval) -> String {
        let seconds = max(0, Int(interval))
        if seconds < 60 {
            return "\(seconds)s"
        }
        let minutes = seconds / 60
        if minutes < 60 {
            return "\(minutes)m"
        }
        let hours = minutes / 60
        if hours < 24 {
            let rest = minutes % 60
            return rest == 0 ? "\(hours)h" : "\(hours)h \(rest)m"
        }
        let days = hours / 24
        let rest = hours % 24
        return rest == 0 ? "\(days)d" : "\(days)d \(rest)h"
    }

    private static let shells: Set<String> = ["sh", "bash", "zsh", "fish", "tcsh", "csh", "ksh", "dash", "nu", "xonsh", "login"]

    // Whether a foreground job name is just the shell (login shells show as "-zsh").
    static func isShell(job: String) -> Bool {
        var name = job
        if name.hasPrefix("-") {
            name.removeFirst()
        }
        return shells.contains((name as NSString).lastPathComponent.lowercased())
    }

    static func state(commandIsRunning: Bool?,
                      commandStart: Date?,
                      exitCode: Int32?,
                      foregroundJob: String?) -> State {
        if let commandIsRunning {
            // Shell integration knows exactly.
            if commandIsRunning {
                return .running(since: commandStart)
            }
            if let exitCode, exitCode != 0 {
                return .failed(code: exitCode)
            }
            return .idle
        }
        if let foregroundJob, !foregroundJob.isEmpty, !isShell(job: foregroundJob) {
            return .running(since: nil)
        }
        return .idle
    }
}

// MARK: - Reading a live session

extension SessionGlance {
    init(session: PTYSession) {
        let mark = session.screen.lastCommandMark()
        let commandIsRunning: Bool? = mark.map { $0.isRunning }
        let exitCode: Int32? = (mark?.hasCode == true) ? mark?.code : nil
        let foregroundJob = session.genericScope.value(forVariableName: iTermVariableKeySessionJob) as? String
        let state = Self.state(commandIsRunning: commandIsRunning,
                               commandStart: mark?.startDate,
                               exitCode: exitCode,
                               foregroundJob: foregroundJob)

        var job: String?
        if case .running = state {
            if mark?.isRunning == true, let command = mark?.firstLineOfCommand, !command.isEmpty {
                job = command
            } else {
                job = foregroundJob
            }
        } else if let foregroundJob, !Self.isShell(job: foregroundJob) {
            // No shell integration, or a command it doesn't know about.
            job = foregroundJob
        }

        self.init(directory: Self.displayDirectory(of: session),
                  job: job,
                  state: state,
                  lastLine: Self.lastOutputLine(of: session))
    }

    // The status a program reports for itself (Claude Code's hooks, OSC
    // 21337, OSC 7501), in the color it asked for. nil when it reports none.
    static func reportedStatus(of session: PTYSession) -> (text: String, color: NSColor)? {
        guard let status = session.tabStatus,
              let raw = status.statusText?.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty else {
            return nil
        }
        let color: NSColor
        if status.hasStatusTextColor {
            color = nsColor(from: status.statusTextColor)
        } else if status.hasIndicator {
            color = nsColor(from: status.indicatorColor)
        } else {
            color = .secondaryLabelColor
        }
        return (raw, color)
    }

    // The reported status when there is one, else the derived state.
    func displayStatus(of session: PTYSession) -> (text: String, color: NSColor) {
        return Self.reportedStatus(of: session) ?? (statusText, statusColor)
    }

    // Sort order for a status, matching the Session Status tool's priority
    // list (lower first). A command running in a plain shell sorts with
    // programs that report themselves as working.
    static func priority(forStatus status: String) -> Int {
        if status == runningLabel {
            return StatusPrioritySettings.shared.priority(for: "working")
        }
        return StatusPrioritySettings.shared.priority(for: status)
    }

    private static func nsColor(from c: iTermSRGBColor) -> NSColor {
        return NSColor(srgbRed: CGFloat(c.r), green: CGFloat(c.g), blue: CGFloat(c.b), alpha: 1)
    }

    private static func displayDirectory(of session: PTYSession) -> String? {
        guard let path = session.genericScope.value(forVariableName: iTermVariableKeySessionPath) as? String, !path.isEmpty else {
            return nil
        }
        let remote = session.screen.lastRemoteHost()
        if let remote, remote.localityState == .remote, let host = remote.hostname, !host.isEmpty {
            // A remote path can't be shortened against our own home.
            return "\(host):\(path)"
        }
        return abbreviate(path: path, home: NSHomeDirectory())
    }

    // The last line with real text above the cursor. At a shell prompt the
    // prompt itself is skipped, so this is the end of the last command's
    // output rather than "~ $".
    private static func lastOutputLine(of session: PTYSession) -> String? {
        let screen: VT100Screen = session.screen
        let numberOfLines = Int(screen.numberOfLines())
        let height = Int(screen.height())
        guard numberOfLines > 0, height > 0 else {
            return nil
        }
        let cursorLine = numberOfLines - height + Int(screen.cursorY()) - 1
        var start = cursorLine
        if session.isAtShellPrompt, let prompt = screen.lastPromptMark() {
            let promptLine = Int(prompt.promptRange.start.y - screen.totalScrollbackOverflow())
            if promptLine >= 0 && promptLine <= cursorLine {
                start = promptLine - 1
            }
        }
        start = min(start, numberOfLines - 1)
        guard start >= 0 else {
            return nil
        }
        let end = max(0, start - linesToScan + 1)
        let bottomUp = stride(from: start, through: end, by: -1).map {
            screen.screenCharArray(forLine: Int32($0)).stringValue
        }
        return lastMeaningfulLine(bottomUp: bottomUp)
    }
}
