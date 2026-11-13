import AppKit
import BoltKVMCore
import Foundation

/// The CLI is a thin dispatcher: everything reusable lives in BoltKVMCore so the
/// app can share it.
@main
struct BoltKVM {
    static func main() async {
        let args = CommandLine.arguments
        guard args.count >= 2 else { CLI.printUsage() }
        switch args[1] {
        case "server":
            runServerEventLoop(args)
        case "keygen":
            CLI.runKeygen(args)
        case "doctor":
            CLI.runDoctor(args)
        case "watchdog":
            CLI.runWatchdog(args)
        case "selftest":
            CLI.runSelftest()
        case "inputprobe":
            await CLI.runInputProbe(args)
        case "cryptotest":
            CLI.runCryptoTest()
        case "displays":
            CLI.runDisplays()
        case "pattern":
            await CLI.runPattern(args)
        case "client":
            if args.contains("--render") {
                await CLI.runClientRender(args)
            } else {
                await CLI.runClient(args)
            }
        default:
            CLI.printUsage()
        }
    }

    /// The capture helper is a bundled executable, so LaunchServices registers
    /// it under the bundle's identity ("BoltKVM") and Activity Monitor pings it
    /// for responsiveness like any app. A CLI process has no main runloop and
    /// can never answer, so the helper showed a permanent 未响应 badge (it is
    /// the busy encode process, which reads as "the app hung"; 2026-11-13 the
    /// user force-rebooted mini over it). Give the long-lived server mode a
    /// real, UI-less main runloop: `.prohibited` means no Dock icon and no
    /// menu, while the runloop answers the ping so Activity Monitor shows a
    /// healthy process.
    ///
    /// ORDERING CONSTRAINT (2026-11-13 mini): the NSApplication event loop must
    /// start only AFTER the virtual display has been created. Creating the
    /// display while an NSApp runloop is already active made the private API's
    /// HiDPI negotiation silently degrade to 1:1 — the stream lost its 2x
    /// backing and turned blurry, deterministically on one machine and never
    /// on the other, surviving reboots once the fallback had happened. So this
    /// function pumps a bare main-thread run loop (no NSApp) until
    /// `CLI.onVirtualDisplayReady` fires, and only then takes over with
    /// NSApplication. All virtual-display work therefore still happens in the
    /// same NSApp-free environment as before the badge fix.
    private static func runServerEventLoop(_ args: [String]) {
        let displayReadyTimeout = Date().addingTimeInterval(60)
        var displayReady = false
        CLI.onVirtualDisplayReady = { displayReady = true }

        let serverTask = Task.detached(priority: .userInitiated) {
            await CLI.runServer(args)
            // The server ended (a bounded `--seconds` run); let the runloop
            // unwind so this process exits instead of lingering as an empty
            // app. Supervisor exit paths (`exit(2/3/9)`, stdin EOF) do not
            // come through here.
            await MainActor.run { NSApplication.shared.stop(nil) }
        }

        // Pump the bare main run loop while the display is being created; this
        // services the main queue (prepareVirtualDisplay) without an NSApp.
        while !displayReady && Date() < displayReadyTimeout {
            RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.1))
        }

        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)
        app.run()
        // Only reachable when the server task finished a bounded run and
        // stopped the app from above; returning from async main() then ends
        // the process. An early spurious return would kill the helper and the
        // supervisor would restart it, which is the existing failure mode.
    }
}
