import Foundation
import CoreGraphics
import Darwin

enum Watchdog {
    static let vdscreen = "/opt/homebrew/bin/vdscreen"
    static let targetWidth = 6016
    static let targetHeight = 3384

    static func hasTargetDisplay() -> Bool {
        var count: UInt32 = 0
        guard CGGetActiveDisplayList(0, nil, &count) == .success, count > 0 else { return false }
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetActiveDisplayList(count, &ids, &count) == .success else { return false }
        for id in ids {
            if let m = CGDisplayCopyDisplayMode(id), m.pixelWidth == targetWidth, m.pixelHeight == targetHeight {
                return true
            }
        }
        return false
    }

    static func vdscreenStatus() -> String? {
        guard FileManager.default.isExecutableFile(atPath: vdscreen) else { return nil }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: vdscreen)
        p.arguments = ["status"]
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = "/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin"
        p.environment = env
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        do {
            try p.run()
            p.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
        } catch {
            return nil
        }
    }

    static func isHealthy() -> Bool {
        // The CLI asks launchd + the actual display, which is reliable from a
        // LaunchAgent. CGGetActiveDisplayList alone was returning stale/false
        // negatives for the virtual display and caused a restart loop.
        if let status = vdscreenStatus(), status.contains("6016 x 3384") || status.contains("6016x3384") {
            return true
        }
        return hasTargetDisplay()
    }

    static func restartDisplay() {
        guard FileManager.default.isExecutableFile(atPath: vdscreen) else {
            log("watchdog: vdscreen not found at \(vdscreen)")
            return
        }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: vdscreen)
        p.arguments = ["on", "3008x1692"]
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = "/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin"
        p.environment = env
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        do {
            try p.run()
            p.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let out = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            log("watchdog: vdscreen on exit=\(p.terminationStatus) \(out)")
        } catch {
            log("watchdog: failed to run vdscreen: \(error)")
        }
        let n = Process()
        n.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        n.arguments = ["-e", "display notification \"virtual display was missing; vdscreen restarted\" with title \"boltkvm watchdog\""]
        try? n.run()
    }

    static func install(interval: Int) {
        let exe = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath().path
        let logs = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs")
        try? FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
        let logPath = logs.appendingPathComponent("boltkvm-watchdog.log").path
        let plistPath = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents/com.boltkvm.watchdog.plist").path
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
            <key>Label</key><string>com.boltkvm.watchdog</string>
            <key>ProgramArguments</key>
            <array>
                <string>\(exe)</string>
                <string>watchdog</string>
                <string>--interval</string>
                <string>\(interval)</string>
            </array>
            <key>RunAtLoad</key><true/>
            <key>KeepAlive</key><true/>
            <key>ProcessType</key><string>Background</string>
            <key>ThrottleInterval</key><integer>10</integer>
            <key>StandardOutPath</key><string>\(logPath)</string>
            <key>StandardErrorPath</key><string>\(logPath)</string>
        </dict>
        </plist>
        """
        do {
            try xml.write(toFile: plistPath, atomically: true, encoding: .utf8)
            let uid = getuid()
            let bootout = Process()
            bootout.executableURL = URL(fileURLWithPath: "/bin/launchctl")
            bootout.arguments = ["bootout", "gui/\(uid)/com.boltkvm.watchdog"]
            try? bootout.run(); bootout.waitUntilExit()
            let boot = Process()
            boot.executableURL = URL(fileURLWithPath: "/bin/launchctl")
            boot.arguments = ["bootstrap", "gui/\(uid)", plistPath]
            try boot.run(); boot.waitUntilExit()
            log("watchdog: installed \(plistPath) exit=\(boot.terminationStatus) exe=\(exe)")
        } catch {
            log("watchdog: install failed: \(error)")
        }
    }

    static func uninstall() {
        let uid = getuid()
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        p.arguments = ["bootout", "gui/\(uid)/com.boltkvm.watchdog"]
        try? p.run(); p.waitUntilExit()
        let plist = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents/com.boltkvm.watchdog.plist")
        try? FileManager.default.removeItem(at: plist)
        log("watchdog: uninstalled")
    }

    static func run(_ args: [String]) {
        if args.contains("--uninstall") { uninstall(); exit(0) }
        let interval = Int(argValue(args, "--interval", "5")) ?? 5
        if args.contains("--install") { install(interval: interval); exit(0) }
        let once = args.contains("--once")
        var missing = 0
        var lastRestart = 0.0
        while true {
            let ok = isHealthy()
            let now = Date().timeIntervalSince1970
            if !ok {
                missing += 1
                let status = vdscreenStatus() ?? "<nil>"
                log("watchdog: display unhealthy (\(missing)) status=\(status.replacingOccurrences(of: "\n", with: " | "))")
            } else {
                if missing > 0 { log("watchdog: display healthy again") }
                missing = 0
            }
            if once { exit(ok ? 0 : 1) }
            if missing >= 2 {
                if now - lastRestart >= 60 {
                    restartDisplay()
                    lastRestart = Date().timeIntervalSince1970
                } else {
                    log("watchdog: restart suppressed (cooldown)")
                }
                missing = 0
            }
            Thread.sleep(forTimeInterval: Double(interval))
        }
    }
}
