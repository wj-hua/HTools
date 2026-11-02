import Foundation
import Dispatch

if CommandLine.arguments.dropFirst().first == "--mcp" {
    Task { @MainActor in
        await HToolsMCP.run()
        exit(0)
    }
    dispatchMain()
} else {
    HToolsApp.main()
}
