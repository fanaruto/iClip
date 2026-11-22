import AppKit

#if !ICLIP_EDITION_FLOW
if CommandLine.arguments.contains("--bench-semantic") {
    print(SemanticEngine.runMicroBenchmark())
    exit(0)
}
#endif

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.run()
}
