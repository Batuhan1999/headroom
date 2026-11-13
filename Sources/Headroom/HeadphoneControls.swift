import SwiftUI
import HeadroomCore

struct HeadphoneControls: View {
    @Bindable var model: HeadphoneController
    @State private var showEQ = false
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
                        model.change(.setPreset(preset), verify: .equalizer)
                    })) {
                        if EQPreset(rawValue: eq.preset) == nil { Text(eq.title).tag(eq.preset) }
                        ForEach(EQPreset.allCases) { Text($0.title).tag($0.rawValue) }
                    }.labelsHidden().frame(maxWidth: 160)
                }
                DisclosureGroup("Adjust equalizer", isExpanded: $showEQ) {
                    EqualizerEditor(model: model, equalizer: eq).padding(.top, 8)
                }
            }
            if let dsee = model.dsee {
                Toggle("DSEE Extreme", isOn: Binding(get: { dsee }, set: { model.change(.setDSEE($0), verify: .dsee) }))
            }
            if let chat = model.speakToChat {
                Toggle("Speak-to-Chat", isOn: Binding(get: { chat }, set: { model.change(.setSpeakToChat($0), verify: .speakToChat) }))
            }
        }.font(.system(size: 12)).toggleStyle(.switch).controlSize(.small)
            .disabled(!model.linked || model.policy.blocked)
    }
}

private struct EqualizerEditor: View {
    var model: HeadphoneController
    let equalizer: Equalizer
    @State private var values = Array(repeating: 0.0, count: 6)
    @State private var editing = false
    private let labels = ["Bass", "400", "1k", "2.5k", "6.3k", "16k"]
    var body: some View {
        VStack(spacing: 6) {
            ForEach(0..<6, id: \.self) { i in
                HStack(spacing: 8) {
                    Text(labels[i]).foregroundStyle(.secondary).frame(width: 32, alignment: .leading)
                    Slider(value: $values[i], in: -10...10, step: 1, onEditingChanged: { isEditing in
                        editing = isEditing
                        if !isEditing { model.change(.setEqualizer(Equalizer(values: values.map(Int.init))), verify: .equalizer) }
                    }).accessibilityLabel(i == 0 ? "Clear Bass" : "\(labels[i]) Hz")
                    Text(String(format: "%+d", Int(values[i]))).monospacedDigit().frame(width: 25, alignment: .trailing)
                }
            }
            HStack {
                Text("Clear Bass + five bands · −10 to +10").font(.system(size: 10)).foregroundStyle(.secondary)
                Spacer()
                Button("Reset") { model.change(.setEqualizer(Equalizer()), verify: .equalizer) }
            }.padding(.top, 4)
        }.onAppear { values = equalizer.values.map(Double.init) }
            .onChange(of: equalizer) { _, eq in if !editing { values = eq.values.map(Double.init) } }
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
