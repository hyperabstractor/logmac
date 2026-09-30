import AppKit
import SensorsC

// `LogMac --dump` prints raw sensor and sampler output, handy when adding chip support.
if CommandLine.arguments.contains("--dump") {
    sensors_dump()
    let sampler = SystemSampler()
    _ = sampler.sample()
    Thread.sleep(forTimeInterval: 1)
    print(sampler.sample())
    exit(0)
}

MainActor.assumeIsolated {
    #if DEBUG
    // `swift run LogMac --selftest` runs the pairing checks in SelfTest.swift.
    if CommandLine.arguments.contains("--selftest") { runSelfTest() }
    #endif

    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    app.run()
}
