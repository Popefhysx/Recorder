import SwiftUI

/// Auto-edit: cut the silent stretches out of clips. Non-destructive: each clip becomes several
/// clips over the same recording (with short fades so the cuts don't click), so undo, or dragging
/// a clip's edge, brings anything back. Optionally closes the gaps, pulling everything after each
/// cut earlier on the track.
struct SilenceSettings: Equatable {
    var threshold: Float = -50        // dB; quieter than this counts as silence
    var minSilence: Double = 0.5      // seconds; shorter pauses are left alone
    var keep: Double = 0.15           // seconds kept either side of the sound, so words aren't clipped
    var closeGaps = false
    var wholeTrack = false
}

enum SilenceRemoval {
    static let block = Double(InputRecorder.peakBlock) / Formats.rate      // one waveform point

    /// Parts of the clip to keep, in clip-relative seconds.
    static func keptRanges(_ clip: Clip, peaks: [Float], _ s: SilenceSettings) -> [Range<Double>] {
        let first = Int(clip.offset / block), count = Int((clip.duration / block).rounded(.up))
        guard count > 0, first < peaks.count else { return [0..<clip.duration] }
        let limit = pow(10, s.threshold / 20)
        let loud = (0..<count).map { i in first + i < peaks.count && peaks[first + i] > limit }
        var silences: [Range<Double>] = []
        var i = 0
        while i < count {
            guard !loud[i] else { i += 1; continue }
            var j = i
            while j < count && !loud[j] { j += 1 }
            let a = Double(i) * block, b = min(clip.duration, Double(j) * block)
            if b - a >= s.minSilence {
                // Keep a margin of the silence next to sound; a silence at the very start or end
                // only needs the margin on its sound side.
                let start = i == 0 ? 0 : a + s.keep, end = j >= count ? clip.duration : b - s.keep
                if end > start { silences.append(start..<end) }
            }
            i = j
        }
        var kept: [Range<Double>] = []
        var cursor = 0.0
        for cut in silences {
            if cut.lowerBound > cursor { kept.append(cursor..<cut.lowerBound) }
            cursor = cut.upperBound
        }
        if cursor < clip.duration { kept.append(cursor..<clip.duration) }
        return kept.filter { $0.upperBound - $0.lowerBound >= 0.05 }   // drop stray clicks
    }

    /// Suggested threshold: 12 dB above the take's noise floor (its quietest 10%), within −70…−25 dB.
    static func autoThreshold(_ clip: Clip, peaks: [Float]) -> Float {
        let first = max(0, Int(clip.offset / block)), last = min(peaks.count, first + Int(clip.duration / block))
        guard last > first else { return -50 }
        let sorted = peaks[first..<last].filter { $0 > 1e-7 }.sorted()
        guard !sorted.isEmpty else { return -50 }
        let floor = 20 * log10(sorted[sorted.count / 10])
        return min(-25, max(-70, (floor + 12).rounded()))
    }
}

extension Session {
    /// What removing silence would do: (silent parts cut, seconds removed) or nil while the
    /// waveform is still being read.
    func silencePreview(_ ref: ClipRef, _ s: SilenceSettings) -> (cuts: Int, seconds: Double)? {
        var cuts = 0, seconds = 0.0
        for c in silenceTargets(ref, s) {
            guard let peaks = waveforms.peaks[c.file] else { return nil }
            let kept = SilenceRemoval.keptRanges(c, peaks: peaks, s)
            let total = kept.reduce(0) { $0 + $1.upperBound - $1.lowerBound }
            seconds += c.duration - total
            let leading = (kept.first?.lowerBound ?? 1) > 0, trailing = (kept.last?.upperBound ?? 0) < c.duration
            cuts += max(0, kept.count - 1) + (leading ? 1 : 0) + (trailing && !kept.isEmpty ? 1 : 0)
        }
        return (cuts, seconds)
    }

    private func silenceTargets(_ ref: ClipRef, _ s: SilenceSettings) -> [Clip] {
        guard let track = project.tracks.first(where: { $0.id == ref.track }) else { return [] }
        return s.wholeTrack ? track.clips : track.clips.filter { $0.id == ref.clip }
    }

    /// One click: automatic threshold, default pause length and margin, gaps left in place.
    func removeSilenceAutomatically(_ ref: ClipRef) {
        guard let c = clip(ref), let peaks = waveforms.peaks[c.file] else { problem = "Still reading this clip's waveform. Try again in a moment."; return }
        var s = SilenceSettings()
        s.threshold = SilenceRemoval.autoThreshold(c, peaks: peaks)
        guard let preview = silencePreview(ref, s), preview.cuts > 0 else { problem = "No silence long enough to cut in this clip."; return }
        removeSilence(ref, s)
        problem = String(format: "Cut %d silent part%@ (%.1f s). ⌘Z to undo; Track › Remove Silence… has options.", preview.cuts, preview.cuts == 1 ? "" : "s", preview.seconds)
    }

    func removeSilence(_ ref: ClipRef, _ s: SilenceSettings) {
        guard !isRecording, let t = index(of: ref.track) else { return }
        let targets = Set(silenceTargets(ref, s).map(\.id))
        let fade = 0.01
        var out: [Clip] = []
        var removedBefore: [(at: Double, amount: Double)] = []      // for closing gaps
        for clip in project.tracks[t].clips.sorted(by: { $0.start < $1.start }) {
            guard targets.contains(clip.id), let peaks = waveforms.peaks[clip.file] else { out.append(clip); continue }
            let kept = SilenceRemoval.keptRanges(clip, peaks: peaks, s)
            guard !(kept.count == 1 && kept[0] == 0..<clip.duration) else { out.append(clip); continue }
            var cursor = 0.0
            for (n, r) in kept.enumerated() {
                if r.lowerBound > cursor { removedBefore.append((clip.start + cursor, r.lowerBound - cursor)) }
                cursor = r.upperBound
                var piece = clip
                piece.id = n == 0 ? clip.id : UUID()
                piece.start = clip.start + r.lowerBound
                piece.offset = clip.offset + r.lowerBound
                piece.duration = r.upperBound - r.lowerBound
                piece.fadeIn = r.lowerBound == 0 ? clip.fadeIn : min(fade, piece.duration / 4)
                piece.fadeOut = r.upperBound >= clip.duration ? clip.fadeOut : min(fade * 3, piece.duration / 4)
                piece.normalize()
                out.append(piece)
            }
            if cursor < clip.duration { removedBefore.append((clip.start + cursor, clip.duration - cursor)) }
        }
        if s.closeGaps {
            out = out.map { c in
                var c = c
                c.start -= removedBefore.filter { $0.at < c.start + 1e-9 }.reduce(0) { $0 + $1.amount }
                c.start = max(0, c.start)
                return c
            }
        }
        asOneUndoStep { project.tracks[t].clips = out }
        if !targets.contains(selection?.clip ?? UUID()) { selection = nil }
    }
}

/// Settings for Remove Silence, with a live count of what it will cut.
struct SilenceSheet: View {
    @EnvironmentObject private var session: Session
    @EnvironmentObject private var waveforms: Waveforms
    let ref: ClipRef
    @State private var s = SilenceSettings()

    var body: some View {
        let preview = session.silencePreview(ref, s)
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                Image(systemName: "scissors").foregroundStyle(Theme.purple)
                Text("Remove Silence").font(.system(size: 16, weight: .semibold))
            }
            Text("Cuts out the quiet parts. Nothing is deleted from your recording: undo (⌘Z), or drag a clip's edge, to bring any of it back.")
                .font(.system(size: 11)).foregroundStyle(Theme.secondary).fixedSize(horizontal: false, vertical: true)
            slider("Silence is quieter than", value: Binding(get: { Double(s.threshold) }, set: { s.threshold = Float($0.rounded()) }),
                   in: -70...(-20), text: String(format: "%.0f dB", s.threshold),
                   hint: "Set automatically from this take's background noise. Raise it if breaths or hiss stay in.")
            slider("Shortest pause to cut", value: $s.minSilence, in: 0.2...3, text: String(format: "%.1f s", s.minSilence),
                   hint: "Shorter pauses, like between words, are left alone.")
            slider("Keep around the sound", value: $s.keep, in: 0.02...0.5, text: String(format: "%.2f s", s.keep),
                   hint: "So the start and end of words aren't clipped.")
            Toggle("Close the gaps (move later clips earlier)", isOn: $s.closeGaps).font(.system(size: 12))
            Toggle("All clips on this track", isOn: $s.wholeTrack).font(.system(size: 12))
            Group {
                if let p = preview {
                    Text(p.cuts == 0 ? "No silence found with these settings."
                         : String(format: "Cuts %d silent part%@, %.1f s in total.", p.cuts, p.cuts == 1 ? "" : "s", p.seconds))
                } else {
                    Text("Reading the waveform…")
                }
            }
            .font(.system(size: 12, weight: .medium)).foregroundStyle(Theme.purple)
            HStack {
                Spacer()
                Button("Cancel") { session.silenceTarget = nil }.keyboardShortcut(.cancelAction)
                Button("Remove Silence") { session.removeSilence(ref, s); session.silenceTarget = nil }
                    .keyboardShortcut(.defaultAction).disabled((preview?.cuts ?? 0) == 0)
            }
        }
        .padding(20)
        .frame(width: 400)
        .onAppear {
            if let c = session.clip(ref), let peaks = waveforms.peaks[c.file] {
                s.threshold = SilenceRemoval.autoThreshold(c, peaks: peaks)
            }
        }
    }

    private func slider(_ label: String, value: Binding<Double>, in range: ClosedRange<Double>, text: String, hint: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(label).font(.system(size: 12, weight: .medium))
                Spacer()
                Text(text).font(.system(size: 12).monospacedDigit())
            }
            Slider(value: value, in: range)
            Text(hint).font(.system(size: 11)).foregroundStyle(Theme.secondary)
        }
    }
}
