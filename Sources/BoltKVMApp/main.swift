import BoltKVMCore
import Foundation

// The app is a shell: role selection, windows and menu bar live in
// BoltKVMCore/App so the CLI and the app keep sharing one implementation.
AppLog.redirect()
AppMain.run()
