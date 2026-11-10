import AppKit

// Top-level code runs on the main thread; tell the compiler so.
MainActor.assumeIsolated {
    let arguments = Array(CommandLine.arguments.dropFirst())
    if arguments.contains(where: CommandLineTool.commands.contains) {
        CommandLineTool.run(arguments)
    }

    let app = NSApplication.shared
    let controller = AppController()
    app.delegate = controller
    app.setActivationPolicy(.accessory)
    app.run()
}
