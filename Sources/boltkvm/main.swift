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
    /// menu (what TransformProcessType used to fake), while the runloop
    /// answers the ping so Activity Monitor shows a healthy process.
    ///
    /// This must be called synchronously from async main() BEFORE the first
    /// suspension, so it still runs on the main thread. Occupying the main
    /// thread with `app.run()` is fine; occupying the main ACTOR is not —
    /// a `MainActor.run { app.run() }` variant deadlocked the server task's
    /// own `MainActor.run` hops (virtual-display setup) behind the runloop
    /// job, because main-actor jobs are strictly serial and `run()` inside
    /// such a job never returns.
    private static func runServerEventLoop(_ args: [String]) {
        let serverTask = Task.detached(priority: .userInitiated) {
            await CLI.runServer(args)
            // The server ended (a bounded `--seconds` run); let the runloop
            // unwind so this process exits instead of lingering as an empty
            // app. Supervisor exit paths (`exit(2/3/9)`, stdin EOF) do not
            // come through here.
            await MainActor.run { NSApplication.shared.stop(nil) }
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
