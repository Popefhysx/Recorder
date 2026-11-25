import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var session: Session
    @FocusState private var keysFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            TopBar()
            Divider()
            HStack(spacing: 0) {
                TimelineArea(focusKeys: { keysFocused = true })
                MasterPanel()
                    .padding(.vertical, 14).padding(.trailing, 14).padding(.leading, 6)
            }
            .overlay(alignment: .bottom) { ProblemToast() }
            TransportBar()
        }
        .ignoresSafeArea(.container, edges: .top)
        .background(Theme.background)
        .sheet(isPresented: Binding(get: { session.denoiseTarget != nil }, set: { if !$0 { session.denoiseTarget = nil } })) {
            if let ref = session.denoiseTarget { DenoiseSheet(ref: ref) }
        }
        .foregroundStyle(Theme.text)
        .tint(Theme.purple)
        .preferredColorScheme(.light)
        .navigationTitle(session.title)
        .focusable()
        .focusEffectDisabled()
        .focused($keysFocused)
        .onAppear { keysFocused = true }
        .onKeyPress(.space) { session.togglePlay(); return .handled }
        .onKeyPress(.return) { session.returnToStart(); return .handled }
        .onKeyPress(.delete) { session.deleteSelectedClip(); return .handled }
        .onKeyPress(.deleteForward) { session.deleteSelectedClip(); return .handled }
        .onKeyPress(characters: CharacterSet(charactersIn: "rlsRLS")) { press in
            switch press.characters.lowercased() {
            case "r": session.toggleRecord()
            case "l": session.toggleLoop()
            case "s": session.splitAtPlayhead()
            default: return .ignored
            }
            return .handled
        }
    }
}

// MARK: top bar

struct TopBar: View {
    @EnvironmentObject private var session: Session
    @State private var showSettings = false
    @State private var fullScreen = NSApp.windows.contains { $0.styleMask.contains(.fullScreen) }

    var body: some View {
        ZStack {
            Color.white.gesture(WindowDragGesture())
            HStack(spacing: 12) {
                Color.clear.frame(width: fullScreen ? 0 : 60, height: 1)   // room for the window buttons
                AppMark()
                Text("Recorder").font(.system(size: 21, weight: .bold)).fixedSize()
                Spacer(minLength: 12)
                ModeTabs().fixedSize()
                Spacer(minLength: 12)
                SaveControls()
                InputPicker()
                OutputPicker()
                Button { showSettings.toggle() } label: {
                    Image(systemName: "gearshape").font(.system(size: 17))
                        .frame(width: 40, height: 40)
                        .background(Circle().fill(.white)).overlay(Circle().strokeBorder(Theme.border))
                }
                .buttonStyle(.plain)
                .popover(isPresented: $showSettings, arrowEdge: .bottom) { SettingsPopover() }
            }
            .padding(.horizontal, 18)
        }
        .frame(height: 64)
        .padding(.top, 2)
        // Full screen hides the window buttons, so drop the space kept for them.
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didEnterFullScreenNotification)) { _ in fullScreen = true }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didExitFullScreenNotification)) { _ in fullScreen = false }
    }
}

struct AppMark: View {
    var body: some View {
        Image(nsImage: NSApp.applicationIconImage)
            .resizable().interpolation(.high)
            .frame(width: 40, height: 40)
            .padding(-4) // the icon art has a margin around the square
    }
}

struct ModeTabs: View {
    @EnvironmentObject private var session: Session
    var body: some View {
        HStack(spacing: 4) {
            tab("Editor", "waveform", selected: true) {}
            tab("Split", "scissors", selected: false) { session.splitAtPlayhead() }
                .help("Split the selected clip (or the clips on the selected track) at the playhead — S")
            Menu {
                Button("Export Mix as WAV…") { session.runExportPanel(.wav) }
                Button("Export Mix as M4A…") { session.runExportPanel(.m4a) }
            } label: {
                Label("Export", systemImage: "square.and.arrow.up").font(.system(size: 15, weight: .medium))
                    .padding(.horizontal, 14).frame(height: 38)
            }
            .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
        }
        .padding(4)
        .background(Capsule().fill(Theme.background))
        .overlay(Capsule().strokeBorder(Theme.border))
    }

    private func tab(_ title: String, _ icon: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: icon).font(.system(size: 15, weight: selected ? .semibold : .medium))
                .padding(.horizontal, 14).frame(height: 38)
                .foregroundStyle(selected ? .white : Theme.text)
                .background(Capsule().fill(selected ? Theme.purple : .clear))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}

/// Save button plus a menu for the other project actions.
struct SaveControls: View {
    @EnvironmentObject private var session: Session
    var body: some View {
        HStack(spacing: 0) {
            Button { session.saveOrAsk() } label: {
                HStack(spacing: 6) {
                    Image(systemName: session.isDirty ? "square.and.arrow.down" : "checkmark.circle")
                    Text(session.isDirty || session.folder == nil ? "Save" : "Saved")
                }
                .font(.system(size: 14, weight: .medium))
                .padding(.leading, 16).padding(.trailing, 10).frame(height: 40)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Save the project (⌘S)")
            Rectangle().fill(Theme.border).frame(width: 1, height: 22)
            Menu {
                Button("New Project") { session.newProject() }
                Button("Open Project…") { session.runOpenPanel() }
                Button("Save As…") { session.runSaveAsPanel() }
                Divider()
                Button("Import Audio…") { session.runImportPanel() }
                Divider()
                Button("Export Mix as WAV…") { session.runExportPanel(.wav) }
                Button("Export Mix as M4A…") { session.runExportPanel(.m4a) }
                Divider()
                Button("Delete Unused Recordings…") { session.runCleanUp() }
            } label: {
                Image(systemName: "chevron.down").font(.system(size: 11, weight: .semibold))
                    .frame(width: 34, height: 40).contentShape(Rectangle())
            }
            .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
        }
        .background(Capsule().fill(.white)).overlay(Capsule().strokeBorder(Theme.border))
        .fixedSize()
    }
}

struct InputPicker: View {
    @EnvironmentObject private var session: Session
    var body: some View {
        Menu {
            Button { session.preferredInputUID = nil } label: {
                Text("Automatic (USB interface if connected)") + Text(session.preferredInputUID == nil ? "  ✓" : "")
            }
            Divider()
            ForEach(session.devices) { d in
                Button { session.preferredInputUID = d.id } label: {
                    Text("\(d.name) (\(d.channels) in)") + Text(session.preferredInputUID == d.id ? "  ✓" : "")
                }
            }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "mic").font(.system(size: 15))
                Text(label).font(.system(size: 14, weight: .medium)).lineLimit(1)
                InputMeters()
                Image(systemName: "chevron.down").font(.system(size: 11, weight: .semibold))
            }
            .padding(.horizontal, 16).frame(height: 40)
            .background(Capsule().fill(.white)).overlay(Capsule().strokeBorder(Theme.border))
            .contentShape(Capsule())
        }
        .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
        .layoutPriority(1)
        .help("Input device. Recorder reconnects to it if it drops out and comes back.")
    }

    private var label: String {
        if let uid = session.preferredInputUID, !session.devices.contains(where: { $0.id == uid }) { return "Input missing — using default" }
        if let d = session.activeDevice { return d.name }
        return "Built-in / Default Input"
    }
}

/// Where playback, clicks and live monitoring go.
struct OutputPicker: View {
    @EnvironmentObject private var session: Session
    var body: some View {
        Menu {
            Button { session.preferredOutputUID = nil } label: {
                Text("System Output (\(session.outputs.first { $0.objectID == AudioDevices.defaultOutput() }?.name ?? "default"))")
                    + Text(session.preferredOutputUID == nil ? "  ✓" : "")
            }
            Divider()
            ForEach(session.outputs) { d in
                Button { session.preferredOutputUID = d.id } label: {
                    Text(d.name) + Text(session.preferredOutputUID == d.id ? "  ✓" : "")
                }
            }
        } label: {
            Image(systemName: "headphones").font(.system(size: 16))
                .frame(width: 40, height: 40)
                .background(Circle().fill(.white)).overlay(Circle().strokeBorder(Theme.border))
                .contentShape(Circle())
        }
        .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
        .help("Output: \(session.outputName). Playback, the metronome and live monitoring play here. Pick USB Audio CODEC for the UMC22's headphones.")
    }
}

/// One small live meter per input channel, labelled 1, 2, …
struct InputMeters: View {
    @EnvironmentObject private var levels: Levels
    var body: some View {
        if !levels.inputs.isEmpty {
            VStack(alignment: .leading, spacing: 3) {
                ForEach(Array(levels.inputs.prefix(2).enumerated()), id: \.offset) { i, level in
                    HStack(spacing: 4) {
                        Text("\(i + 1)").font(.system(size: 9, weight: .bold)).foregroundStyle(Theme.secondary)
                        LevelMeter(level: level, vertical: false).frame(width: 64, height: 6)
                    }
                }
            }
            .help("Live level of each input. If a meter stays empty, check the cable, the gain knob and 48V for condenser mics.")
        }
    }
}

struct SettingsPopover: View {
    @EnvironmentObject private var session: Session
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Project").font(.headline)
            HStack {
                Button("New") { session.newProject() }
                Button("Open…") { session.runOpenPanel() }
                Button("Save") { session.saveOrAsk() }
                Button("Save As…") { session.runSaveAsPanel() }
            }
            Button("Delete Unused Recordings…") { session.runCleanUp() }
            if let folder = session.folder {
                Text(folder.path).font(.caption).foregroundStyle(.secondary).lineLimit(2).textSelection(.enabled)
            }
            Divider()
            Text("Timeline zoom").font(.headline)
            Slider(value: Binding(get: { log(session.pointsPerSecond) }, set: { session.pointsPerSecond = exp($0) }),
                   in: log(5)...log(800))
            Divider()
            Text("Loop range").font(.headline)
            HStack {
                Button("Start at Playhead") { session.setLoop(start: session.clock.position) }
                Button("End at Playhead") { session.setLoop(end: session.clock.position) }
            }
            Text(String(format: "%@ – %@", TimeDisplay.format(session.project.loopStart), TimeDisplay.format(session.project.loopEnd)))
                .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
        }
        .padding(16)
        .frame(width: 330)
    }
}

struct ProblemToast: View {
    @EnvironmentObject private var session: Session
    var body: some View {
        if let problem = session.problem {
            HStack(spacing: 10) {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                Text(problem).font(.callout).lineLimit(3)
                Button { session.problem = nil } label: { Image(systemName: "xmark") }.buttonStyle(.plain)
            }
            .padding(.horizontal, 14).padding(.vertical, 10)
            .card(radius: 12)
            .padding(14)
            .frame(maxWidth: 620)
        }
    }
}

// MARK: transport

struct TransportBar: View {
    @EnvironmentObject private var session: Session

    var body: some View {
        HStack(spacing: 14) {
            Spacer()
            RoundButton(size: 50, fill: Theme.record, action: { session.toggleRecord() }) {
                ZStack {
                    Circle().strokeBorder(.white.opacity(session.isRecording ? 1 : 0), lineWidth: 3).padding(5)
                    if session.isRecording {
                        RoundedRectangle(cornerRadius: 3).fill(.white).frame(width: 14, height: 14)
                    } else {
                        Circle().fill(.white).frame(width: 15, height: 15)
                    }
                }
            }
            .help("Record armed tracks (R)")
            .padding(.trailing, 6)

            HStack(spacing: 8) {
                RoundButton(action: { session.returnToStart() }) {
                    Image(systemName: "backward.fill").font(.system(size: 16))
                }
                .help("Back to the start (Return)")
                RoundButton(size: 54, fill: Theme.purple, action: { session.togglePlay() }) {
                    Image(systemName: session.isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 20)).foregroundStyle(.white).offset(x: session.isPlaying ? 0 : 2)
                }
                .help("Play / Pause (Space)")
                RoundButton(action: { session.setPosition(session.clock.position + 5) }) {
                    Image(systemName: "forward.fill").font(.system(size: 16))
                }
                .help("Forward 5 seconds")
                RoundButton(action: { session.stop() }) {
                    RoundedRectangle(cornerRadius: 2).fill(Theme.text).frame(width: 14, height: 14)
                }
                .help("Stop (press twice to go back to the start)")
            }
            .padding(4)
            .background(Capsule().fill(Theme.background))

            Rectangle().fill(Theme.border).frame(width: 1, height: 40).padding(.horizontal, 10)
            TimeDisplay()
            Spacer(minLength: 16)
            TempoControls()
            Spacer(minLength: 16)

            Image(systemName: "speaker.wave.2").font(.system(size: 17)).foregroundStyle(Theme.text)
            Slider(value: Gain.binding(Binding(get: { session.project.masterVolume }, set: { session.project.masterVolume = $0 })))
                .frame(minWidth: 80, maxWidth: 160)
                .help("Master volume")
            Button { session.toggleLoop() } label: {
                Image(systemName: "repeat").font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(session.project.loopEnabled ? .white : Theme.text)
                    .frame(width: 44, height: 44)
                    .background(RoundedRectangle(cornerRadius: 12).fill(session.project.loopEnabled ? Theme.purple : .white))
                    .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Theme.border))
            }
            .buttonStyle(.plain)
            .help("Loop (L). Set the loop range in Settings or with ⌘[ and ⌘].")
            .padding(.leading, 12)
        }
        .padding(.horizontal, 22)
        .frame(height: 84)
        .background(Color.white)
        .overlay(alignment: .top) { Rectangle().fill(Theme.border).frame(height: 1) }
    }
}

/// Metronome, tempo, time signature, count-in and snap.
struct TempoControls: View {
    @EnvironmentObject private var session: Session
    var body: some View {
        HStack(spacing: 6) {
            toggle("metronome", on: session.project.metronome, help: "Metronome click while playing and recording (only you hear it; it's never recorded or exported)") {
                session.project.metronome.toggle()
            }
            HStack(spacing: 3) {
                TextField("BPM", value: Binding(get: { session.project.tempo }, set: { session.project.tempo = $0 }),
                          format: .number.precision(.fractionLength(0...1)))
                    .textFieldStyle(.plain).multilineTextAlignment(.trailing)
                    .font(.system(size: 14, weight: .semibold).monospacedDigit()).frame(width: 38)
                Text("BPM").font(.system(size: 10, weight: .medium)).foregroundStyle(Theme.secondary)
                Menu {
                    ForEach([2, 3, 4, 5, 6, 7], id: \.self) { n in
                        Button("\(n)/4") { session.project.beatsPerBar = n }
                    }
                } label: {
                    Text("\(session.project.beatsPerBar)/4").font(.system(size: 13, weight: .semibold))
                }
                .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
                .help("Beats per bar")
            }
            .padding(.horizontal, 10).frame(height: 36)
            .background(RoundedRectangle(cornerRadius: 10).fill(Theme.background))
            .help("Tempo")
            toggle("1.circle", on: session.project.countIn, help: "Count-in: one bar of clicks before recording starts") {
                session.project.countIn.toggle()
            }
            toggle("square.grid.3x1.below.line.grid.1x2", on: session.project.snap, help: "Snap clips to beats and show bars on the ruler") {
                session.project.snap.toggle()
            }
        }
        .fixedSize()
    }

    private func toggle(_ icon: String, on: Bool, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon).font(.system(size: 15, weight: .semibold))
                .foregroundStyle(on ? .white : Theme.text)
                .frame(width: 36, height: 36)
                .background(RoundedRectangle(cornerRadius: 10).fill(on ? Theme.purple : .white))
                .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(on ? .clear : Theme.border))
        }
        .buttonStyle(.plain)
        .help(help)
    }
}

struct TimeDisplay: View {
    @EnvironmentObject private var clock: Clock
    @EnvironmentObject private var session: Session
    var body: some View {
        // Drops the total length when the window is too narrow, rather than wrapping.
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 6) {
                now
                Text("/").foregroundStyle(Theme.secondary)
                Text(Self.format(session.project.duration)).foregroundStyle(Theme.secondary)
            }
            now
        }
        .font(.system(size: 20, weight: .medium).monospacedDigit())
        .lineLimit(1)
        .layoutPriority(1)
    }

    private var now: some View {
        Text(Self.format(clock.position))
            .foregroundStyle(session.isRecording ? Theme.record : Theme.text)
            .fixedSize()
    }
    static func format(_ time: Double) -> String {
        let t = abs(time)
        let m = Int(t) / 60, s = Int(t) % 60, ms = Int((t - floor(t)) * 1000)
        return String(format: "%@%d:%02d.%03d", time < -0.0005 ? "-" : "", m, s, ms)
    }
}

// MARK: master

struct MasterPanel: View {
    @EnvironmentObject private var session: Session
    @EnvironmentObject private var levels: Levels

    var body: some View {
        VStack(spacing: 14) {
            Text("Master").font(.system(size: 17, weight: .bold))
            HStack(alignment: .bottom, spacing: 10) {
                VerticalFader(gain: Binding(get: { session.project.masterVolume }, set: { session.project.masterVolume = $0 }))
                LevelMeter(level: levels.master.0).frame(width: 9)
                LevelMeter(level: levels.master.1).frame(width: 9)
            }
            .frame(maxHeight: .infinity)
            Text(Gain.dbText(session.project.masterVolume)).font(.system(size: 14).monospacedDigit())
        }
        .padding(.vertical, 22)
        .frame(width: Layout.masterWidth)
        .frame(maxHeight: .infinity)
        .card(radius: 16)
    }
}

/// Thin vertical fader with a round thumb. Double-click resets to 0 dB.
struct VerticalFader: View {
    @Binding var gain: Float
    var body: some View {
        GeometryReader { geo in
            let h = geo.size.height
            let pos = CGFloat(Gain.position(gain))
            ZStack(alignment: .bottom) {
                Capsule().fill(Color.black.opacity(0.08)).frame(width: 4)
                Capsule().fill(Theme.purple.opacity(0.5)).frame(width: 4, height: max(0, (h - 22) * pos + 11))
                Circle().fill(.white).frame(width: 22, height: 22)
                    .shadow(color: .black.opacity(0.25), radius: 2, y: 1)
                    .offset(y: -(h - 22) * pos)
            }
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { v in
                gain = Gain.gain(Double(min(1, max(0, 1 - (v.location.y - 11) / (h - 22)))))
            })
            .onTapGesture(count: 2) { gain = 1 }
        }
        .frame(width: 26)
    }
}
