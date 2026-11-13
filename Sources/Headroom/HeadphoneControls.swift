import SwiftUI
import HeadroomCore

struct HeadphoneControls: View {
    @Bindable var model: HeadphoneController
    var body: some View {
        VStack(alignment: .leading, spacing: 13) {
            if let noise = model.noiseControl {
                if noise.mode == .ambient {
                    HStack {
                        Text("Ambient level").foregroundStyle(.secondary)
                        Slider(value: Binding(get: { Double(model.noiseControl?.ambientLevel ?? 20) }, set: { value in
                            guard var next = model.noiseControl else { return }
                            next.ambientLevel = Int(value); model.changeNoise(next)
                        }), in: 1...20, step: 1).accessibilityLabel("Ambient level")
                        Text("\(noise.ambientLevel)").monospacedDigit().frame(width: 19)
                    }
                    Toggle("Focus on voice", isOn: Binding(get: { noise.focusOnVoice }, set: { value in
                        var next = noise; next.focusOnVoice = value; model.changeNoise(next)
                    }))
                }
            }
            if let eq = model.equalizer {
                HStack {
                    Text("Equalizer")
                    Spacer()
                    Picker("Equalizer preset", selection: Binding(get: { eq.preset }, set: { value in
                        guard let preset = EQPreset(rawValue: value) else { return }
                        model.change(.setPreset(preset, layout: eq.layout), verify: .equalizer(layout: eq.layout))
                    })) {
                        if EQPreset(rawValue: eq.preset) == nil { Text(eq.title).tag(eq.preset) }
                        ForEach(EQPreset.allCases) { Text($0.title).tag($0.rawValue) }
                    }.labelsHidden().frame(maxWidth: 160)
                }
                EqualizerEditor(model: model, equalizer: eq)
            }
            if let dsee = model.dsee {
                MenuChoice(symbol: "waveform", title: "DSEE Extreme", selected: dsee) {
                    model.change(.setDSEE(!dsee), verify: .dsee)
                }
            }
            if let chat = model.speakToChat {
                MenuChoice(symbol: "bubble.left.and.bubble.right", title: "Speak-to-Chat", selected: chat) {
                    model.change(.setSpeakToChat(!chat), verify: .speakToChat)
                }
            }
        }.font(.system(size: 12)).toggleStyle(.switch).controlSize(.small)
            .disabled(!model.linked || model.policy.blocked)
    }
}

private struct EqualizerEditor: View {
    var model: HeadphoneController
    let equalizer: Equalizer
    @State private var values: [Double]
    init(model: HeadphoneController, equalizer: Equalizer) {
        self.model = model; self.equalizer = equalizer
        _values = State(initialValue: equalizer.values.map(Double.init))
    }
    @State private var editing = false
    private var labels: [String] {
        equalizer.isTenBand ? ["31", "63", "125", "250", "500", "1k", "2k", "4k", "8k", "16k"]
            : ["Bass", "400", "1k", "2.5k", "6.3k", "16k"]
    }
    private var order: [Int] { equalizer.isTenBand ? Array(values.indices) : [1, 2, 3, 4, 5, 0] }
    private func commit() {
        editing = false
        model.change(.setEqualizer(Equalizer(layout: equalizer.layout, values: values.map(Int.init))),
                     verify: .equalizer(layout: equalizer.layout))
    }
    var body: some View {
        VStack(spacing: 7) {
            HStack(alignment: .top, spacing: equalizer.isTenBand ? 3 : 7) {
                ForEach(order, id: \.self) { i in
                    if !equalizer.isTenBand, i == 0 { Divider().frame(height: 139).padding(.horizontal, 2) }
                    VStack(spacing: 5) {
                        Text(equalizer.isTenBand ? "\(Int(values[i]))" : String(format: "%+d", Int(values[i])))
                            .font(.system(size: 10)).monospacedDigit().foregroundStyle(.secondary)
                        VerticalEQSlider(value: $values[i], range: equalizer.isTenBand ? 0...12 : -10...10,
                                         label: !equalizer.isTenBand && i == 0 ? "Clear Bass" : "\(labels[i]) Hz",
                                         onBegin: { editing = true }, onCommit: commit)
                            .frame(width: 18, height: 112)
                        Text(!equalizer.isTenBand && i == 0 ? "Bass" : labels[i])
                            .font(.system(size: equalizer.isTenBand ? 8 : 9)).foregroundStyle(.secondary)
                            .lineLimit(1).minimumScaleFactor(0.8)
                    }.frame(maxWidth: .infinity)
                }
            }
            HStack {
                Text(equalizer.isTenBand ? "Raw steps · 0–12" : "Clear Bass + five bands")
                    .font(.system(size: 10)).foregroundStyle(.secondary)
                Spacer()
                Button("Reset") { model.change(.setEqualizer(Equalizer(layout: equalizer.layout)), verify: .equalizer(layout: equalizer.layout)) }
                    .font(.system(size: 10)).buttonStyle(.plain).foregroundStyle(.secondary)
            }
        }.padding(.vertical, 3)
            .onChange(of: equalizer) { _, eq in if !editing { values = eq.values.map(Double.init) } }
    }
}

private struct VerticalEQSlider: NSViewRepresentable {
    @Binding var value: Double
    let range: ClosedRange<Double>
    let label: String
    let onBegin: () -> Void
    let onCommit: () -> Void
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeNSView(context: Context) -> EQSlider {
        let slider = EQSlider(value: value, minValue: range.lowerBound, maxValue: range.upperBound,
                              target: context.coordinator, action: #selector(Coordinator.changed(_:)))
        slider.isVertical = true; slider.isContinuous = true; slider.controlSize = .small
        slider.setAccessibilityLabel(label)
        slider.onBegin = onBegin; slider.onCommit = onCommit
        return slider
    }
    func updateNSView(_ slider: EQSlider, context: Context) {
        context.coordinator.parent = self
        slider.minValue = range.lowerBound; slider.maxValue = range.upperBound
        if !slider.dragging { slider.doubleValue = value }
        slider.onBegin = onBegin; slider.onCommit = onCommit
    }
    final class Coordinator: NSObject {
        var parent: VerticalEQSlider
        init(_ parent: VerticalEQSlider) { self.parent = parent }
        @objc func changed(_ slider: EQSlider) {
            parent.value = slider.doubleValue.rounded()
            if !slider.dragging { parent.onCommit() }
        }
    }
    final class EQSlider: NSSlider {
        var dragging = false
        var onBegin: (() -> Void)?
        var onCommit: (() -> Void)?
        override func mouseDown(with event: NSEvent) {
            dragging = true; onBegin?()
            super.mouseDown(with: event)
            dragging = false; onCommit?()
        }
    }
}

struct HeadphoneSettingsView: View {
    @Bindable var model: HeadphoneController
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let wearing = model.wearingPause {
                Toggle("Pause when taken off", isOn: Binding(get: { wearing }, set: { model.change(.setWearingPause($0), verify: .wearingPause) }))
            }
            if let options = model.chatOptions {
                Picker("Chat sensitivity", selection: Binding(get: { options.sensitivity }, set: { value in
                    var next = options; next.sensitivity = value; model.change(.setChatOptions(next), verify: .chatOptions)
                })) {
                    Text("Auto").tag(UInt8(0)); Text("High").tag(UInt8(1)); Text("Low").tag(UInt8(2))
                }
                Picker("Chat ends", selection: Binding(get: { options.duration }, set: { value in
                    var next = options; next.duration = value; model.change(.setChatOptions(next), verify: .chatOptions)
                })) {
                    Text("Short").tag(UInt8(0)); Text("Standard").tag(UInt8(1)); Text("Long").tag(UInt8(2)); Text("Never").tag(UInt8(3))
                }
            }
            if let code = model.noiseButton {
                Picker("NC/AMB button", selection: Binding(get: { code }, set: { model.change(.setNoiseButton($0), verify: .noiseButton) })) {
                    Text("NC → Ambient → Off").tag(UInt8(1)); Text("NC ↔ Ambient").tag(UInt8(2))
                    Text("NC ↔ Off").tag(UInt8(3)); Text("Ambient ↔ Off").tag(UInt8(4))
                }
            }
            if let code = model.hardwareAutoOffCode, !model.hardwareAutoOffChoices.isEmpty {
                Picker("Built-in power-off", selection: Binding(get: { code }, set: model.changeAutoOff)) {
                    if ![UInt8(0x10), 0x11].contains(code) { Text("Current (\(code))").tag(code) }
                    if model.hardwareAutoOffChoices.contains(0x10) { Text("When taken off").tag(UInt8(0x10)) }
                    if model.hardwareAutoOffChoices.contains(0x11) { Text("Never").tag(UInt8(0x11)) }
                }
                Text("The built-in setting works without the Mac. The silence timer below requires the Mac to be awake and connected.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if model.noiseControl != nil {
                Toggle("Ambient sound during calls", isOn: $model.ambientDuringCalls)
                Text("Switch to Ambient while a Mac microphone or headphone call is active, then restore the previous mode.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let firmware = model.firmware {
                Text(["Firmware \(firmware)", model.codec].compactMap { $0 }.joined(separator: " · "))
                    .font(.caption).foregroundStyle(.secondary)
            }
        }.disabled(!model.linked || model.policy.blocked)
    }
}
