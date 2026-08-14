import Foundation
import AppKit

@main
struct Main {
    /// A `.recut` passed on the command line, opened once the editor is up.
    /// Set before SwiftUI starts so `AppState` can pick it up on first appear.
    static private(set) var launchProject: URL?

    /// Cleared after the first open so closing the project returns to the library.
    static func consumeLaunchProject() { launchProject = nil }

    static func main() {
        let args = Array(CommandLine.arguments.dropFirst())
        if let first = args.first, first.hasPrefix("--") {
            CLI.run(args)
            return
        }
        // `open -a Recut.app --args /path/to/Something.recut`
        if let path = args.first(where: { $0.hasSuffix(".recut") }) {
            launchProject = URL(fileURLWithPath: path)
        }
        RecutApp.main()
    }
}
