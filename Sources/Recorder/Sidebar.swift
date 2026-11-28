import SwiftUI

/// One track's card in the left column; its height matches the track's lane.
struct TrackCard: View {
    @EnvironmentObject private var session: Session
    @EnvironmentObject private var levels: Levels
    @Binding var track: Track
    @State private var showMore = false

    var body: some View {
        let selected = session.selectedTrack == track.id
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 8) {
                TextField("Name", text: $track.name).textFieldStyle(.plain).font(.system(size: 15, weight: .semibold))
                Menu {
                    Section("Mono") {
                        ForEach(0..<max(2, session.inputChannels), id: \.self) { c in
                            Button { track.inputChannel = c; track.stereo = false } label: {
                                Text("Input \(c + 1)") + Text(!track.stereo && track.inputChannel == c ? "  ✓" : "")
                            }
                        }
                    }
                    Section("Stereo") {
                        Button { track.stereo = true } label: {
                            Text("Inputs 1 + 2 (left + right)") + Text(track.stereo ? "  ✓" : "")
                        }
                        .disabled(session.inputChannels < 2)
                    }
                    Section("Boost (for quiet mics)") {
                        ForEach([Float(0), 6, 12, 18, 24], id: \.self) { db in
                            Button { track.boost = db } label: {
                                Text(db == 0 ? "Off" : String(format: "+%.0f dB", db)) + Text(track.boost == db ? "  ✓" : "")
                            }
                        }
                    }
                } label: {
                    Text(track.inputChipLabel).font(.system(size: 11, weight: .semibold))
                        .padding(.horizontal, 7).frame(height: 20)
                        .background(Capsule().fill(Theme.background)).overlay(Capsule().strokeBorder(Theme.border))
                }
                .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
                .help("Which input of the interface this track records, and how much to boost it")
                Button { track.armed.toggle() } label: {
                    Image(systemName: track.armed ? "record.circle.fill" : "record.circle")
                        .font(.system(size: 17)).foregroundStyle(track.armed ? Theme.record : Theme.secondary)
                }
                .buttonStyle(.plain).disabled(session.isRecording)
                .help("Arm for recording")
                Button { openMore() } label: {
                    Image(systemName: "ellipsis").font(.system(size: 14, weight: .bold))
                        .frame(width: 26, height: 22).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Track settings: effects, volume, pan, delete")
                .popover(isPresented: $showMore, arrowEdge: .trailing) {
                    TrackInspector(track: $track) {
                        showMore = false
                        session.removeTrack(track.id)
                    }
                    
                }
            }
            HStack(spacing: 6) {
                Chip(label: "M", on: track.mute, onColor: .orange) { track.mute.toggle() }.help("Mute")
                Chip(label: "S", on: track.solo, onColor: Color(red: 0.95, green: 0.7, blue: 0.1)) { track.solo.toggle() }.help("Solo")
                Chip(label: "FX", on: false) { openMore() }
                    .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(hasFX ? Theme.purple : .clear, lineWidth: 1.5))
                    .help("Effects for this track")
                Button { track.monitor.toggle() } label: {
                    Image(systemName: track.monitor ? "headphones.circle.fill" : "headphones")
                        .font(.system(size: 13, weight: .semibold))
                        .frame(width: 28, height: 28)
                        .foregroundStyle(track.monitor ? .white : Theme.text)
                        .background(RoundedRectangle(cornerRadius: 8).fill(track.monitor ? Theme.purple : .white))
                        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(track.monitor ? .clear : Theme.border))
                }
                .buttonStyle(.plain)
                .help(Shortcuts.shared.hint("Listen: hear this track's input live, with its effects, for a soundcheck or while recording. Use headphones", .listen))
                Slider(value: Gain.binding($track.volume)).controlSize(.small).padding(.leading, 2)
                    .help(Gain.dbText(track.volume))
            }
            let channels = track.stereo ? [0, 1] : [track.inputChannel]
            let level: Float = track.armed
                ? min(1, (channels.map { $0 < levels.inputs.count ? levels.inputs[$0] : 0 }.max() ?? 0) * track.boostGain)
                : (levels.tracks[track.id] ?? 0)
            LevelMeter(level: level, vertical: false).frame(height: 4)
                .help(track.armed ? "Input level" : "Track level")
        }
        .padding(.horizontal, 12).padding(.vertical, 12)
        .card(selected: selected)
        .contentShape(Rectangle())
        .onTapGesture { session.selectedTrack = track.id }
        .padding(.vertical, 6)
        .frame(height: Layout.rowHeight)
    }

    private var hasFX: Bool { track.eq.enabled || track.comp.enabled || track.reverb.enabled || track.delay.enabled || track.gate.active }

    private func openMore() {
        session.selectedTrack = track.id
        showMore = true
    }
}

/// Settings for the selected track: effects, volume, pan, mute and solo.
struct TrackInspector: View {
    @Binding var track: Track
    var onDelete: () -> Void
    @State private var editing: FX? = nil
    @State private var confirmDelete = false

    enum FX: String, CaseIterable { case gate = "Gate", eq = "EQ", comp = "Comp", reverb = "Verb", delay = "Delay"
        var icon: String {
            switch self { case .gate: "door.left.hand.closed"; case .eq: "number"; case .comp: "chart.line.uptrend.xyaxis"; case .reverb: "waveform"; case .delay: "repeat" }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(track.name).font(.system(size: 14, weight: .semibold)).lineLimit(1)
                Spacer()
                Button { confirmDelete = true } label: {
                    Image(systemName: "trash").font(.system(size: 12)).foregroundStyle(Theme.record)
                }
                .buttonStyle(.plain)
                .help("Delete track")
                .confirmationDialog("Delete “\(track.name)”?", isPresented: $confirmDelete) {
                    Button("Delete Track", role: .destructive, action: onDelete)
                } message: {
                    Text("Its clips are removed from the project. The recordings stay on disk until you use Delete Unused Recordings.")
                }
            }
            FlowPills(spacing: 4) {
                pill("None", on: !anyFX) {
                    track.eq.enabled = false; track.comp.enabled = false; track.reverb.enabled = false; track.delay.enabled = false
                    track.gate = GateSettings(); editing = nil
                }
                ForEach(FX.allCases, id: \.self) { fx in
                    pill(fx.rawValue, on: isOn(fx), editing: editing == fx) { tap(fx) }
                }
            }
            if let fx = editing { settings(fx) }
            row("Boost") {
                // Rounded to whole dB in the binding rather than with `step:`, which draws a tick mark per step.
                Slider(value: Binding(get: { track.boost }, set: { track.boost = $0.rounded() }), in: 0...24).controlSize(.small)
                Text(track.boost == 0 ? "Off" : String(format: "+%.0f dB", track.boost))
                    .font(.system(size: 11).monospacedDigit()).frame(width: 52, alignment: .trailing)
                    .onTapGesture(count: 2) { track.boost = 0 }
            }
            .help("Raises a quiet input (e.g. a dynamic mic) before the effects. Doesn't change the recording, so you can adjust it later.")
            row("Vol") {
                Slider(value: Gain.binding($track.volume)).controlSize(.small)
                Text(Gain.dbText(track.volume)).font(.system(size: 11).monospacedDigit()).frame(width: 52, alignment: .trailing)
            }
            row("Pan") {
                Slider(value: $track.pan, in: -1...1).controlSize(.small)
                Text(track.pan == 0 ? "C" : String(format: "%@%.0f", track.pan < 0 ? "L" : "R", abs(track.pan) * 100))
                    .font(.system(size: 11).monospacedDigit()).frame(width: 52, alignment: .trailing)
                    .onTapGesture(count: 2) { track.pan = 0 }
            }
        }
        .padding(12)
        .frame(width: 268)
    }

    private func row<Content: View>(_ label: String, @ViewBuilder _ content: () -> Content) -> some View {
        HStack(spacing: 6) {
            Text(label).font(.system(size: 12, weight: .medium)).lineLimit(1).fixedSize().frame(width: 40, alignment: .leading)
            content()
        }
    }

    private var anyFX: Bool { track.eq.enabled || track.comp.enabled || track.reverb.enabled || track.delay.enabled || track.gate.active }

    private func isOn(_ fx: FX) -> Bool {
        switch fx { case .gate: track.gate.active; case .eq: track.eq.enabled; case .comp: track.comp.enabled; case .reverb: track.reverb.enabled; case .delay: track.delay.enabled }
    }

    private func setOn(_ fx: FX, _ on: Bool) {
        switch fx {
        case .gate: if on { track.gate.enabled = true } else { track.gate = GateSettings() }
        case .eq: track.eq.enabled = on
        case .comp: track.comp.enabled = on
        case .reverb: track.reverb.enabled = on
        case .delay: track.delay.enabled = on
        }
    }

    /// Off → on and show its settings; on and showing → off; on but hidden → show.
    private func tap(_ fx: FX) {
        if !isOn(fx) { setOn(fx, true); editing = fx }
        else if editing == fx { setOn(fx, false); editing = nil }
        else { editing = fx }
    }

    private func pill(_ title: String, on: Bool, editing: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title).font(.system(size: 11, weight: .medium))
                .padding(.horizontal, 8).frame(height: 22)
                .foregroundStyle(on ? .white : Theme.text)
                .background(Capsule().fill(on ? Theme.purple : .white))
                .overlay(Capsule().strokeBorder(editing ? Theme.purple.opacity(0.5) : (on ? .clear : Theme.border), lineWidth: editing ? 2 : 1))
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder private func settings(_ fx: FX) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            switch fx {
            case .gate:
                Toggle("Noise gate", isOn: $track.gate.enabled).font(.system(size: 12, weight: .medium))
                knob("Threshold", $track.gate.threshold, -80...(-10), "dB")
                Picker("Hum filter", selection: $track.gate.humHz) {
                    Text("Off").tag(0); Text("50 Hz").tag(50); Text("60 Hz").tag(60)
                }
                .pickerStyle(.segmented).controlSize(.small).font(.system(size: 12))
                Toggle("Low cut (below 80 Hz)", isOn: $track.gate.lowCut).font(.system(size: 12))
            case .eq:
                GraphicEQ(gains: $track.eq.gains)
            case .comp:
                knob("Threshold", $track.comp.threshold, -40...0, "dB")
                knob("Headroom", $track.comp.headroom, 0.5...20, "dB")
                knob("Makeup", $track.comp.makeup, 0...20, "dB")
            case .reverb:
                Picker("Room", selection: $track.reverb.preset) {
                    ForEach(ReverbSettings.presets.indices, id: \.self) { i in Text(ReverbSettings.presets[i]).tag(i) }
                }
                .controlSize(.small)
                knob("Mix", $track.reverb.mix, 0...100, "%")
            case .delay:
                Picker("Time", selection: $track.delay.note) {
                    ForEach(DelaySettings.notes.indices, id: \.self) { i in Text(DelaySettings.notes[i]).tag(i) }
                }
                .controlSize(.small)
                .help("Echo time in beats, following the project tempo")
                knob("Repeats", $track.delay.feedback, 0...90, "%")
                knob("Mix", $track.delay.mix, 0...100, "%")
                HStack(spacing: 6) {
                    Text("Tone").font(.system(size: 11)).frame(width: 58, alignment: .leading)
                    Slider(value: $track.delay.tone, in: 1000...16000).controlSize(.mini)
                    Text(String(format: "%.0fk", track.delay.tone / 1000)).font(.system(size: 10).monospacedDigit())
                        .frame(width: 40, alignment: .trailing)
                }
                .help("Darker repeats sit behind the voice")
            }
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 8).fill(Theme.lavender.opacity(0.6)))
    }

    private func knob(_ label: String, _ value: Binding<Float>, _ range: ClosedRange<Float>, _ unit: String) -> some View {
        HStack(spacing: 6) {
            Text(label).font(.system(size: 11)).frame(width: 58, alignment: .leading)
            Slider(value: value, in: range).controlSize(.mini)
            Text(String(format: "%.0f %@", value.wrappedValue, unit)).font(.system(size: 10).monospacedDigit())
                .frame(width: 40, alignment: .trailing)
        }
    }
}

/// Nine vertical band sliders, 20 Hz – 20 kHz. The band being touched (or hovered) is named above
/// them with its range and what it does to the sound.
struct GraphicEQ: View {
    @Binding var gains: [Float]
    @State private var focus: Int?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                if let i = focus {
                    let b = EQSettings.bands[i]
                    VStack(alignment: .leading, spacing: 1) {
                        Text("\(b.name) · \(Self.hz(b.low))–\(Self.hz(b.high)) · \(String(format: "%+.1f dB", gains[i]))")
                            .font(.system(size: 11, weight: .semibold))
                        Text(b.sound).font(.system(size: 10)).foregroundStyle(Theme.secondary)
                    }
                } else {
                    Text("20 Hz – 20 kHz · hover a band").font(.system(size: 11)).foregroundStyle(Theme.secondary)
                }
                Spacer(minLength: 4)
                Button("Flat") { gains = Array(repeating: 0, count: gains.count) }
                    .buttonStyle(.plain).font(.system(size: 10, weight: .medium)).foregroundStyle(Theme.purple)
                    .disabled(gains.allSatisfy { $0 == 0 })
            }
            .frame(height: 28, alignment: .top)
            HStack(spacing: 0) {
                ForEach(EQSettings.bands.indices, id: \.self) { i in
                    VStack(spacing: 3) {
                        BandSlider(gain: Binding(get: { gains[i] }, set: { gains[i] = $0 }),
                                   onActive: { focus = $0 ? i : focus })
                            .frame(height: 84)
                        Text(EQSettings.bands[i].short).font(.system(size: 8).monospacedDigit()).foregroundStyle(Theme.secondary)
                    }
                    .frame(maxWidth: .infinity)
                    .contentShape(Rectangle())
                    .onHover { if $0 { focus = i } }
                    .help("\(EQSettings.bands[i].name) (\(Self.hz(EQSettings.bands[i].low))–\(Self.hz(EQSettings.bands[i].high))): \(EQSettings.bands[i].sound). Double-click to reset.")
                }
            }
        }
    }

    static func hz(_ f: Float) -> String { f >= 1000 ? String(format: f.truncatingRemainder(dividingBy: 1000) == 0 ? "%.0f kHz" : "%.1f kHz", f / 1000) : String(format: "%.0f Hz", f) }
}

/// A small vertical ±12 dB slider: the bar grows up or down from the 0 dB line.
struct BandSlider: View {
    @Binding var gain: Float
    var onActive: (Bool) -> Void = { _ in }

    var body: some View {
        GeometryReader { geo in
            let h = geo.size.height, r = EQSettings.range
            let y = { (g: Float) in CGFloat((r.upperBound - g) / (r.upperBound - r.lowerBound)) * (h - 10) + 5 }
            let mid = y(0), pos = y(gain)
            ZStack(alignment: .top) {
                Capsule().fill(Color.black.opacity(0.08)).frame(width: 3)
                Rectangle().fill(Theme.border).frame(width: 9, height: 1).offset(y: mid)
                Rectangle().fill(Theme.purple.opacity(0.55)).frame(width: 3, height: abs(pos - mid)).offset(y: min(pos, mid))
                Circle().fill(gain == 0 ? .white : Theme.purple).frame(width: 10, height: 10)
                    .overlay(Circle().strokeBorder(Theme.purple, lineWidth: 1.5))
                    .offset(y: pos - 5)
            }
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { v in
                    onActive(true)
                    let t = Float((v.location.y - 5) / (h - 10))
                    let g = r.upperBound - t * (r.upperBound - r.lowerBound)
                    gain = (min(r.upperBound, max(r.lowerBound, g)) * 2).rounded() / 2   // 0.5 dB steps
                })
            .onTapGesture(count: 2) { gain = 0 }
        }
    }
}
