import SwiftUI

@main
struct RecorderApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var session = Session()

    init() {
        if let i = CommandLine.arguments.firstIndex(of: "--selftest") {
            let log = CommandLine.arguments.dropFirst(i + 1).first ?? NSTemporaryDirectory() + "recorder-selftest.txt"
            SelfTest.start(logPath: log)
        }
        if let i = CommandLine.arguments.firstIndex(of: "--inputcheck") {
            let log = CommandLine.arguments.dropFirst(i + 1).first ?? NSTemporaryDirectory() + "recorder-inputcheck.txt"
            InputCheck.start(logPath: log)
        }
    }

    var body: some Scene {
        Window("Recorder", id: "main") {
            ContentView()
                .environmentObject(session)
                .environmentObject(session.clock)
                .environmentObject(session.levels)
                .environmentObject(session.waveforms)
                .frame(minWidth: 1100, minHeight: 660)
                .onAppear {
                    delegate.session = session
                    if let i = CommandLine.arguments.firstIndex(of: "--open"), i + 1 < CommandLine.arguments.count {
                        try? session.open(URL(fileURLWithPath: CommandLine.arguments[i + 1]))
                    }
                }
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1400, height: 820)
        .commands {
            CommandGroup(replacing: .appSettings) {
                Button("Keyboard Shortcuts…") { Shortcuts.shared.showingEditor = true }.keyboardShortcut(",")
            }
            CommandGroup(replacing: .undoRedo) {
                Button("Undo") { session.undo() }.keyboardShortcut("z").disabled(!session.canUndo)
                Button("Redo") { session.redo() }.keyboardShortcut("z", modifiers: [.command, .shift]).disabled(!session.canRedo)
            }
            CommandGroup(replacing: .newItem) {
                Button("New Project") { session.newProject() }.keyboardShortcut("n")
                Button("Open Project…") { session.runOpenPanel() }.keyboardShortcut("o")
            }
            CommandGroup(replacing: .saveItem) {
                Button("Save") { session.saveOrAsk() }.keyboardShortcut("s")
                Button("Save As…") { session.runSaveAsPanel() }.keyboardShortcut("s", modifiers: [.command, .shift])
                Divider()
                Button("Import Audio…") { session.runImportPanel() }.keyboardShortcut("i")
                Divider()
                Button("Export Mix as WAV…") { session.runExportPanel(.wav) }.keyboardShortcut("e")
                Button("Export Mix as M4A…") { session.runExportPanel(.m4a) }.keyboardShortcut("e", modifiers: [.command, .option])
                Divider()
                Button("Delete Unused Recordings…") { session.runCleanUp() }
            }
            CommandMenu("Track") {
                Button("Add Track") { session.addTrack() }.keyboardShortcut("t", modifiers: [.command, .shift])
                Button("Split at Playhead") { session.splitAtPlayhead() }.keyboardShortcut("t")
                Button("Delete Clip") { session.deleteSelectedClip() }.keyboardShortcut(.delete)
                Divider()
                Button("Denoise Clip…") { session.selection.map { session.cleanupTarget = .init(ref: $0, tool: .denoise) } }
                    .keyboardShortcut("n", modifiers: [.command, .option])
                    .disabled(session.selection == nil)
                Button("Voice Clean Clip…") { session.selection.map { session.cleanupTarget = .init(ref: $0, tool: .voiceClean) } }
                    .keyboardShortcut("v", modifiers: [.command, .option])
                    .disabled(session.selection == nil)
            }
            CommandMenu("Transport") {
                Button("Play / Stop") { session.togglePlay() }.keyboardShortcut(.return, modifiers: [.command])
                Button("Record") { session.toggleRecord() }.keyboardShortcut("r")
                Button("Return to Start") { session.returnToStart() }.keyboardShortcut(.leftArrow, modifiers: [.command])
                Button("Loop") { session.toggleLoop() }.keyboardShortcut("l")
                Divider()
                Button("Set Loop Start at Playhead") { session.setLoop(start: session.clock.position) }.keyboardShortcut("[")
                Button("Set Loop End at Playhead") { session.setLoop(end: session.clock.position) }.keyboardShortcut("]")
                Divider()
                Button("Zoom In") { session.pointsPerSecond = min(800, session.pointsPerSecond * 1.5) }.keyboardShortcut("=")
                Button("Zoom Out") { session.pointsPerSecond = max(5, session.pointsPerSecond / 1.5) }.keyboardShortcut("-")
            }
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    weak var session: Session?

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    /// Projects that already have a folder are saved on quit, so a take is never lost.
    func applicationWillTerminate(_ notification: Notification) {
        guard let session, session.folder != nil else { return }
        session.stop()
        if session.isDirty { try? session.save() }
    }
}
