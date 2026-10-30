import AmplayerKit
import SwiftUI

/// 音效：一键预设 + 自定义（音色、空间、动态、变速变调）
struct SoundEffectsView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss

    private var player: PlayerController { app.player }
    private let columns = [GridItem(.adaptive(minimum: 150), spacing: 10)]

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    LazyVGrid(columns: columns, spacing: 10) {
                        ForEach(SoundEffectPreset.all) { preset in
                            presetCard(preset)
                        }
                    }
                    .padding(.vertical, 4)
                    .listRowInsets(EdgeInsets(top: 8, leading: 12, bottom: 8, trailing: 12))
                    .listRowBackground(Color.clear)
                } header: {
                    Text("一键音效")
                } footer: {
                    Text("音效叠加在经典 10 段均衡器之上。环绕、8D 旋转戴耳机效果最明显。")
                }

                Section {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 96), spacing: 8)], spacing: 8) {
                        ForEach(EqualizerPreset.builtIn) { eqChip($0) }
                    }
                    .padding(.vertical, 4)
                    .listRowInsets(EdgeInsets(top: 8, leading: 12, bottom: 8, trailing: 12))
                    .listRowBackground(Color.clear)
                } header: {
                    Text("均衡器预设")
                } footer: {
                    Text("设置经典 10 段均衡器，可以和上面的音效一起用。")
                }

                Section("音色") {
                    slider("低音", value: binding(\.bass), range: -12...12, unit: "dB")
                    slider("人声", value: binding(\.vocal), range: -12...12, unit: "dB")
                    slider("高音", value: binding(\.treble), range: -12...12, unit: "dB")
                }

                Section("空间") {
                    Picker("混响", selection: binding(\.reverbType)) {
                        ForEach(SoundEffects.Reverb.allCases) { Text($0.title).tag($0) }
                    }
                    slider("混响量", value: binding(\.reverbMix), range: 0...60, unit: "%", step: 1)
                    slider("回声", value: binding(\.echoMix), range: 0...50, unit: "%", step: 1)
                    if player.effects.echoMix > 0 {
                        slider("回声间隔", value: binding(\.echoTime), range: 0.02...0.6, unit: "秒", step: 0.01)
                    }
                    slider("环绕", value: binding(\.surround), range: 0...1, unit: "", step: 0.05)
                    if player.effects.surround > 0 {
                        slider("旋转速度", value: binding(\.surroundSpeed), range: 0.02...0.5, unit: "圈/秒", step: 0.01)
                    }
                }

                Section("动态与质感") {
                    Toggle("响度均衡", isOn: binding(\.loudness))
                    slider("黑胶底噪", value: binding(\.vinylNoise), range: 0...1, unit: "", step: 0.05)
                }

                Section {
                    slider("变速", value: binding(\.rate), range: 0.5...2, unit: "×", step: 0.05)
                    slider("变调", value: binding(\.pitch), range: -12...12, unit: "半音", step: 0.5)
                } header: {
                    Text("速度与音调")
                } footer: {
                    Text("变速不变调，变调不变速。练歌、听播客、做 Slowed + Reverb 都用得上。")
                }

                Section {
                    Button("恢复原声", role: .destructive) { player.applyEffectPreset(SoundEffectPreset.all[0]) }
                        .disabled(player.effects.isNeutral)
                }
            }
            .navigationTitle("音效")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } } }
        }
        .presentationDetents([.medium, .large])
    }

    private func presetCard(_ preset: SoundEffectPreset) -> some View {
        let selected = player.effects.presetID == preset.id
        return Button { player.applyEffectPreset(preset) } label: {
            VStack(alignment: .leading, spacing: 6) {
                Image(systemName: preset.symbol)
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(selected ? Color.black : Color.orange)
                    .frame(height: 24)
                Text(preset.name).font(.subheadline.weight(.semibold))
                Text(preset.detail).font(.caption2).lineLimit(2).multilineTextAlignment(.leading)
                    .foregroundStyle(selected ? Color.black.opacity(0.7) : Color.secondary)
            }
            .frame(maxWidth: .infinity, minHeight: 92, alignment: .topLeading)
            .padding(10)
            .background(selected ? Color.orange : Color(white: 0.16), in: RoundedRectangle(cornerRadius: 12))
            .foregroundStyle(selected ? Color.black : Color.primary)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("音效：\(preset.name)")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func eqChip(_ preset: EqualizerPreset) -> some View {
        let selected = player.equalizer.bands == preset.bands && player.equalizer.preamp == preset.preamp
        return Button {
            player.applyPreset(preset)
        } label: {
            Text(preset.name)
                .font(.subheadline.weight(.medium))
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .frame(maxWidth: .infinity, minHeight: 36)
                .background(selected ? Color.orange : Color(white: 0.16), in: RoundedRectangle(cornerRadius: 10))
                .foregroundStyle(selected ? Color.black : Color.primary)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(preset.name)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    /// 改任何一项都算“自定义”
    private func binding<T>(_ key: WritableKeyPath<SoundEffects, T>) -> Binding<T> {
        Binding(
            get: { player.effects[keyPath: key] },
            set: { value in
                var e = player.effects
                e[keyPath: key] = value
                e.presetID = e.isNeutral ? "off" : SoundEffectPreset.custom
                player.effects = e
            }
        )
    }

    private func slider(_ title: String, value: Binding<Float>, range: ClosedRange<Float>, unit: String, step: Float = 0.5) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(title)
                Spacer()
                Text(format(value.wrappedValue, unit: unit, step: step))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            Slider(value: value, in: range, step: step)
                .accessibilityLabel(title)
        }
    }

    private func format(_ v: Float, unit: String, step: Float) -> String {
        let number: String
        if step >= 1 { number = String(format: "%.0f", v) }
        else if step >= 0.1 { number = String(format: "%.1f", v) }
        else { number = String(format: "%.2f", v) }
        let signed = (unit == "dB" || unit == "半音") && v > 0 ? "+" + number : number
        return unit.isEmpty ? signed : "\(signed) \(unit)"
    }
}
