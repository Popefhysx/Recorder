import SwiftUI

/// Left column (track cards + inspector) and the timeline share one vertical scroll so cards
/// line up with their lanes; the lanes scroll sideways on their own.
struct TimelineArea: View {
    @EnvironmentObject private var session: Session
    var focusKeys: () -> Void
    @State private var scroll = ScrollPosition(edge: .leading)
    @State private var visibleX: CGFloat = 0
    @State private var visibleWidth: CGFloat = 600

    var body: some View {
        let pps = session.pointsPerSecond
        let contentWidth = max(visibleWidth, CGFloat(max(session.project.duration, session.project.loopEnd) + 60) * pps)
        GeometryReader { geo in
            ScrollView(.vertical) {
                HStack(alignment: .top, spacing: 0) {
                    sidebar
                        .frame(width: Layout.sidebarWidth)
                        .padding(.horizontal, 12)
                    ScrollView(.horizontal) {
                        ZStack(alignment: .topLeading) {
                            VStack(spacing: 0) {
                                Ruler(width: contentWidth, focusKeys: focusKeys)
                                ForEach(session.project.tracks) { track in
                                    Lane(track: track, width: contentWidth, focusKeys: focusKeys)
                                }
                                Color.clear.frame(height: 1)
                            }
                            Playhead()
                        }
                        .frame(width: contentWidth, alignment: .topLeading)
                        .frame(minHeight: geo.size.height, alignment: .top)
                    }
                    .scrollPosition($scroll)
                    .onScrollGeometryChange(for: CGRect.self) { $0.visibleRect } action: { _, rect in
                        visibleX = rect.minX
                        visibleWidth = rect.width
                    }
                    .background(Color.white.opacity(0.55))
                    .overlay(alignment: .leading) { Rectangle().fill(Theme.border).frame(width: 1) }
                }
                .frame(minHeight: geo.size.height, alignment: .top)
            }
        }
        .onReceive(session.clock.$position) { t in
            // Page the view along with the playhead while the transport runs.
            guard session.isPlaying else { return }
            let x = CGFloat(t) * pps
            if x > visibleX + visibleWidth - 30 || x < visibleX {
                scroll.scrollTo(x: max(0, x - 40))
            }
        }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Tracks").font(.system(size: 18, weight: .bold))
                Spacer()
                Button { session.addTrack() } label: {
                    Label("Add", systemImage: "plus").font(.system(size: 13, weight: .medium))
                        .padding(.horizontal, 12).frame(height: 30)
                        .foregroundStyle(Theme.purple)
                        .background(Capsule().fill(Theme.purpleSoft))
                }
                .buttonStyle(.plain)
                .help("Add a track (⇧⌘T)")
            }
            .frame(height: Layout.rulerHeight)
            ForEach(session.project.tracks) { track in
                TrackCard(track: session.trackBinding(track.id))
            }
        }
    }
}

struct Ruler: View {
    @EnvironmentObject private var session: Session
    let width: CGFloat
    var focusKeys: () -> Void

    var body: some View {
        let pps = session.pointsPerSecond
        let loopStart = session.project.loopStart, loopEnd = session.project.loopEnd, loopOn = session.project.loopEnabled
        let bars = session.project.snap || session.project.metronome
        let beat = session.project.beatLength, perBar = session.project.beatsPerBar
        Canvas { ctx, size in
            if bars {
                // Bars and beats: number every bar (or every few bars when zoomed out).
                let barPts = beat * Double(perBar) * pps
                let every = max(1, Int((70 / barPts).rounded(.up)))
                var b = 0
                while Double(b) * beat * pps < size.width {
                    let x = Double(b) * beat * pps + 12
                    let isBar = b % perBar == 0
                    let bar = b / perBar
                    if isBar || beat * pps > 12 {
                        ctx.fill(Path(CGRect(x: x, y: isBar ? 36 : 44, width: 1, height: isBar ? 16 : 8)),
                                 with: .color(Theme.secondary.opacity(isBar ? 0.8 : 0.45)))
                    }
                    if isBar && bar % every == 0 {
                        ctx.draw(Text("\(bar + 1)").font(.system(size: 13, weight: .medium)).foregroundStyle(Theme.text),
                                 at: CGPoint(x: x + 3, y: 22), anchor: .leading)
                    }
                    b += 1
                }
                if loopOn {
                    ctx.fill(Path(roundedRect: CGRect(x: loopStart * pps + 12, y: size.height - 10, width: (loopEnd - loopStart) * pps, height: 6),
                                  cornerRadius: 3), with: .color(Theme.purple.opacity(0.45)))
                }
                ctx.fill(Path(CGRect(x: 0, y: size.height - 1, width: size.width, height: 1)), with: .color(Theme.border))
                return
            }
            if loopOn {
                ctx.fill(Path(roundedRect: CGRect(x: loopStart * pps, y: size.height - 10, width: (loopEnd - loopStart) * pps, height: 6),
                              cornerRadius: 3), with: .color(Theme.purple.opacity(0.45)))
            }
            let step = Self.labelStep(pps)
            let minor = step / (step >= 5 ? 5 : 4)
            var i = 0
            while Double(i) * minor * pps < size.width {
                let t = Double(i) * minor
                let x = t * pps + 12
                let major = i % Int((step / minor).rounded()) == 0
                ctx.fill(Path(CGRect(x: x, y: major ? 36 : 44, width: 1, height: major ? 16 : 8)),
                         with: .color(Theme.secondary.opacity(major ? 0.8 : 0.45)))
                if major {
                    ctx.draw(Text(TimeDisplay.format(t).dropLast(4)).font(.system(size: 13, weight: .medium)).foregroundStyle(Theme.text),
                             at: CGPoint(x: x, y: 22), anchor: .center)
                }
                i += 1
            }
            ctx.fill(Path(CGRect(x: 0, y: size.height - 1, width: size.width, height: 1)), with: .color(Theme.border))
        }
        .frame(width: width, height: Layout.rulerHeight)
        .contentShape(Rectangle())
        .gesture(SpatialTapGesture().onEnded { v in
            focusKeys()
            session.setPosition(session.project.snapped((v.location.x - 12) / pps))
        })
        .help("Click to move the playhead")
    }

    static func labelStep(_ pps: Double) -> Double {
        for s in [0.5, 1, 2, 5, 10, 15, 30, 60, 120] where s * pps >= 80 { return s }
        return 300
    }
}

/// Lanes start 12 pt in so the playhead handle isn't clipped at 0:00.
let laneInset: CGFloat = 12

struct Playhead: View {
    @EnvironmentObject private var clock: Clock
    @EnvironmentObject private var session: Session
    var body: some View {
        let color = session.isRecording ? Theme.record : Theme.purple
        VStack(spacing: 0) {
            Color.clear.frame(height: Layout.rulerHeight - 18)
            PlayheadHandle().fill(color).frame(width: 16, height: 14)
            Rectangle().fill(color).frame(width: 2).frame(maxHeight: .infinity)
        }
        .frame(width: 16)
        .offset(x: CGFloat(clock.position) * session.pointsPerSecond + laneInset - 8)
        .allowsHitTesting(false)
    }
}

struct PlayheadHandle: Shape {
    func path(in r: CGRect) -> Path {
        var p = Path()
        p.addRoundedRect(in: CGRect(x: r.minX, y: r.minY, width: r.width, height: r.height * 0.45), cornerSize: CGSize(width: 3, height: 3))
        p.move(to: CGPoint(x: r.minX, y: r.minY + r.height * 0.4))
        p.addLine(to: CGPoint(x: r.maxX, y: r.minY + r.height * 0.4))
        p.addLine(to: CGPoint(x: r.midX, y: r.maxY))
        p.closeSubpath()
        return p
    }
}

struct Lane: View {
    @EnvironmentObject private var session: Session
    @EnvironmentObject private var levels: Levels
    let track: Track
    let width: CGFloat
    var focusKeys: () -> Void
    @State private var targeted = false

    var body: some View {
        let pps = session.pointsPerSecond
        ZStack(alignment: .topLeading) {
            Rectangle().fill(session.selectedTrack == track.id ? Theme.purple.opacity(0.035) : Color.clear)
                .overlay {
                    if session.project.snap || session.project.metronome {
                        let bar = session.project.barLength * pps
                        Canvas { ctx, size in
                            guard bar > 6 else { return }
                            var x = laneInset
                            while x < size.width {
                                ctx.fill(Path(CGRect(x: x, y: 0, width: 1, height: size.height)), with: .color(Theme.border))
                                x += bar
                            }
                        }
                        .allowsHitTesting(false)
                    }
                }
                .contentShape(Rectangle())
                .gesture(SpatialTapGesture().onEnded { v in
                    focusKeys()
                    session.selection = nil
                    session.selectedTrack = track.id
                    session.setPosition((v.location.x - laneInset) / pps)
                })
            ForEach(track.clips) { clip in
                ClipView(clip: clip, trackID: track.id, focusKeys: focusKeys)
            }
            if let live = levels.live[track.id] {
                LiveTake(peaks: live, start: session.recordStart, pps: pps, boost: Double(track.boostGain))
            }
        }
        .frame(width: width, height: Layout.rowHeight)
        .clipped()
        .dropDestination(for: URL.self) { urls, location in
            session.importAudio(urls, track: track.id, at: session.project.snapped(max(0, (location.x - laneInset) / pps)))
            return true
        } isTargeted: { targeted = $0 }
        .overlay { if targeted { RoundedRectangle(cornerRadius: 12).strokeBorder(Theme.purple, style: StrokeStyle(lineWidth: 2, dash: [6, 4])) } }
    }
}

/// The waveform of a take while it is being recorded.
struct LiveTake: View {
    let peaks: [Float]
    let start: Double
    let pps: Double
    var boost: Double = 1
    var body: some View {
        let seconds = Double(peaks.count * InputRecorder.peakBlock) / Formats.rate
        Canvas { ctx, size in
            drawPeaks(ctx, size: size, peaks: peaks, fileStart: 0, pps: pps, color: Theme.record, gain: { _ in sqrt(boost) })
        }
        .frame(width: max(1, seconds * pps), height: Layout.rowHeight - 12)
        .background(RoundedRectangle(cornerRadius: 12).fill(Theme.record.opacity(0.1)))
        .offset(x: start * pps + laneInset, y: 6)
        .allowsHitTesting(false)
    }
}

/// Draws the waveform as mirrored rounded bars; `gain` maps clip-relative seconds to a display gain (fades).
func drawPeaks(_ ctx: GraphicsContext, size: CGSize, peaks: [Float], fileStart: Double, pps: Double,
               color: Color, gain: (Double) -> Double) {
    guard !peaks.isEmpty else { return }
    let perSecond = Formats.rate / Double(InputRecorder.peakBlock)
    let mid = size.height / 2
    let pitch: CGFloat = 3.5, bar: CGFloat = 2
    var path = Path()
    var x: CGFloat = 4
    while x < size.width - 4 {
        let t0 = Double(x) / pps, t1 = Double(x + pitch) / pps
        let i0 = Int((fileStart + t0) * perSecond), i1 = max(i0 + 1, Int((fileStart + t1) * perSecond))
        guard i0 < peaks.count else { break }
        var p: Float = 0
        for i in max(0, i0)..<min(i1, peaks.count) { p = max(p, peaks[i]) }
        let h = max(1, CGFloat(min(1, sqrt(Double(p)) * gain(t0))) * (mid - 8))   // sqrt makes quiet takes visible
        path.addRoundedRect(in: CGRect(x: x, y: mid - h, width: bar, height: h * 2), cornerSize: CGSize(width: 1, height: 1))
        x += pitch
    }
    ctx.fill(path, with: .color(color))
}

struct ClipView: View {
    @EnvironmentObject private var session: Session
    @EnvironmentObject private var waveforms: Waveforms
    let clip: Clip
    let trackID: UUID
    var focusKeys: () -> Void
    @State private var origin: Clip?

    private var ref: ClipRef { ClipRef(track: trackID, clip: clip.id) }

    var body: some View {
        let pps = session.pointsPerSecond
        let selected = session.selection == ref
        let w = max(6, clip.duration * pps)
        let h = Layout.rowHeight - 12
        let peaks = waveforms.peaks[clip.file] ?? []
        let c = clip
        let boost = sqrt(Double(session.project.tracks.first { $0.id == trackID }?.boostGain ?? 1))
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 12).fill(Theme.lavender)
            Canvas { ctx, size in
                drawPeaks(ctx, size: size, peaks: peaks, fileStart: c.offset, pps: pps, color: Theme.purple) { t in
                    var g = boost
                    if c.fadeIn > 0, t < c.fadeIn { g *= t / c.fadeIn }
                    if c.fadeOut > 0, t > c.duration - c.fadeOut { g *= max(0, (c.duration - t) / c.fadeOut) }
                    return g
                }
                var fade = Path()
                if c.fadeIn > 0 { fade.move(to: CGPoint(x: 0, y: size.height)); fade.addLine(to: CGPoint(x: c.fadeIn * pps, y: 0)) }
                if c.fadeOut > 0 {
                    fade.move(to: CGPoint(x: size.width - c.fadeOut * pps, y: 0)); fade.addLine(to: CGPoint(x: size.width, y: size.height))
                }
                ctx.stroke(fade, with: .color(Theme.purple.opacity(0.6)), style: StrokeStyle(lineWidth: 1.5, dash: [4, 3]))
            }
            .allowsHitTesting(false)
            RoundedRectangle(cornerRadius: 12).strokeBorder(selected ? Theme.purple : .clear, lineWidth: 1.5)
                .allowsHitTesting(false)

            // Edge handles trim, corner dots set fades.
            HStack(spacing: 0) {
                handle(.trimStart).frame(width: 7)
                Spacer(minLength: 0)
                handle(.trimEnd).frame(width: 7)
            }
            if let done = c.processing, !done.isEmpty {
                Label(done.summary, systemImage: "sparkles").font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Theme.purple).padding(.horizontal, 6).frame(height: 16)
                    .background(Capsule().fill(.white.opacity(0.85)))
                    .offset(x: 18, y: h - 22).allowsHitTesting(false)
            }
            fadeHandle(.fadeIn).offset(x: min(w - 14, c.fadeIn * pps + 3), y: 3)
            fadeHandle(.fadeOut).offset(x: max(0, w - 14 - c.fadeOut * pps - 3), y: 3)
        }
        .frame(width: w, height: h)
        .contentShape(Rectangle())
        .gesture(dragGesture(.move))
        .simultaneousGesture(TapGesture().onEnded { select() })
        .contextMenu {
            Button("Split at Playhead") { session.selection = ref; session.splitAtPlayhead() }
            Button("Delete Clip") { session.selection = ref; session.deleteSelectedClip() }
            Button("Remove Fades") { session.updateClip(ref) { $0.fadeIn = 0; $0.fadeOut = 0 } }
            Divider()
            Button("Remove Silence…") { session.selection = ref; session.silenceTarget = ref }
            Divider()
            Button("Clean Up & Enhance…") { session.selection = ref; session.processTarget = .init(ref: ref) }
            Button("Denoise…") { session.selection = ref; session.processTarget = .init(ref: ref, preset: .denoise) }
            Button("Voice Clean…") { session.selection = ref; session.processTarget = .init(ref: ref, preset: .voiceClean) }
            Button("Enhance Voice…") { session.selection = ref; session.processTarget = .init(ref: ref, preset: .enhance) }
            if clip.originalFile != nil { Button("Remove Clean-Up & Enhance") { session.removeProcessing(ref) } }
        }
        .offset(x: clip.start * pps + laneInset, y: 6)
        .onAppear { if let audio = session.audioFolder { waveforms.load(clip.file, folder: audio) } }
        .help("Drag to move. Drag the edges to trim and the dots to fade. S splits at the playhead.")
    }

    private enum Edit { case move, trimStart, trimEnd, fadeIn, fadeOut }

    private func select() {
        focusKeys()
        session.selection = ref
        session.selectedTrack = trackID
    }

    private func handle(_ edit: Edit) -> some View {
        Rectangle().fill(Color.white.opacity(0.001))
            .frame(maxHeight: .infinity)
            .onHover { inside in if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() } }
            .gesture(dragGesture(edit))
    }

    private func fadeHandle(_ edit: Edit) -> some View {
        Circle().fill(.white).frame(width: 11, height: 11)
            .overlay(Circle().strokeBorder(Theme.purple, lineWidth: 2))
            .gesture(dragGesture(edit))
    }

    private func dragGesture(_ edit: Edit) -> some Gesture {
        DragGesture(minimumDistance: 2, coordinateSpace: .global)
            .onChanged { v in
                if origin == nil { origin = clip; select() }
                guard let o = origin else { return }
                let d = v.translation.width / session.pointsPerSecond
                session.updateClip(ref) { c in
                    switch edit {
                    case .move: c.start = max(0, session.project.snapped(o.start + d))
                    case .trimStart:
                        let delta = min(max(session.project.snapped(o.start + d) - o.start, -o.offset), o.duration - 0.05)
                        c.offset = o.offset + delta; c.start = o.start + delta; c.duration = o.duration - delta
                        if c.start < 0 { c.offset -= c.start; c.duration += c.start; c.start = 0 }
                    case .trimEnd: c.duration = max(0.05, session.project.snapped(o.end + d) - o.start)
                    case .fadeIn: c.fadeIn = max(0, o.fadeIn + d)
                    case .fadeOut: c.fadeOut = max(0, o.fadeOut - d)
                    }
                }
            }
            .onEnded { _ in origin = nil }
    }
}
