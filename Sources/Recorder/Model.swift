import Foundation

/// Everything in a project that gets saved to project.json. Audio lives next to it in Audio/.
struct Project: Codable, Equatable {
    var version = 1
    var sampleRate: Double = 48000
    var tracks: [Track] = []
    var masterVolume: Float = 1
    var loopEnabled = false
    var loopStart: Double = 0
    var loopEnd: Double = 8

    // Added later; optional so older project.json files still open.
    var tempoValue: Double?
    var beatsPerBarValue: Int?
    var metronomeValue: Bool?
    var countInValue: Bool?
    var snapValue: Bool?

    var tempo: Double { get { tempoValue ?? 120 } set { tempoValue = min(300, max(30, newValue)) } }
    var beatsPerBar: Int { get { beatsPerBarValue ?? 4 } set { beatsPerBarValue = min(12, max(1, newValue)) } }
    var metronome: Bool { get { metronomeValue ?? false } set { metronomeValue = newValue } }
    var countIn: Bool { get { countInValue ?? false } set { countInValue = newValue } }
    var snap: Bool { get { snapValue ?? false } set { snapValue = newValue } }
    var beatLength: Double { 60 / tempo }
    var barLength: Double { beatLength * Double(beatsPerBar) }
    /// Nearest beat to `time` when snapping is on.
    func snapped(_ time: Double) -> Double { snap ? (time / beatLength).rounded() * beatLength : time }

    var duration: Double { tracks.flatMap(\.clips).map(\.end).max() ?? 0 }
    var anySolo: Bool { tracks.contains(where: \.solo) }
    func isAudible(_ track: Track) -> Bool { !track.mute && (!anySolo || track.solo) }
}

struct Track: Codable, Equatable, Identifiable {
    var id = UUID()
    var name: String
    var inputChannel = 0          // 0-based channel of the input device
    var armed = false
    var volume: Float = 1         // linear gain
    var pan: Float = 0            // -1 ... 1
    var mute = false
    var solo = false
    var eq = EQSettings()
    var comp = CompSettings()
    var reverb = ReverbSettings()
    var clips: [Clip] = []
    // Added later; optional so older project.json files still open.
    var stereoInput: Bool?
    var gateSettings: GateSettings?
    var monitorOn: Bool?
    var boostValue: Float?
    var delaySettings: DelaySettings?
    var delay: DelaySettings { get { delaySettings ?? DelaySettings() } set { delaySettings = newValue } }

    /// Input boost in dB (0 ... +24), applied before the effects. For quiet mics such as dynamics on a
    /// small interface. Non-destructive: the recorded file is untouched, so it can be changed later.
    var boost: Float { get { boostValue ?? 0 } set { boostValue = newValue == 0 ? nil : min(24, max(0, newValue)) } }
    var boostGain: Float { pow(10, boost / 20) }

    /// Plays this track's input live through its effects (for headphones / in-ears).
    var monitor: Bool { get { monitorOn ?? false } set { monitorOn = newValue } }

    /// Records inputs 1 and 2 into one stereo file.
    var stereo: Bool { get { stereoInput ?? false } set { stereoInput = newValue } }
    var gate: GateSettings { get { gateSettings ?? GateSettings() } set { gateSettings = newValue } }
    var inputLabel: String { stereo ? "In 1+2" : "In \(inputChannel + 1)" }
    var inputChipLabel: String { boost > 0 ? inputLabel + String(format: " +%.0f", boost) : inputLabel }
}

/// Noise gate plus clean-up filters for hum and rumble.
struct GateSettings: Codable, Equatable {
    var enabled = false
    var threshold: Float = -45   // dB; quieter than this is turned down hard
    var humHz: Int = 0           // 0 = off, 50 or 60: notches the mains frequency and its harmonics
    var lowCut = false           // 80 Hz high-pass
    var active: Bool { enabled || humHz != 0 || lowCut }
}

/// Nine-band EQ covering 20 Hz – 20 kHz, one band per named range.
struct EQSettings: Codable, Equatable {
    var enabled = false
    // The first EQ had three bands; kept so older projects open with their settings carried over.
    var low: Float = 0
    var mid: Float = 0
    var high: Float = 0
    var bandGains: [Float]?

    /// dB per band, in `EQSettings.bands` order.
    var gains: [Float] {
        get {
            if let g = bandGains, g.count == Self.bands.count { return g }
            return [0, low, 0, mid, mid, 0, 0, high, high]
        }
        set { bandGains = newValue }
    }

    struct Band {
        let name: String, short: String, low: Float, high: Float, sound: String
        var shelf: Bool { high >= 20000 }
        var centre: Float { shelf ? low : sqrt(low * high) }
        var octaves: Float { log2(high / low) }
    }
    static let range: ClosedRange<Float> = -12...12
    static let bands = [
        Band(name: "Sub-bass", short: "40", low: 20, high: 60, sound: "Deep rumble, low-end power"),
        Band(name: "Bass", short: "120", low: 60, high: 250, sound: "Warmth, body, punch"),
        Band(name: "Low mids", short: "350", low: 250, high: 500, sound: "Thickness, muddiness"),
        Band(name: "Midrange", short: "700", low: 500, high: 1000, sound: "Body, boxiness"),
        Band(name: "Upper mids", short: "1.4k", low: 1000, high: 2000, sound: "Clarity, attack"),
        Band(name: "Presence", short: "2.8k", low: 2000, high: 4000, sound: "Vocal intelligibility, definition"),
        Band(name: "High presence", short: "5k", low: 4000, high: 6000, sound: "Brightness, articulation"),
        Band(name: "Treble", short: "8k", low: 6000, high: 10000, sound: "Detail, sibilance"),
        Band(name: "Air", short: "14k", low: 10000, high: 20000, sound: "Airiness, sparkle"),
    ]
}

struct CompSettings: Codable, Equatable {
    var enabled = false
    var threshold: Float = -20   // dB
    var headroom: Float = 5      // dB, smaller = harder compression
    var makeup: Float = 0        // dB
}

struct ReverbSettings: Codable, Equatable {
    var enabled = false
    var preset = 1               // index into ReverbSettings.presets
    var mix: Float = 25          // wet %, 0...100
    static let presets = ["Small Room", "Medium Room", "Large Room", "Medium Hall", "Large Hall", "Plate", "Cathedral"]
}

/// Echo, timed to the project tempo.
struct DelaySettings: Codable, Equatable {
    var enabled = false
    var note = 2                 // index into DelaySettings.notes
    var feedback: Float = 30     // %, how many repeats
    var mix: Float = 20          // wet %, 0...100
    var tone: Float = 6000       // Hz, low-pass on the repeats (darker echoes sit behind the voice)
    static let notes = ["1/2", "1/4", "1/8 dotted", "1/8", "1/16"]
    static let beats: [Double] = [2, 1, 0.75, 0.5, 0.25]
    func seconds(tempo: Double) -> Double { min(2, Self.beats[min(max(0, note), Self.beats.count - 1)] * 60 / tempo) }
}

enum CleanupTool: String, Codable {
    case denoise, voiceClean
    var title: String { self == .denoise ? "Denoise" : "Voice Clean" }
    var fileSuffix: String { self == .denoise ? "denoised" : "voice clean" }
}

/// Clean-up and enhancement applied to a clip, always starting from its original recording:
/// noise removal, then voice enhancement, then volume.
struct ClipProcessing: Codable, Equatable {
    enum Volume: String, Codable, CaseIterable { case unchanged, normalize, gain }
    var noise: CleanupTool?
    var denoiseReduction: Float = 15
    // 30 dB, not unlimited: at Max the model turns anything it doesn't hear as voice (quiet word
    // endings, claps, breaths) into digital silence, which sounds like the sentence was cut off.
    var voiceStrength: Float = 30
    var enhance = false
    var volume: Volume = .unchanged
    var gain: Float = 6                     // dB, when volume == .gain

    /// One-click fixes from the clip menu. Each adds to whatever the clip already has.
    enum QuickFix: CaseIterable {
        case cleanVoice, removeHiss, louder
        var title: String {
            switch self {
            case .cleanVoice: "Clean Up Voice"
            case .removeHiss: "Remove Hiss & Hum"
            case .louder: "Make Louder"
            }
        }
        var working: String {
            switch self {
            case .cleanVoice: "Cleaning up the voice…"
            case .removeHiss: "Removing hiss and hum…"
            case .louder: "Making it louder…"
            }
        }
        func apply(to s: inout ClipProcessing) {
            switch self {
            case .cleanVoice: s.noise = .voiceClean; s.enhance = true
            case .removeHiss: s.noise = .denoise
            case .louder: s.volume = .normalize
            }
        }
    }

    var isEmpty: Bool { noise == nil && !enhance && (volume == .unchanged || (volume == .gain && gain == 0)) }

    /// e.g. "Voice Clean · Enhanced · +6 dB"
    var summary: String {
        var parts: [String] = []
        if let noise { parts.append(noise.title) }
        if enhance { parts.append("Enhanced") }
        switch volume {
        case .unchanged: break
        case .normalize: parts.append("Normalized")
        case .gain: if gain != 0 { parts.append(String(format: "%+.0f dB", gain)) }
        }
        return parts.joined(separator: " · ")
    }
}

struct Clip: Codable, Equatable, Identifiable {
    var id = UUID()
    var file: String             // file name inside Audio/
    var fileLength: Double       // seconds of audio in the file
    var start: Double            // timeline position, seconds
    var offset: Double = 0       // where in the file the clip begins, seconds
    var duration: Double         // seconds
    var fadeIn: Double = 0
    var fadeOut: Double = 0
    /// The untouched recording when `file` is a processed copy; nil otherwise.
    var originalFile: String?
    var cleanup: CleanupTool?               // first version: the one clean-up tool used
    var processingValue: ClipProcessing?

    /// How `file` was made from `originalFile`. Older clips that only recorded `cleanup` read as that.
    var processing: ClipProcessing? {
        get { processingValue ?? cleanup.map { ClipProcessing(noise: $0) } }
        set { processingValue = newValue; cleanup = nil }
    }

    var end: Double { start + duration }

    /// Keeps the clip inside its file and the fades inside the clip.
    mutating func normalize() {
        start = max(0, start)
        offset = min(max(0, offset), max(0, fileLength - 0.01))
        duration = min(max(0.01, duration), fileLength - offset)
        fadeIn = min(max(0, fadeIn), duration)
        fadeOut = min(max(0, fadeOut), duration - fadeIn)
    }

    /// Splits at a timeline time strictly inside the clip.
    func split(at time: Double) -> (Clip, Clip)? {
        guard time > start + 0.01, time < end - 0.01 else { return nil }
        var left = self, right = self
        left.duration = time - start
        left.fadeOut = 0
        right.id = UUID()
        right.start = time
        right.offset = offset + (time - start)
        right.duration = end - time
        right.fadeIn = 0
        left.normalize(); right.normalize()
        return (left, right)
    }
}
