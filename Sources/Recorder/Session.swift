import AppKit
import AVFoundation
import Combine
import SwiftUI
import UniformTypeIdentifiers

/// Fast-changing values live in their own objects so the whole timeline doesn't redraw 30×/s.
final class Clock: ObservableObject { @Published var position: Double = 0 }

final class Levels: ObservableObject {
    @Published var tracks: [UUID: Float] = [:]
    @Published var master: (Float, Float) = (0, 0)
    @Published var inputs: [Float] = []
    @Published var live: [UUID: [Float]] = [:]     // waveform points of takes being recorded
}

struct ClipRef: Equatable { var track: UUID; var clip: UUID }

final class Session: ObservableObject {
    @Published var project = Project() { didSet { recordUndo(oldValue); projectChanged(oldValue) } }

    // MARK: undo
    // Whole-project snapshots. Changes less than 0.6 s apart (a drag, a slider move) share one step.
    @Published private(set) var undoStack: [Project] = []
    @Published private(set) var redoStack: [Project] = []
    private var lastEdit = Date.distantPast
    private var restoring = false

    private func recordUndo(_ old: Project) {
        guard !restoring, old != project else { return }
        // Arming and monitoring are not edits worth undoing.
        var a = old, b = project
        for i in a.tracks.indices { a.tracks[i].armed = false; a.tracks[i].monitorOn = nil }
        for i in b.tracks.indices { b.tracks[i].armed = false; b.tracks[i].monitorOn = nil }
        guard a != b else { return }
        if Date().timeIntervalSince(lastEdit) > 0.6 {
            undoStack.append(old)
            if undoStack.count > 200 { undoStack.removeFirst() }
            redoStack.removeAll()
        }
        lastEdit = Date()
    }

    /// Makes `change` its own undo step, never merged with an edit just before or after it.
    /// For one-off commands (Remove Silence, clean-up) that can follow a drag within 0.6 s.
    func asOneUndoStep(_ change: () -> Void) {
        lastEdit = .distantPast
        change()
        lastEdit = .distantPast
    }

    var canUndo: Bool { !undoStack.isEmpty && !isRecording }
    var canRedo: Bool { !redoStack.isEmpty && !isRecording }

    func undo() {
        guard canUndo, let previous = undoStack.popLast() else { return }
        redoStack.append(project)
        restore(previous)
    }

    func redo() {
        guard canRedo, let next = redoStack.popLast() else { return }
        undoStack.append(project)
        restore(next)
    }

    /// Keeps the current arm/monitor state; only edits are rolled back.
    private func restore(_ snapshot: Project) {
        var p = snapshot
        for i in p.tracks.indices {
            if let live = project.tracks.first(where: { $0.id == p.tracks[i].id }) {
                p.tracks[i].armed = live.armed; p.tracks[i].monitorOn = live.monitorOn
            } else {
                p.tracks[i].armed = false; p.tracks[i].monitorOn = nil
            }
        }
        restoring = true
        project = p
        restoring = false
        lastEdit = .distantPast
        if let sel = selection, index(of: sel.track).map({ project.tracks[$0].clips.contains { $0.id == sel.clip } }) != true {
            selection = nil
        }
        if let audio = audioFolder { for c in project.tracks.flatMap(\.clips) { waveforms.load(c.file, folder: audio) } }
    }
    @Published var folder: URL?                      // project folder; Audio/ lives inside it
    @Published var isUntitled = true
    @Published private(set) var savedProject = Project()
    @Published var selection: ClipRef?
    @Published var selectedTrack: UUID?
    @Published private(set) var isPlaying = false
    @Published private(set) var isRecording = false
    @Published var devices: [InputDevice] = []
    @Published var preferredInputUID: String? = UserDefaults.standard.string(forKey: "inputUID") {
        didSet { UserDefaults.standard.set(preferredInputUID, forKey: "inputUID"); refreshInput() }
    }
    @Published var outputs: [InputDevice] = []
    /// The input switched off by the user: no mic, meters or monitoring, so the interface makes no
    /// noise. Arming a track or pressing Listen switches it back on.
    @Published var inputOff = UserDefaults.standard.bool(forKey: "inputOff") {
        didSet { if inputOff != oldValue { UserDefaults.standard.set(inputOff, forKey: "inputOff"); refreshInput() } }
    }

    func toggleInput() {
        if inputOff { inputOff = false; return }
        if isRecording { problem = "Stop recording before switching the input off."; return }
        for i in project.tracks.indices { project.tracks[i].armed = false; project.tracks[i].monitor = false }
        inputOff = true
    }

    @Published var preferredOutputUID: String? = UserDefaults.standard.string(forKey: "outputUID") {
        didSet { UserDefaults.standard.set(preferredOutputUID, forKey: "outputUID"); applyOutput(force: true) }
    }
    @Published private(set) var inputName = "—"
    @Published private(set) var inputChannels = 2
    @Published var problem: String?
    @Published var pointsPerSecond: Double = 80
    @Published var recordStart: Double = 0
    /// Loudest level seen on each input during the current take, for the "no sound on this input" warning.
    private var takePeaks: [Float] = []
    private var checkedTakeInputs = false

    let clock = Clock()
    let levels = Levels()
    let waveforms = Waveforms()
    let recorder = InputRecorder()
    lazy var playback = PlaybackEngine(monitorRing: recorder.monitorRing)
    private var timer: Timer?
    private var playStart: Double = 0

    var isDirty: Bool { project != savedProject }
    var audioFolder: URL? { folder?.appendingPathComponent("Audio") }
    var title: String { (folder?.lastPathComponent ?? "Untitled") + (isDirty ? " — Edited" : "") }

    init(startTimer: Bool = true) {
        project.tracks = [Track(name: "Track 1")]
        savedProject = project
        playback.sync(project)
        playback.onConfigurationChange = { [weak self] in
            self?.problem = "The output device changed, so playback stopped."
            self?.stop()
        }
        recorder.onInterrupted = { [weak self] in self?.inputInterrupted() }
        playback.master.onProblem = { [weak self] in self?.problem = $0 }
        playback.master.onLoaded = { [weak self] in self?.objectWillChange.send() }
        playback.onDeviceLost = { [weak self] in DispatchQueue.main.async { self?.applyOutput(force: true) } }
        outputs = AudioDevices.outputDevices()
        applyOutput(force: true)
        devices = AudioDevices.inputDevices()
        inputChannels = activeDevice?.channels ?? 2
        AudioDevices.observeChanges { [weak self] in self?.devicesChanged() }
        if startTimer {
            persistRecovery = true
            if let path = UserDefaults.standard.string(forKey: "pendingRecordingFolder") {
                DispatchQueue.main.async { [weak self] in
                    self?.recoverTakes(in: URL(fileURLWithPath: path))
                    UserDefaults.standard.removeObject(forKey: "pendingRecordingFolder")
                }
            }
            monitorAlways = true
            DispatchQueue.main.async { [weak self] in self?.refreshInput() }
            NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in self?.appActive = true }
            NotificationCenter.default.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { [weak self] _ in self?.appActive = false }
        }
        if startTimer {
            timer = Timer(timeInterval: 1.0 / 30, repeats: true) { [weak self] _ in self?.tick() }
            RunLoop.main.add(timer!, forMode: .common)
        }
    }

    private func projectChanged(_ old: Project) {
        if inputOff, project.tracks.contains(where: { $0.armed || $0.monitor }) { inputOff = false }
        if old.tracks.map(\.id) != project.tracks.map(\.id) || old.tracks.map(\.armed) != project.tracks.map(\.armed) {
            refreshInput()
        }
        if isPlaying, old.tracks.map(\.id) != project.tracks.map(\.id) { return }
        playback.sync(project)
        let monitorKey = { (p: Project) in p.tracks.map { "\($0.id)\($0.monitor)\($0.stereo)\($0.inputChannel)" } }
        if monitorKey(old) != monitorKey(project) { updateMonitoring() }
    }

    // MARK: master plugins

    static let maxMasterPlugins = 6

    func addPlugin(_ c: AVAudioUnitComponent) {
        guard project.masterPlugins.count < Self.maxMasterPlugins else { return }
        let p = MasterPlugin(c)
        project.masterPlugins.append(p)
        // Open its window once it has loaded, so SonoBus's connect screen (or the knobs) appear.
        func open(_ tries: Int) {
            if let u = playback.master.units[p.id] { PluginWindows.shared.show(p, unit: u); return }
            if tries > 0 { DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { open(tries - 1) } }
        }
        open(25)
    }

    func removePlugin(_ id: UUID) {
        PluginWindows.shared.close(id)
        project.masterPlugins.removeAll { $0.id == id }
    }

    func setPluginBypass(_ id: UUID, _ bypass: Bool) {
        guard let i = project.masterPlugins.firstIndex(where: { $0.id == id }) else { return }
        project.masterPlugins[i].bypass = bypass
    }

    func movePlugin(_ id: UUID, by delta: Int) {
        guard let i = project.masterPlugins.firstIndex(where: { $0.id == id }) else { return }
        let j = i + delta
        guard project.masterPlugins.indices.contains(j) else { return }
        project.masterPlugins.swapAt(i, j)
    }

    var monitoredTracks: [Track] { project.tracks.filter(\.monitor) }

    func updateMonitoring() {
        if !monitoredTracks.isEmpty, !recorder.isRunning { refreshInput() }
        playback.updateMonitoring(project, inputRunning: recorder.isRunning)
        if !monitoredTracks.isEmpty, recorder.device == nil || recorder.device?.isUSB == false,
           AudioDevices.defaultOutputIsBuiltInSpeakers() {
            problem = "Monitoring the built-in mic through the MacBook speakers can howl. Use headphones."
        }
    }

    var isListening: Bool { !monitoredTracks.isEmpty }

    /// Soundcheck: hear the input live through a track's effects, without recording. Uses the
    /// selected track, else an armed one, else the first. Off turns every track's monitoring off.
    func toggleListen() {
        if isListening {
            for i in project.tracks.indices { project.tracks[i].monitor = false }
            return
        }
        if project.tracks.isEmpty { addTrack() }
        // A muted (or not-soloed) track's monitoring is silent, so pick one that can be heard.
        let order = [selectedTrack].compactMap { $0 } + armedTracks.map(\.id) + project.tracks.map(\.id)
        guard let id = order.first(where: { id in project.tracks.first { $0.id == id }.map(project.isAudible) ?? false }),
              let i = index(of: id) else {
            problem = "Every track is muted (or another is soloed), so there's nothing to hear. Unmute a track with M, then press Listen again."
            return
        }
        project.tracks[i].monitor = true
        selectedTrack = id
        if let d = recorder.device ?? activeDevice, AudioDevices.transport(d.objectID) == kAudioDeviceTransportTypeBluetooth {
            problem = "Listening to \(d.name)'s mic. Bluetooth mics are delayed and low quality; for recording, pick your audio interface in the mic menu."
        }
    }

    // MARK: tracks and clips

    func addTrack() {
        let n = (project.tracks.count) + 1
        var t = Track(name: "Track \(n)")
        // Same input as the track above: most people overdub with the one mic they have plugged in.
        if let last = project.tracks.last {
            t.inputChannel = min(last.inputChannel, max(0, inputChannels - 1))
            t.stereoInput = last.stereoInput
        }
        project.tracks.append(t)
    }

    func removeTrack(_ id: UUID) {
        guard !isRecording else { return }
        project.tracks.removeAll { $0.id == id }
    }

    func index(of track: UUID) -> Int? { project.tracks.firstIndex { $0.id == track } }

    func trackBinding(_ id: UUID) -> Binding<Track> {
        Binding(get: { [unowned self] in project.tracks.first { $0.id == id } ?? Track(name: "") },
                set: { [unowned self] new in if let i = index(of: id) { project.tracks[i] = new } })
    }

    func clip(_ ref: ClipRef) -> Clip? {
        project.tracks.first { $0.id == ref.track }?.clips.first { $0.id == ref.clip }
    }

    // MARK: clean-up and enhancement

    /// The clip the Clean Up & Enhance sheet (custom settings) is open for.
    @Published var processTarget: ClipRef?
    /// The clip the Remove Silence sheet is open for.
    @Published var silenceTarget: ClipRef?
    @Published var processProgress: Double?

    /// The part of the loop region that lies over the clip, as seconds in the clip's file.
    func loopNoiseRange(_ ref: ClipRef) -> Range<Double>? {
        guard let c = clip(ref), project.loopEnd > project.loopStart else { return nil }
        let a = max(project.loopStart, c.start), b = min(project.loopEnd, c.end)
        guard b - a >= 0.2 else { return nil }
        return (c.offset + a - c.start)..<(c.offset + b - c.start)
    }

    /// Makes a processed copy of the clip's original recording (noise removal, then enhancement,
    /// then volume) and points the clip, and any other clip cut from the same recording, at it.
    /// Always starts from the original, so changing settings replaces the result instead of stacking.
    func process(_ ref: ClipRef, _ settings: ClipProcessing, denoiseFromLoop: Bool = false, completion: ((Bool) -> Void)? = nil) {
        guard !isRecording, processProgress == nil, let audio = audioFolder, let c = clip(ref) else { completion?(false); return }
        if settings.isEmpty { removeProcessing(ref); completion?(true); return }
        let source = c.originalFile ?? c.file
        let current = c.file
        var range: Range<Double>?
        if settings.noise == .denoise, denoiseFromLoop {
            range = loopNoiseRange(ref)
            if range == nil {
                problem = "Put the loop region over a part of this clip that is only noise (at least 0.2 s), then try again."
                completion?(false); return
            }
        }
        let base = ((source as NSString).deletingPathExtension) + " processed"
        var name = base + ".wav", n = 2
        while FileManager.default.fileExists(atPath: audio.appendingPathComponent(name).path) { name = "\(base) \(n).wav"; n += 1 }
        let src = audio.appendingPathComponent(source), dest = audio.appendingPathComponent(name)
        processProgress = 0
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let report: (Double) -> Void = { p in DispatchQueue.main.async { self?.processProgress = p } }
            let result = Result { try Self.render(src, to: dest, settings, noiseRange: range, progress: report) }
            DispatchQueue.main.async {
                guard let self else { return }
                self.processProgress = nil
                switch result {
                case .success:
                    var p = self.project
                    for t in p.tracks.indices {
                        for i in p.tracks[t].clips.indices where p.tracks[t].clips[i].file == current {
                            p.tracks[t].clips[i].file = name
                            p.tracks[t].clips[i].originalFile = source
                            p.tracks[t].clips[i].processing = settings
                        }
                    }
                    self.waveforms.load(name, folder: audio)
                    self.asOneUndoStep { self.project = p }
                    try? self.save()
                    completion?(true)
                case .failure(let error):
                    try? FileManager.default.removeItem(at: dest)
                    self.problem = error.localizedDescription
                    completion?(false)
                }
            }
        }
    }

    /// The processing chain, off the main thread. Intermediate steps go through temp files.
    private static func render(_ src: URL, to dest: URL, _ s: ClipProcessing, noiseRange: Range<Double>?,
                               progress: @escaping (Double) -> Void) throws {
        let work = FileManager.default.temporaryDirectory.appendingPathComponent("process-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: work) }
        let finishing = s.enhance || s.volume != .unchanged
        var current = src
        if let noise = s.noise {
            let out = finishing ? work.appendingPathComponent("clean.wav") : dest
            switch noise {
            case .denoise:
                try Denoise.process(source: current, dest: out, options: .init(reduction: s.denoiseReduction, profile: noiseRange)) {
                    progress($0 * (finishing ? 0.5 : 1))
                }
            case .voiceClean:
                try VoiceClean.process(source: current, dest: out, strength: s.voiceStrength)
            }
            current = out
        }
        guard finishing else { return }
        let volume: Enhance.Volume = switch s.volume {
            case .unchanged: .unchanged
            case .normalize: .normalize
            case .gain: .gain(s.gain)
        }
        let start = s.noise == nil ? 0.0 : 0.5
        try Enhance.process(source: current, dest: dest, enhance: s.enhance, volume: volume) { progress(start + $0 * (1 - start)) }
    }

    /// One click from the clip menu: adds the fix to the clip's current processing and runs it.
    func quickFix(_ ref: ClipRef, _ fix: ClipProcessing.QuickFix) {
        guard let c = clip(ref) else { return }
        guard processProgress == nil else { problem = "Still working on the last clean-up. Try again in a moment."; return }
        var s = c.processing ?? ClipProcessing()
        fix.apply(to: &s)
        guard s != c.processing else { problem = "\(fix.title) is already on this clip."; return }
        if s.noise == .voiceClean, VoiceClean.tool == nil { problem = VoiceClean.Failure.notInstalled.localizedDescription; return }
        problem = fix.working
        process(ref, s) { [weak self] ok in if ok { self?.problem = nil } }
    }

    /// Puts the original recording back on the clip (and the other clips sharing its file).
    func removeProcessing(_ ref: ClipRef) {
        guard let c = clip(ref), let original = c.originalFile else { return }
        var p = project
        for t in p.tracks.indices {
            for i in p.tracks[t].clips.indices where p.tracks[t].clips[i].file == c.file {
                p.tracks[t].clips[i].file = original
                p.tracks[t].clips[i].originalFile = nil
                p.tracks[t].clips[i].processing = nil
            }
        }
        if let audio = audioFolder { waveforms.load(original, folder: audio) }
        asOneUndoStep { project = p }
        try? save()
    }

    func updateClip(_ ref: ClipRef, _ change: (inout Clip) -> Void) {
        guard let t = index(of: ref.track), let c = project.tracks[t].clips.firstIndex(where: { $0.id == ref.clip }) else { return }
        var clip = project.tracks[t].clips[c]
        change(&clip)
        clip.normalize()
        project.tracks[t].clips[c] = clip
    }

    func deleteSelectedClip() {
        guard let sel = selection, let t = index(of: sel.track) else { return }
        project.tracks[t].clips.removeAll { $0.id == sel.clip }
        selection = nil
    }

    /// Splits the selected clip at the playhead, or every clip under it on the selected track.
    func splitAtPlayhead() {
        let time = clock.position
        let targets: [UUID] = selection.map { [$0.track] } ?? selectedTrack.map { [$0] } ?? project.tracks.map(\.id)
        for id in targets {
            guard let t = index(of: id) else { continue }
            var clips: [Clip] = []
            for clip in project.tracks[t].clips {
                if (selection == nil || selection?.clip == clip.id), let (a, b) = clip.split(at: time) {
                    clips += [a, b]
                    if selection?.clip == clip.id { selection = ClipRef(track: id, clip: b.id) }
                } else {
                    clips.append(clip)
                }
            }
            project.tracks[t].clips = clips
        }
    }

    // MARK: transport

    func setPosition(_ seconds: Double) {
        let p = max(0, seconds)
        if isRecording { return }
        if isPlaying { startPlayback(from: p) } else { clock.position = p }
    }

    func togglePlay() { isPlaying || isRecording ? stop() : startPlayback(from: clock.position) }

    /// While recording, stops the take first (it's kept), so "back to the start" always works.
    func returnToStart() {
        let start = project.loopEnabled ? project.loopStart : 0
        if isRecording { stop(); clock.position = start; return }
        setPosition(start)
    }

    func goToEnd() {
        if isRecording { return }
        setPosition(project.duration)
    }

    func toggleLoop() {
        project.loopEnabled.toggle()
        if isPlaying && !isRecording { startPlayback(from: clock.position) }
    }

    func setLoop(start: Double? = nil, end: Double? = nil) {
        if let start { project.loopStart = max(0, start) }
        if let end { project.loopEnd = max(0, end) }
        if project.loopEnd < project.loopStart { (project.loopStart, project.loopEnd) = (project.loopEnd, project.loopStart) }
    }

    private func startHost(after seconds: Double) -> UInt64 {
        mach_absolute_time() + AVAudioTime.hostTime(forSeconds: seconds)
    }

    func startPlayback(from position: Double) {
        problem = nil
        do {
            let loop = project.loopEnabled ? (project.loopStart, project.loopEnd) : nil
            try playback.play(project, audioFolder: audioFolder, from: position, loop: loop, at: startHost(after: 0.08),
                              clicks: project.metronome ? .always : .none)
            playStart = position
            isPlaying = true
        } catch {
            problem = "Couldn't start playback: \(error.localizedDescription)"
        }
    }

    func stop() {
        if isRecording { finishRecording() }
        let wasPlaying = isPlaying
        if wasPlaying { clock.position = max(0, playback.position) }
        playback.stop()
        isPlaying = false
        if !wasPlaying { clock.position = 0 }        // a second Stop returns to the start
    }

    // MARK: recording

    var armedTracks: [Track] { project.tracks.filter(\.armed) }

    func toggleRecord() {
        if isRecording { stop(); return }
        record()
    }

    func record(completion: ((Bool) -> Void)? = nil) {
        guard !armedTracks.isEmpty else {
            problem = "Arm a track (the red button on the track) to record."
            completion?(false); return
        }
        withMicrophoneAccess { [self] granted in
            guard granted else {
                problem = "Recorder can't use the microphone. Allow it in System Settings › Privacy & Security › Microphone."
                completion?(false); return
            }
            do {
                if !recorder.isRunning { try openInput() }
                try ensureFolder()
                guard hasRoom(forSeconds: 120) else { completion?(false); return }
                try save()
                if isPlaying { playback.stop(); isPlaying = false }
                let stamp = Self.stampFormatter.string(from: Date())
                let requests = armedTracks.map { track in
                    InputRecorder.TakeRequest(trackID: track.id, channels: track.stereo ? [0, 1] : [track.inputChannel],
                                              url: audioFolder!.appendingPathComponent("\(Self.safe(track.name)) \(stamp).wav"))
                }
                let host = startHost(after: 0.12)
                recordStart = clock.position
                // Count-in: the transport starts a bar early; recording starts on the downbeat.
                let preroll = project.countIn ? project.barLength : 0
                try recorder.beginRecording(requests, at: host + AVAudioTime.hostTime(forSeconds: preroll))
                writePending(requests)
                let minutes = recordingMinutesLeft
                if minutes < 30 { problem = String(format: "Low disk space: about %.0f minutes of recording left.", minutes) }
                try playback.play(project, audioFolder: audioFolder, from: recordStart - preroll, loop: nil, at: host,
                                  clicks: project.metronome ? .always : (preroll > 0 ? .before(recordStart) : .none))
                playStart = recordStart - preroll
                isPlaying = true
                isRecording = true
                if recordingMinutesLeft >= 30 { problem = nil }
                completion?(true)
            } catch {
                _ = recorder.finishRecording()
                problem = "Couldn't start recording: \(error.localizedDescription)"
                completion?(false)
            }
        }
    }

    private func finishRecording() {
        let (results, error) = recorder.finishRecording()
        isRecording = false
        levels.live = [:]
        if let error { problem = "Recording stopped with a disk error: \(error.localizedDescription)" }
        // Input + output latency: what was heard at time T was captured this much later.
        let latency = recorder.latency + playback.outputLatency
        for r in results {
            guard r.frames > 0 else { try? FileManager.default.removeItem(at: r.url); continue }
            let length = Double(r.frames) / Formats.rate
            var clip = Clip(file: r.url.lastPathComponent, fileLength: length, start: recordStart + r.startDelay - latency,
                            duration: length)
            if clip.start < 0 { clip.offset = -clip.start; clip.duration -= clip.offset; clip.start = 0 }
            clip.normalize()
            waveforms.set(clip.file, r.peaks)
            guard let t = index(of: r.trackID) else { continue }
            project.tracks[t].clips = Self.carve(project.tracks[t].clips, start: clip.start, end: clip.end) + [clip]
        }
        if !results.isEmpty { try? save() }
        clearPending()
    }

    /// Removes the part of existing clips that a new take covers.
    static func carve(_ clips: [Clip], start: Double, end: Double) -> [Clip] {
        var out: [Clip] = []
        for clip in clips {
            if clip.end <= start || clip.start >= end { out.append(clip); continue }
            if clip.start < start, var left = clip.split(at: start)?.0 { left.fadeOut = 0; out.append(left) }
            if clip.end > end, let right = clip.split(at: end)?.1 { out.append(right) }
        }
        return out
    }

    private func withMicrophoneAccess(_ done: @escaping (Bool) -> Void) {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: done(true)
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio) { ok in DispatchQueue.main.async { done(ok) } }
        default: done(false)
        }
    }

    // MARK: input device

    var selectedDevice: InputDevice? { devices.first { $0.id == preferredInputUID } }

    /// The chosen device; in Automatic mode a connected USB interface, else the system default.
    var activeDevice: InputDevice? {
        if let d = selectedDevice { return d }
        return preferredInputUID == nil ? devices.first(where: \.isUSB) : nil
    }

    /// Whether Recorder is the frontmost app; input meters run then even with nothing armed.
    var monitorAlways = false
    @Published var appActive = false { didSet { if appActive != oldValue { refreshInput() } } }

    private func openInput() throws {
        try recorder.start(device: activeDevice)
        inputChannels = recorder.channelCount
        // The input may have a new rate or device: rebuild the live monitor feeds.
        playback.updateMonitoring(project, inputRunning: true)
        let name = activeDevice?.name ?? devices.first { $0.objectID == AudioDevices.defaultInput() }?.name ?? "Default input"
        inputName = name
    }

    /// The mic stays open only while a track is armed, so the orange mic light means something.
    func refreshInput() {
        // Input meters run whenever the app is open (the self-test sessions excepted).
        let wanted = !armedTracks.isEmpty || (appActive && !inputOff) || monitorAlways || !monitoredTracks.isEmpty
        if !wanted {
            if !isRecording { recorder.stop(); levels.inputs = [] }
            return
        }
        let current = recorder.device?.id
        guard !recorder.isRunning || current != activeDevice?.id else { return }
        if isRecording { return }
        withMicrophoneAccess { [self] granted in
            guard granted else {
                problem = "Recorder can't use the microphone. Allow it in System Settings › Privacy & Security › Microphone."
                return
            }
            do { try openInput(); problem = nil } catch { problem = error.localizedDescription }
        }
    }

    // MARK: output device

    var selectedOutput: InputDevice? { outputs.first { $0.id == preferredOutputUID } }
    var outputName: String {
        if let d = selectedOutput { return d.name }
        if preferredOutputUID != nil { return "Output missing — using default" }
        return outputs.first { $0.objectID == AudioDevices.defaultOutput() }?.name ?? "Default output"
    }

    /// Points the playback engine at the chosen output (or the system default when it's missing).
    func applyOutput(force: Bool = false) {
        let target = selectedOutput?.objectID ?? AudioDevices.defaultOutput()
        guard target != playback.currentOutputDevice || (force && target != playback.outputDeviceID) else { return }
        if isRecording { return }                 // never switch mid-take
        let wasPlaying = isPlaying
        let position = clock.position
        if wasPlaying { stop() }
        playback.setOutputDevice(target)
        playback.updateMonitoring(project, inputRunning: recorder.isRunning)
        if wasPlaying { startPlayback(from: position) }
    }

    private func devicesChanged() {
        outputs = AudioDevices.outputDevices()
        applyOutput()
        devices = AudioDevices.inputDevices()
        if !isRecording {
            refreshInputDevice()
            if !recorder.isRunning { inputChannels = activeDevice?.channels ?? inputChannels }
        }
    }

    /// Reopens the input if the preferred device came back, or the current one went away.
    private func refreshInputDevice() {
        guard !armedTracks.isEmpty || (appActive && !inputOff) else { return }
        let gone = recorder.device.map { d in !devices.contains { $0.id == d.id } } ?? false
        let back = activeDevice != nil && recorder.device?.id != activeDevice?.id
        if gone || back || !recorder.isRunning {
            recorder.stop()
            refreshInput()
        }
    }

    private func inputInterrupted() {
        if isRecording {
            stop()
            problem = "The input device changed or disconnected, so recording stopped. Your take up to that point was kept."
        }
        recorder.stop()
        devices = AudioDevices.inputDevices()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in self?.refreshInput() }
    }

    // MARK: timer

    private func tick() {
        // Polled as well as notified: the activation notice can arrive before this object exists.
        if NSApp.isActive != appActive { appActive = NSApp.isActive }
        if monitorAlways, !recorder.isRunning, !isRecording, Int(Date().timeIntervalSince1970 * 30) % 60 == 0 { refreshInput() }
        if isPlaying {
            playback.tick()
            let p = playback.position
            clock.position = p
            if !isRecording, !project.loopEnabled, !project.metronome, p > project.duration + 0.5, p > playStart + 0.5 {
                stop()
                clock.position = 0
            }
        }
        var trackLevels: [UUID: Float] = [:]
        for (id, strip) in playback.strips {
            let v = strip.meter.take().0
            let old = levels.tracks[id] ?? 0
            trackLevels[id] = isPlaying ? max(v, old * 0.85) : old * 0.7
        }
        if trackLevels != levels.tracks { levels.tracks = trackLevels }
        let m = playback.masterMeter.take()
        let master = isPlaying ? (max(m.0, levels.master.0 * 0.85), max(m.1, levels.master.1 * 0.85))
                               : (levels.master.0 * 0.7, levels.master.1 * 0.7)
        if master != levels.master { levels.master = master }
        if !recorder.isRunning, !levels.inputs.isEmpty { levels.inputs = [] }
        if recorder.isRunning {
            let inputs = recorder.meters.enumerated().map { i, meter in
                max(meter.take().0, (i < levels.inputs.count ? levels.inputs[i] : 0) * 0.85)
            }
            if inputs != levels.inputs { levels.inputs = inputs }
        }
        if isRecording, Int(clock.position * 30) % 3 == 0 { levels.live = recorder.livePeaks() }
        if isRecording { checkTakeInputs() }
        if isRecording, Int(clock.position * 30) % 30 == 0, DiskSpace.free(at: folder ?? Self.projectsRoot) < DiskSpace.stopBelow {
            stop()
            problem = "Recording stopped because the disk is almost full. Everything up to that point was kept."
        }
    }

    /// A few seconds into a take, warn about any armed track whose input is silent, and say
    /// which input the sound is actually on.
    private func checkTakeInputs() {
        if clock.position < recordStart { takePeaks = []; checkedTakeInputs = false; return }   // count-in
        if checkedTakeInputs { return }
        for (i, v) in levels.inputs.enumerated() {
            if i >= takePeaks.count { takePeaks.append(0) }
            takePeaks[i] = max(takePeaks[i], v)
        }
        guard clock.position - recordStart > 3 else { return }
        checkedTakeInputs = true
        let quiet: Float = 0.003, heard: Float = 0.02     // about -50 dB and -34 dB
        for t in project.tracks where t.armed {
            let mine = t.stereo ? [0, 1] : [t.inputChannel]
            let peak = mine.map { $0 < takePeaks.count ? takePeaks[$0] : 0 }.max() ?? 0
            guard peak < quiet else { continue }
            if let loud = takePeaks.indices.first(where: { !mine.contains($0) && takePeaks[$0] > heard }) {
                problem = "\(t.name) is recording In \(t.inputChannel + 1), which is silent. Your sound is on In \(loud + 1): stop, and pick In \(loud + 1) from the track's In menu."
            } else {
                problem = "No sound is reaching \(t.name) (\(t.inputLabel)). Check the cable, the gain knob and the input it's plugged into."
            }
            return
        }
    }

    // MARK: files

    static let projectsRoot = FileManager.default.urls(for: .musicDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Recorder")
    static let stampFormatter: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd HH.mm.ss"; return f
    }()
    static func safe(_ s: String) -> String {
        let cleaned = s.components(separatedBy: CharacterSet(charactersIn: "/:\\")).joined(separator: "-")
        return cleaned.isEmpty ? "Track" : cleaned
    }

    /// Untitled projects get a folder in ~/Music/Recorder the first time something is recorded.
    func ensureFolder() throws {
        if folder == nil {
            folder = Self.projectsRoot.appendingPathComponent("Untitled \(Self.stampFormatter.string(from: Date()))")
            isUntitled = true
        }
        try FileManager.default.createDirectory(at: audioFolder!, withIntermediateDirectories: true)
    }

    func save() throws {
        try ensureFolder()
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        var saved = project
        saved.masterPlugins = playback.master.withState(project.masterPlugins)    // each plugin's own settings
        try enc.encode(saved).write(to: folder!.appendingPathComponent("project.json"), options: .atomic)
        savedProject = project
    }

    func saveAs(to url: URL) throws {
        stop()
        let fm = FileManager.default
        if let old = folder, isUntitled {
            if fm.fileExists(atPath: url.path) { try fm.removeItem(at: url) }
            try fm.moveItem(at: old, to: url)
        } else {
            try fm.createDirectory(at: url.appendingPathComponent("Audio"), withIntermediateDirectories: true)
            if let oldAudio = audioFolder {
                for name in Set(project.tracks.flatMap(\.clips).map(\.file)) {
                    let dest = url.appendingPathComponent("Audio").appendingPathComponent(name)
                    if !fm.fileExists(atPath: dest.path) { try fm.copyItem(at: oldAudio.appendingPathComponent(name), to: dest) }
                }
            }
        }
        folder = url
        isUntitled = false
        try save()
    }

    func open(_ url: URL) throws {
        stop()
        let data = try Data(contentsOf: url.appendingPathComponent("project.json"))
        let loaded = try JSONDecoder().decode(Project.self, from: data)
        waveforms.clear()
        selection = nil
        folder = url
        isUntitled = false
        var p = loaded
        // Opening a project never opens the mic or starts live monitoring: monitoring a boosted input
        // that nobody is using is a constant hiss in the headphones.
        for i in p.tracks.indices { p.tracks[i].armed = false; p.tracks[i].monitor = false }
        project = p
        savedProject = p
        undoStack = []; redoStack = []
        clock.position = 0
        if let audio = audioFolder { for c in p.tracks.flatMap(\.clips) { waveforms.load(c.file, folder: audio) } }
    }

    func newProject() {
        stop()
        waveforms.clear()
        selection = nil
        folder = nil
        isUntitled = true
        var p = Project()
        p.tracks = [Track(name: "Track 1")]
        project = p
        savedProject = p
        undoStack = []; redoStack = []
        clock.position = 0
    }

    // MARK: disk space and recovery

    /// Checks there's room for `seconds` of the armed tracks plus `extraBytes`, keeping a reserve.
    func hasRoom(forSeconds seconds: Double, extraBytes: Int = 0) -> Bool {
        let place = folder ?? Self.projectsRoot
        let free = DiskSpace.free(at: place)
        let channels = max(1, armedTracks.map { $0.stereo ? 2 : 1 }.reduce(0, +))
        let need = Int64(seconds) * DiskSpace.bytesPerSecond(channels: channels) + Int64(extraBytes) + DiskSpace.reserve
        if free < need {
            problem = "Your disk is nearly full (\(ByteCountFormatter.string(fromByteCount: free, countStyle: .file)) free). Free some space first."
            return false
        }
        return true
    }

    /// Minutes of recording left for the armed tracks.
    var recordingMinutesLeft: Double {
        let channels = max(1, armedTracks.map { $0.stereo ? 2 : 1 }.reduce(0, +))
        let free = DiskSpace.free(at: folder ?? Self.projectsRoot) - DiskSpace.reserve
        return max(0, Double(free) / Double(DiskSpace.bytesPerSecond(channels: channels)) / 60)
    }

    private var persistRecovery = false
    private var pendingFile: URL? { folder?.appendingPathComponent(PendingRecording.fileName) }

    private func writePending(_ requests: [InputRecorder.TakeRequest]) {
        let pending = PendingRecording(takes: requests.map { .init(trackID: $0.trackID, file: $0.url.lastPathComponent, start: recordStart) })
        if let url = pendingFile { try? JSONEncoder().encode(pending).write(to: url, options: .atomic) }
        if persistRecovery { UserDefaults.standard.set(folder?.path, forKey: "pendingRecordingFolder") }
    }

    private func clearPending() {
        if let url = pendingFile { try? FileManager.default.removeItem(at: url) }
        if persistRecovery { UserDefaults.standard.removeObject(forKey: "pendingRecordingFolder") }
    }

    /// After a crash or power loss mid-take: opens that project, repairs the half-written WAVs
    /// and puts them back on their tracks. Returns how many takes came back.
    @discardableResult
    func recoverTakes(in projectFolder: URL) -> Int {
        let marker = projectFolder.appendingPathComponent(PendingRecording.fileName)
        guard let data = try? Data(contentsOf: marker), let pending = try? JSONDecoder().decode(PendingRecording.self, from: data) else { return 0 }
        if FileManager.default.fileExists(atPath: projectFolder.appendingPathComponent("project.json").path) {
            try? open(projectFolder)
        } else {
            newProject()
            folder = projectFolder
        }
        isUntitled = projectFolder.deletingLastPathComponent().standardizedFileURL == Self.projectsRoot.standardizedFileURL
            && projectFolder.lastPathComponent.hasPrefix("Untitled")
        var recovered = 0
        for take in pending.takes {
            let url = projectFolder.appendingPathComponent("Audio").appendingPathComponent(take.file)
            guard FileManager.default.fileExists(atPath: url.path) else { continue }
            if project.tracks.contains(where: { $0.clips.contains { $0.file == take.file } }) { continue }
            WAVRepair.repair(url)
            guard let a = try? Exporter.analyze(url), a.frames > 0 else { continue }
            let length = Double(a.frames) / Formats.rate
            let clip = Clip(file: take.file, fileLength: length, start: max(0, take.start), duration: length)
            if let t = index(of: take.trackID) {
                project.tracks[t].clips = Self.carve(project.tracks[t].clips, start: clip.start, end: clip.end) + [clip]
            } else {
                var t = Track(name: "Recovered take")
                t.clips = [clip]
                project.tracks.append(t)
            }
            waveforms.load(take.file, folder: projectFolder.appendingPathComponent("Audio"))
            recovered += 1
        }
        try? FileManager.default.removeItem(at: marker)
        if recovered > 0 {
            try? save()
            problem = "Recorder closed unexpectedly during a take. \(recovered) recording\(recovered == 1 ? " was" : "s were") recovered and put back on the timeline."
        }
        return recovered
    }

    // MARK: import

    @Published private(set) var importing = 0

    /// Copies audio files into the project (as 48 kHz WAV) and places them at `time`: the first on
    /// `track` (or the selected track, or a new one), any others on new tracks below.
    func importAudio(_ urls: [URL], track: UUID? = nil, at time: Double? = nil, completion: ((Bool) -> Void)? = nil) {
        let files = urls.filter { !$0.hasDirectoryPath }
        guard !files.isEmpty else { completion?(false); return }
        do { try ensureFolder(); try save() } catch { problem = "Couldn't prepare the project folder: \(error.localizedDescription)"; completion?(false); return }
        guard let audio = audioFolder else { completion?(false); return }
        guard hasRoom(forSeconds: 0, extraBytes: files.compactMap { try? $0.resourceValues(forKeys: [.fileSizeKey]).fileSize }.reduce(0, +) * 4) else {
            completion?(false); return
        }
        let start = max(0, time ?? clock.position)
        var target = track ?? selectedTrack
        importing += files.count
        problem = "Importing \(files.count == 1 ? files[0].lastPathComponent : "\(files.count) files")…"
        DispatchQueue.global(qos: .userInitiated).async {
            var results: [(URL, String, Importer.Result)] = []
            var failures: [String] = []
            for url in files {
                let base = Self.safe(url.deletingPathExtension().lastPathComponent)
                var name = "\(base).wav", n = 2
                while FileManager.default.fileExists(atPath: audio.appendingPathComponent(name).path) { name = "\(base) \(n).wav"; n += 1 }
                do { results.append((url, name, try Importer.convert(url, to: audio.appendingPathComponent(name)))) }
                catch { try? FileManager.default.removeItem(at: audio.appendingPathComponent(name)); failures.append(url.lastPathComponent) }
            }
            DispatchQueue.main.async {
                self.importing -= files.count
                for (i, (url, name, r)) in results.enumerated() {
                    let length = Double(r.frames) / Formats.rate
                    let clip = Clip(file: name, fileLength: length, start: start, duration: length)
                    self.waveforms.set(name, r.peaks)
                    if i == 0, let t = target, let idx = self.index(of: t) {
                        self.project.tracks[idx].clips.append(clip)
                    } else {
                        var t = Track(name: url.deletingPathExtension().lastPathComponent)
                        t.clips = [clip]
                        self.project.tracks.append(t)
                        target = t.id
                    }
                }
                self.problem = failures.isEmpty ? nil : "Couldn't import \(failures.joined(separator: ", ")). Recorder reads WAV, AIFF, MP3, M4A, CAF and FLAC."
                if !results.isEmpty { try? self.save() }
                completion?(!results.isEmpty)
            }
        }
    }

    func runImportPanel() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.audio]
        panel.allowsMultipleSelection = true
        panel.message = "Choose audio to add at the playhead"
        guard panel.runModal() == .OK else { return }
        importAudio(panel.urls)
    }

    /// WAVs in Audio/ that no clip uses any more (deleted or fully trimmed takes).
    func unusedAudio() -> [URL] {
        guard let audio = audioFolder,
              let files = try? FileManager.default.contentsOfDirectory(at: audio, includingPropertiesForKeys: nil) else { return [] }
        // Originals behind cleaned clips count as used: Remove Clean-up needs them.
        let used = Set(project.tracks.flatMap(\.clips).flatMap { [$0.file, $0.originalFile].compactMap { $0 } })
        return files.filter { $0.pathExtension.lowercased() == "wav" && !used.contains($0.lastPathComponent) }
    }

    // MARK: panels (UI)

    func runOpenPanel() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.message = "Choose a Recorder project folder"
        panel.directoryURL = Self.projectsRoot
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try open(url) } catch { problem = "Couldn't open that folder as a project: \(error.localizedDescription)" }
    }

    func runSaveAsPanel() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = isUntitled ? "My Song" : (folder?.lastPathComponent ?? "My Song")
        panel.directoryURL = Self.projectsRoot
        panel.message = "The project is saved as a folder with project.json and its recordings."
        try? FileManager.default.createDirectory(at: Self.projectsRoot, withIntermediateDirectories: true)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try saveAs(to: url) } catch { problem = "Couldn't save: \(error.localizedDescription)" }
    }

    func saveOrAsk() {
        if folder == nil || isUntitled { runSaveAsPanel() } else {
            do { try save() } catch { problem = "Couldn't save: \(error.localizedDescription)" }
        }
    }

    func runExportPanel(_ format: ExportFormat) {
        guard let audio = audioFolder, project.duration > 0 else { problem = "There's nothing to export yet."; return }
        stop()
        let panel = NSSavePanel()
        panel.allowedContentTypes = [format == .wav ? .wav : .mpeg4Audio]
        panel.nameFieldStringValue = (isUntitled ? "Mix" : folder!.lastPathComponent) + "." + format.rawValue
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let project = self.project
        problem = "Exporting…"
        DispatchQueue.global(qos: .userInitiated).async {
            let result = Result { try Exporter.render(project, audioFolder: audio, to: url, format: format) }
            DispatchQueue.main.async {
                switch result {
                case .success: self.problem = nil; NSWorkspace.shared.activateFileViewerSelecting([url])
                case .failure(let e): self.problem = "Export failed: \(e.localizedDescription)"
                }
            }
        }
    }

    func runCleanUp() {
        let unused = unusedAudio()
        guard !unused.isEmpty else { problem = "Every recording in this project is in use."; return }
        let bytes = unused.compactMap { try? $0.resourceValues(forKeys: [.fileSizeKey]).fileSize }.reduce(0, +)
        let alert = NSAlert()
        alert.messageText = "Delete \(unused.count) unused recording\(unused.count == 1 ? "" : "s")?"
        alert.informativeText = "These takes aren't used by any clip. Deleting them frees \(ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)). This can't be undone."
        alert.addButton(withTitle: "Delete")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        for url in unused { try? FileManager.default.removeItem(at: url) }
    }
}
