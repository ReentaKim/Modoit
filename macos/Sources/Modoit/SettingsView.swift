import ModoitCore
import SwiftUI

/// 설정 창 (F-10, SCR-05). ⌘, 또는 앱 메뉴 "설정…"으로 연다
struct SettingsView: View {
    let model: AppModel

    private static let themeLabels = ["system": "시스템", "light": "라이트", "dark": "다크"]
    private static let accentLabels = ["yellow": "노랑", "orange": "주황", "red": "빨강", "pink": "분홍", "purple": "보라",
                                       "blue": "파랑", "green": "초록", "graphite": "흑연"]
    private static let fontLabels = ["system": "시스템 기본", "pretendard": "Pretendard", "serif": "명조", "mono": "고정폭", "custom": "직접 입력"]

    private func bind<T>(_ key: WritableKeyPath<Prefs, T>) -> Binding<T> {
        Binding(get: { model.prefs[keyPath: key] }, set: { v in model.updatePrefs { $0[keyPath: key] = v } })
    }

    var body: some View {
        Form {
            Section("모양") {
                Picker("모양", selection: bind(\.theme)) {
                    ForEach(themes, id: \.self) { Text(Self.themeLabels[$0] ?? $0).tag($0) }
                }
                .pickerStyle(.segmented)
                LabeledContent("강조 색") {
                    HStack(spacing: 8) {
                        ForEach(accents, id: \.self) { name in
                            let on = model.prefs.accent == name
                            Button {
                                model.updatePrefs { $0.accent = name }
                            } label: {
                                Circle()
                                    .fill(accentTint(name))
                                    .frame(width: 18, height: 18)
                                    .overlay { Circle().strokeBorder(.primary.opacity(on ? 0.9 : 0), lineWidth: 2).padding(-3) }
                            }
                            .buttonStyle(.plain)
                            .help(Self.accentLabels[name] ?? name)
                            .accessibilityLabel(Self.accentLabels[name] ?? name)
                            .accessibilityAddTraits(on ? .isSelected : [])
                        }
                    }
                    .padding(.vertical, 3)
                }
            }
            Section("글꼴") {
                Picker("글꼴", selection: bind(\.fontFamily)) {
                    ForEach(fontFamilies, id: \.self) { Text(Self.fontLabels[$0] ?? $0).tag($0) }
                }
                if model.prefs.fontFamily == "custom" {
                    CustomFontField(model: model)
                }
                LabeledContent("본문 크기") {
                    HStack {
                        Slider(value: bind(\.fontSize), in: fontSizeMin...fontSizeMax, step: 1)
                        Text("\(Int(model.prefs.fontSize))").monospacedDigit().frame(width: 24, alignment: .trailing)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 440)
        .fixedSize(horizontal: false, vertical: true)
        .tint(accentTint(model.prefs.accent))
    }
}

/// 직접 입력 글꼴. 치는 동안에는 저장하지 않는다(저장하며 앞뒤 공백을 다듬어 입력이 튄다). 떠나거나 Return에 저장 (FR-24)
private struct CustomFontField: View {
    let model: AppModel
    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        TextField("글꼴 이름", text: $text, prompt: Text("예: Nanum Gothic"))
            .focused($focused)
            .onAppear { text = model.prefs.customFont }
            .onSubmit(commit)
            .onChange(of: focused) { if !focused { commit() } }
            .onDisappear(perform: commit)
    }

    private func commit() {
        model.updatePrefs { $0.customFont = text }
    }
}
