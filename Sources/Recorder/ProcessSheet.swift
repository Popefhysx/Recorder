import SwiftUI

/// Clean Up & Enhance for one clip: noise removal (Denoise or Voice Clean), voice enhancement and
/// volume, applied in that order to the original recording. Opening it shows the clip's current
/// settings, so it's also where you change or remove them.
struct ProcessSheet: View {
    @EnvironmentObject private var session: Session
    let ref: ClipRef
    @State private var s: ClipProcessing
    @State private var fromLoop = false

    init(ref: ClipRef, current: ClipProcessing?) {
        self.ref = ref
        _s = State(initialValue: current ?? ClipProcessing())
    }

    var body: some View {
        let clip = session.clip(ref)
        let busy = session.processProgress != nil
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                Image(systemName: "sparkles").foregroundStyle(Theme.purple)
                Text("Custom Clean Up").font(.system(size: 16, weight: .semibold))
            }

            section("Noise") {
                Picker("", selection: $s.noise) {
                    Text("None").tag(CleanupTool?.none)
                    Text("Denoise").tag(CleanupTool?.some(.denoise))
                    Text("Voice Clean").tag(CleanupTool?.some(.voiceClean))
                }
                .pickerStyle(.segmented).labelsHidden()
                switch s.noise {
                case .denoise?: denoiseOptions
                case .voiceClean?: voiceCleanOptions
                case nil: note("Leaves the noise as recorded.")
                }
            }

            section("Voice") {
                Toggle(isOn: $s.enhance) { Text("Enhance voice").font(.system(size: 12, weight: .medium)) }
                note("Removes rumble and muddiness, adds presence and air, evens out the level, and brings it up to a strong, consistent loudness.")
            }

            section("Volume") {
                Picker("", selection: $s.volume) {
                    Text("Unchanged").tag(ClipProcessing.Volume.unchanged)
                    Text("Normalize").tag(ClipProcessing.Volume.normalize)
                    Text("Gain").tag(ClipProcessing.Volume.gain)
                }
                .pickerStyle(.segmented).labelsHidden()
                switch s.volume {
                case .unchanged: note(s.enhance ? "Enhance already sets a strong level." : "Keeps the recorded level.")
                case .normalize: note("As loud as it can go without distorting (peaks at −1 dB).")
                case .gain:
                    slider("Gain", value: Binding(get: { Double(s.gain) }, set: { s.gain = Float($0.rounded()) }), in: -12...24,
                           text: String(format: "%+.0f dB", s.gain),
                           hint: "A limiter stops loud parts from distorting, so big boosts stay clean.")
                }
            }

            note("Works from your original recording, which is always kept. Open this again to change the settings, or remove them all.")

            if busy, let p = session.processProgress {
                ProgressView(value: p) { Text("Processing…").font(.system(size: 11)) }
            }

            HStack {
                if clip?.originalFile != nil {
                    Button("Remove All") { session.removeProcessing(ref); session.processTarget = nil }.disabled(busy)
                }
                Spacer()
                Button("Cancel") { session.processTarget = nil }.keyboardShortcut(.cancelAction).disabled(busy)
                Button("Apply") {
                    session.process(ref, s, denoiseFromLoop: fromLoop) { ok in if ok { session.processTarget = nil } }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(busy || clip == nil || !ready)
            }
        }
        .padding(20)
        .frame(width: 420)
        .onAppear { fromLoop = session.loopNoiseRange(ref) != nil && session.project.loopEnabled }
    }

    private var ready: Bool {
        switch s.noise {
        case .denoise?: !fromLoop || session.loopNoiseRange(ref) != nil
        case .voiceClean?: VoiceClean.tool != nil
        case nil: true
        }
    }

    private var denoiseOptions: some View {
        VStack(alignment: .leading, spacing: 8) {
            note("Learns the noise and removes it everywhere. Best for steady hiss, hum and fans.")
            Picker("", selection: $fromLoop) {
                Text("Learn the noise from the quiet parts (automatic)").tag(false)
                Text("Learn it from the loop region").tag(true)
            }
            .pickerStyle(.radioGroup).labelsHidden().font(.system(size: 12))
            if fromLoop, session.loopNoiseRange(ref) == nil {
                note("Set the loop region over a noise-only part of this clip first.").foregroundStyle(Theme.record)
            }
            slider("Reduction", value: Binding(get: { Double(s.denoiseReduction) }, set: { s.denoiseReduction = Float($0) }), in: 6...30,
                   text: String(format: "%.0f dB", s.denoiseReduction),
                   hint: "Higher removes more. Too high can make the voice thin or watery.")
        }
    }

    private var voiceCleanOptions: some View {
        VStack(alignment: .leading, spacing: 8) {
            note("AI that keeps the voice and turns everything else down, steady or not: noise, room, and also claps and instruments, so it's for vocals and speech.")
            if VoiceClean.tool == nil {
                note("Voice Clean isn't installed in this copy of Recorder. Rebuild it with build.sh while online.").foregroundStyle(Theme.record)
            }
            slider("Strength", value: Binding(get: { Double(s.voiceStrength) }, set: { s.voiceStrength = Float($0) }),
                   in: 10...Double(VoiceClean.maxStrength),
                   text: s.voiceStrength >= VoiceClean.maxStrength ? "Max" : String(format: "%.0f dB", s.voiceStrength),
                   hint: s.voiceStrength >= VoiceClean.maxStrength
                       ? "Max removes everything that isn't voice, including claps and quiet word endings. Those parts become dead silence."
                       : "How far noise is turned down. 20–40 dB sounds natural and keeps quiet endings and claps; Max removes them.")
        }
    }

    private func section<Content: View>(_ title: String, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.purple)
            content()
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8).fill(Theme.lavender.opacity(0.45)))
    }

    private func note(_ text: String) -> some View {
        Text(text).font(.system(size: 11)).foregroundStyle(Theme.secondary).fixedSize(horizontal: false, vertical: true)
    }

    private func slider(_ label: String, value: Binding<Double>, in range: ClosedRange<Double>, text: String, hint: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(label).font(.system(size: 12, weight: .medium))
                Spacer()
                Text(text).font(.system(size: 12).monospacedDigit())
            }
            Slider(value: value, in: range)
            note(hint)
        }
    }
}
