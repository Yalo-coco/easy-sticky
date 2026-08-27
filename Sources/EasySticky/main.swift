import AppKit

let application = NSApplication.shared
let appDelegate = AppDelegate()

application.delegate = appDelegate
application.setActivationPolicy(.regular)

if CommandLine.arguments.contains("--smoke-test") {
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
        application.terminate(nil)
    }
}

application.run()
