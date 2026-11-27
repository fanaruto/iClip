import AppKit

@main
enum iClipLauncher {
    static func main() {
        if CommandLine.arguments.contains("--bench-semantic") {
            print(SemanticEngine.runMicroBenchmark())
            exit(0)
        }

        MainActor.assumeIsolated {
            let app = NSApplication.shared
            let delegate = AppDelegate()
            app.delegate = delegate
            app.run()
        }
    }
}
