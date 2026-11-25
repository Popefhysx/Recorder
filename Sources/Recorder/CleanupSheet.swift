import SwiftUI

/// Noise clean-up for one clip: Denoise (learned noise print, for steady hiss and hum) or
/// Voice Clean (DeepFilterNet, for any noise behind a voice). Both keep the original.
struct CleanupSheet: View {
    @EnvironmentObject private var session: Session
    let ref: ClipRef
    @State var tool: CleanupTool
    @AppStorage("denoiseReduction") private var reduction: Double = 15
    @AppStorage("voiceCleanStrength") private var strength: Double = Double(VoiceClean.maxStrength)
    @State private var fromLoop = false

    var body: some View {
        let clip = session.clip(ref)
        let busy = session.cleanupProgress != nil
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                Image(systemName: "sparkles").foregroundStyle(Theme.purple)
                Text("Clean Up Noise").font(.system(size: 16, weight: .semibold))
            }
            Picker("", selection: $tool) {
                Text("Denoise").tag(CleanupTool.denoise)
                Text("Voice Clean").tag(CleanupTool.voiceClean)
            }
            .pickerStyle(.segmented).labelsHidden().disabled(busy)

            switch tool {
            case .denoise: denoiseOptions
            case .voiceClean: voiceCleanOptions
            }

            Text("Your original recording is kept; Remove Clean-up brings it back.")
                .font(.system(size: 11)).foregroundStyle(Theme.secondary)

            if busy {
                if tool == .denoise, let p = session.cleanupProgress {
                    ProgressView(value: p) { Text("Denoising…").font(.system(size: 11)) }
                } else {
                    ProgressView { Text("Cleaning the voice…").font(.system(size: 11)) }
                }
            }

            HStack {
                if let c = clip, let used = c.cleanup {
                    Button("Remove \(used.title)") { session.removeCleanup(ref); session.cleanupTarget = nil }
                        .disabled(busy)
                }
                Spacer()
                Button("Cancel") { session.cleanupTarget = nil }
                    .keyboardShortcut(.cancelAction).disabled(busy)
                Button(tool.title) { run() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(busy || clip == nil || !ready)
            }
        }
        .padding(20)
        .frame(width: 400)
        .onAppear { fromLoop = session.loopNoiseRange(ref) != nil && session.project.loopEnabled }
    }

    private var ready: Bool {
        switch tool {
        case .denoise: !fromLoop || session.loopNoiseRange(ref) != nil
        case .voiceClean: VoiceClean.tool != nil
        }
    }

    private func run() {
        let how: Session.Cleanup = tool == .denoise
            ? .denoise(reduction: Float(reduction), fromLoop: fromLoop)
            : .voiceClean(strength: Float(strength))
        session.cleanUp(ref, how) { ok in if ok { session.cleanupTarget = nil } }
    }

    private var denoiseOptions: some View {
        VStack(alignment: .leading, spacing: 12) {
            note("Learns the noise and removes it everywhere. Best for steady hiss, hum and fans.")
            VStack(alignment: .leading, spacing: 6) {
                Text("Learn the noise from").font(.system(size: 12, weight: .medium))
                Picker("", selection: $fromLoop) {
                    Text("Quiet parts (automatic)").tag(false)
                    Text("Loop region").tag(true)
                }
                .pickerStyle(.radioGroup).labelsHidden()
                note(session.loopNoiseRange(ref) != nil
                     ? "Loop region: set the loop over a stretch with no voice, just the noise, for the most accurate result."
                     : "To choose the noise yourself, set the loop region over a noise-only part of this clip.")
            }
            slider("Reduction", value: $reduction, in: 6...30, text: String(format: "%.0f dB", reduction),
                   hint: "Higher removes more noise. Too high can make the voice sound thin or watery.")
        }
    }

    private var voiceCleanOptions: some View {
        VStack(alignment: .leading, spacing: 12) {
            note("AI that keeps the voice and removes everything else: hiss, hum, room, traffic, keyboard. Needs no noise sample. Made for speech and singing; it will also remove instruments.")
            if VoiceClean.tool == nil {
                note("Voice Clean isn't installed in this copy of Recorder. Rebuild it with build.sh while online.")
                    .foregroundStyle(Theme.record)
            }
            slider("Strength", value: $strength, in: 10...Double(VoiceClean.maxStrength),
                   text: strength >= Double(VoiceClean.maxStrength) ? "Max" : String(format: "%.0f dB", strength),
                   hint: "How far the noise may be turned down. Lower keeps a little of the room, which can sound more natural.")
        }
    }

    private func note(_ s: String) -> some View {
        Text(s).font(.system(size: 11)).foregroundStyle(Theme.secondary).fixedSize(horizontal: false, vertical: true)
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
