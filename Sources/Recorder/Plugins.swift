import AVFoundation
import AppKit
import CoreAudioKit
import SwiftUI

/// An Audio Unit effect on the master output (for example SonoBus, to send the mix to a phone).
/// Saved in project.json with the plugin's own settings.
struct MasterPlugin: Codable, Equatable, Identifiable {
    var id = UUID()
    var name: String
    var maker: String
    var type: UInt32
    var subtype: UInt32
    var manufacturer: UInt32
    var bypass = false
    var state: Data?          // the plugin's fullState as a binary plist

    init(_ c: AVAudioUnitComponent) {
        name = c.name
        maker = c.manufacturerName
        type = c.audioComponentDescription.componentType
        subtype = c.audioComponentDescription.componentSubType
        manufacturer = c.audioComponentDescription.componentManufacturer
    }

    var description: AudioComponentDescription {
        AudioComponentDescription(componentType: type, componentSubType: subtype, componentManufacturer: manufacturer,
                                  componentFlags: 0, componentFlagsMask: 0)
    }
}

enum PluginCatalog {
    /// Installed effects (Apple's included), sorted by maker then name.
    static func effects() -> [AVAudioUnitComponent] {
        let types = [kAudioUnitType_Effect, kAudioUnitType_MusicEffect]
        return types.flatMap { type in
            AVAudioUnitComponentManager.shared().components(matching: AudioComponentDescription(
                componentType: type, componentSubType: 0, componentManufacturer: 0, componentFlags: 0, componentFlagsMask: 0))
        }
        .sorted { ($0.manufacturerName, $0.name) < ($1.manufacturerName, $1.name) }
    }
}

/// Loads, wires and remembers the master plugins inside the playback engine:
/// main mixer → plugin 1 → plugin 2 → … → output.
final class MasterChain {
    private unowned let engine: AVAudioEngine
    private(set) var units: [UUID: AVAudioUnit] = [:]
    private var pending: Set<UUID> = []
    private var wanted: [MasterPlugin] = []
    private var wired: [UUID]? = nil
    var onProblem: ((String) -> Void)?
    var onLoaded: (() -> Void)?

    init(engine: AVAudioEngine) { self.engine = engine }

    /// The loaded plugins in order (the ones still loading are skipped until they're ready).
    var chain: [AVAudioUnit] { wanted.compactMap { units[$0.id] } }

    func sync(_ list: [MasterPlugin]) {
        wanted = list
        let ids = Set(list.map(\.id))
        let gone = units.keys.filter { !ids.contains($0) }
        if !gone.isEmpty {
            changeGraph {
                for id in gone { if let u = units.removeValue(forKey: id) { engine.disconnectNodeOutput(u); engine.detach(u) } }
            }
        }
        for p in list where units[p.id] == nil && !pending.contains(p.id) { load(p) }
        for p in list { units[p.id]?.auAudioUnit.shouldBypassEffect = p.bypass }
        if wired != list.filter({ units[$0.id] != nil }).map(\.id) { changeGraph { } }
    }

    private func load(_ p: MasterPlugin) {
        pending.insert(p.id)
        AVAudioUnit.instantiate(with: p.description, options: []) { [weak self] unit, error in
            DispatchQueue.main.async {
                guard let self else { return }
                self.pending.remove(p.id)
                guard let unit else {
                    self.onProblem?("Couldn't load \(p.name)\(error.map { " (\($0.localizedDescription))" } ?? "").")
                    return
                }
                guard self.wanted.contains(where: { $0.id == p.id }) else { return }    // removed while loading
                if let data = p.state,
                   let state = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] {
                    unit.auAudioUnit.fullState = state
                }
                unit.auAudioUnit.shouldBypassEffect = self.wanted.first { $0.id == p.id }?.bypass ?? false
                self.changeGraph {
                    self.engine.attach(unit)
                    self.units[p.id] = unit
                }
                self.onLoaded?()
            }
        }
    }

    /// Runs `edit` with the engine paused (never rewire a running graph), then rewires the chain.
    private func changeGraph(_ edit: () -> Void) {
        let running = engine.isRunning
        if running { engine.pause() }
        edit()
        wire()
        if running { engine.prepare(); try? engine.start() }
    }

    /// Connects main mixer → plugins → output. Also called after the output device changes.
    func wire() {
        let rate = engine.outputNode.outputFormat(forBus: 0).sampleRate
        let format = AVAudioFormat(standardFormatWithSampleRate: rate > 0 ? rate : Formats.rate, channels: 2)
        engine.disconnectNodeOutput(engine.mainMixerNode)
        for u in units.values { engine.disconnectNodeOutput(u) }
        var previous: AVAudioNode = engine.mainMixerNode
        for u in chain {
            engine.connect(previous, to: u, format: format)
            previous = u
        }
        engine.connect(previous, to: engine.outputNode, format: chain.isEmpty ? nil : format)
        wired = wanted.filter { units[$0.id] != nil }.map(\.id)
    }

    /// The plugins with each loaded one's current settings, for saving.
    func withState(_ list: [MasterPlugin]) -> [MasterPlugin] {
        list.map { p in
            var p = p
            if let state = units[p.id]?.auAudioUnit.fullState,
               let data = try? PropertyListSerialization.data(fromPropertyList: state, format: .binary, options: 0) {
                p.state = data
            }
            return p
        }
    }
}

/// Each plugin's own window (SonoBus's group and connection screen, a compressor's knobs, …).
final class PluginWindows: NSObject, NSWindowDelegate {
    static let shared = PluginWindows()
    private var windows: [UUID: NSWindow] = [:]

    func show(_ plugin: MasterPlugin, unit: AVAudioUnit?) {
        if let w = windows[plugin.id] { w.makeKeyAndOrderFront(nil); return }
        guard let unit else { return }
        unit.auAudioUnit.requestViewController { [weak self] vc in
            DispatchQueue.main.async {
                guard let self else { return }
                let controller: NSViewController = vc ?? self.genericView(unit)
                let size = controller.preferredContentSize == .zero ? controller.view.fittingSize : controller.preferredContentSize
                let w = NSWindow(contentRect: NSRect(origin: .zero, size: size.width > 10 ? size : NSSize(width: 480, height: 320)),
                                 styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
                w.title = "\(plugin.name) — Master"
                w.contentViewController = controller
                w.isReleasedWhenClosed = false
                w.level = .floating
                w.delegate = self
                w.center()
                w.makeKeyAndOrderFront(nil)
                self.windows[plugin.id] = w
            }
        }
    }

    func close(_ id: UUID) { windows[id]?.close() }

    func windowWillClose(_ notification: Notification) {
        guard let w = notification.object as? NSWindow else { return }
        windows = windows.filter { $0.value !== w }
    }

    /// Plugins without their own screen get Apple's generic sliders.
    private func genericView(_ unit: AVAudioUnit) -> NSViewController {
        let vc = NSViewController()
        let view = AUGenericView(audioUnit: unit.audioUnit)
        view.showsExpertParameters = true
        vc.view = view
        return vc
    }
}

/// The master plugin slots: add, open, bypass, reorder and remove.
struct MasterPluginsView: View {
    @EnvironmentObject private var session: Session
    @State private var catalog: [AVAudioUnitComponent] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "puzzlepiece.extension").foregroundStyle(Theme.purple)
                Text("Master Plugins").font(.system(size: 15, weight: .semibold))
            }
            Text("Audio Unit effects on everything you hear: playback, live monitoring and the click. Use SonoBus here to hear it on your phone. Exports don't include them.")
                .font(.system(size: 11)).foregroundStyle(Theme.secondary).fixedSize(horizontal: false, vertical: true)

            let list = session.project.masterPlugins
            if list.isEmpty {
                Text("No plugins yet.").font(.system(size: 12)).foregroundStyle(Theme.secondary)
            }
            ForEach(Array(list.enumerated()), id: \.element.id) { i, p in
                HStack(spacing: 8) {
                    Toggle("", isOn: Binding(get: { !p.bypass }, set: { on in session.setPluginBypass(p.id, !on) }))
                        .toggleStyle(.switch).controlSize(.mini).labelsHidden()
                        .help(p.bypass ? "Off (bypassed)" : "On")
                    VStack(alignment: .leading, spacing: 1) {
                        Text(p.name).font(.system(size: 12, weight: .medium)).lineLimit(1)
                        Text(session.playback.master.units[p.id] == nil ? "Loading…" : p.maker)
                            .font(.system(size: 10)).foregroundStyle(Theme.secondary).lineLimit(1)
                    }
                    Spacer()
                    Button("Open") { PluginWindows.shared.show(p, unit: session.playback.master.units[p.id]) }
                        .controlSize(.small).disabled(session.playback.master.units[p.id] == nil)
                    Menu {
                        Button("Move Up") { session.movePlugin(p.id, by: -1) }.disabled(i == 0)
                        Button("Move Down") { session.movePlugin(p.id, by: 1) }.disabled(i == list.count - 1)
                        Divider()
                        Button("Remove") { session.removePlugin(p.id) }
                    } label: { Image(systemName: "ellipsis") }
                    .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                }
                .padding(8)
                .background(RoundedRectangle(cornerRadius: 8).fill(Theme.lavender.opacity(0.45)))
            }

            Menu {
                if catalog.isEmpty { Text("No Audio Unit effects found") }
                ForEach(Dictionary(grouping: catalog, by: \.manufacturerName).sorted { $0.key < $1.key }, id: \.key) { maker, items in
                    Menu(maker) {
                        ForEach(items, id: \.self) { c in
                            Button(c.name) { session.addPlugin(c) }
                        }
                    }
                }
            } label: {
                Label("Add Plugin", systemImage: "plus")
            }
            .fixedSize()
            .disabled(list.count >= Session.maxMasterPlugins)
        }
        .padding(16)
        .frame(width: 340)
        .onAppear { catalog = PluginCatalog.effects() }
    }
}
