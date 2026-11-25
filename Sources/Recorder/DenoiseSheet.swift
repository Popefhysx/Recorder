import SwiftUI

/// Settings for denoising one clip: where to learn the noise, and how hard to reduce it.
struct DenoiseSheet: View {
    @EnvironmentObject private var session: Session
    let ref: ClipRef
    @AppStorage("denoiseReduction") private var reduction: Double = 15
    @State private var fromLoop = false

    var body: some View {
        let clip = session.clip(ref)
        let loopFits = session.loopNoiseRange(ref) != nil
        let busy = session.denoiseProgress != nil
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                Image(systemName: "sparkles").foregroundStyle(Theme.purple)
                Text("Denoise").font(.system(size: 16, weight: .semibold))
            }
            Text("Removes steady background noise (hiss, hum, fans) from this clip. Your original recording is kept, and Remove Denoise brings it back.")
                .font(.system(size: 12)).foregroundStyle(Theme.secondary).fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: 6) {
                Text("Learn the noise from").font(.system(size: 12, weight: .medium))
                Picker("", selection: $fromLoop) {
                    Text("Quiet parts (automatic)").tag(false)
                    Text("Loop region").tag(true)
                }
                .pickerStyle(.radioGroup).labelsHidden()
                Text(loopFits
                     ? "Loop region: set the loop over a stretch with no voice, just the noise, for the most accurate result."
                     : "To choose the noise yourself, set the loop region over a noise-only part of this clip.")
                    .font(.system(size: 11)).foregroundStyle(Theme.secondary).fixedSize(horizontal: false, vertical: true)
            }

            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("Reduction").font(.system(size: 12, weight: .medium))
                    Spacer()
                    Text(String(format: "%.0f dB", reduction)).font(.system(size: 12).monospacedDigit())
                }
                Slider(value: $reduction, in: 6...30)
                Text("Higher removes more noise. Too high can make the voice sound thin or watery.")
                    .font(.system(size: 11)).foregroundStyle(Theme.secondary)
            }

            if let p = session.denoiseProgress {
                ProgressView(value: p) { Text("Denoising…").font(.system(size: 11)) }
            }

            HStack {
                if clip?.originalFile != nil {
                    Button("Remove Denoise") { session.removeDenoise(ref); session.denoiseTarget = nil }
                        .disabled(busy)
                }
                Spacer()
                Button("Cancel") { session.denoiseTarget = nil }
                    .keyboardShortcut(.cancelAction).disabled(busy)
                Button("Denoise") {
                    session.denoise(ref, reduction: Float(reduction), fromLoop: fromLoop) { ok in
                        if ok { session.denoiseTarget = nil }
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(busy || clip == nil || (fromLoop && !loopFits))
            }
        }
        .padding(20)
        .frame(width: 380)
        .onAppear { fromLoop = loopFits && session.project.loopEnabled }
    }
}
