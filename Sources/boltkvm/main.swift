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
            await CLI.runServer(args)
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
}
