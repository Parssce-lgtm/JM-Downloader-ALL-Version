import SwiftUI
import UIKit

extension Preferences {
    var accent: Color {
        switch themeColor ?? "橙" {
        case "蓝": .blue
        case "黑 / 白": Color(uiColor: .label)
        case "粉": .pink
        case "绿": .green
        default: .orange
        }
    }
    var colorScheme: ColorScheme? {
        switch appearance ?? "跟随系统" {
        case "浅色": .light
        case "深色": .dark
        default: nil
        }
    }
}

struct ThemeSettingsView: View {
    @ObservedObject var store: AppStore
    @State private var currentIcon = UIApplication.shared.alternateIconName
    @State private var changingIcon = false
    private let icons: [(String, String?)] = [("经典书页", nil), ("蓝色书签", "IconBlue"), ("黑白书架", "IconMono"), ("粉色星光", "IconPink"), ("绿色叶页", "IconGreen")]
    var body: some View {
        Form {
            Section("外观") {
                Picker("显示模式", selection: Binding(get: { store.preferences.appearance ?? "跟随系统" }, set: {
                    var value = store.preferences; value.appearance = $0; store.savePreferences(value)
                })) {
                    ForEach(["跟随系统", "浅色", "深色"], id: \.self) { Text($0).tag($0) }
                }.pickerStyle(.segmented)
            }
            Section("主题颜色") {
                ForEach(["蓝", "黑 / 白", "橙", "粉", "绿"], id: \.self) { name in
                    Button {
                        var value = store.preferences; value.themeColor = name; store.savePreferences(value)
                    } label: {
                        HStack {
                            Circle().fill(color(name)).frame(width: 22, height: 22)
                            Text(name).foregroundStyle(Color.primary)
                            Spacer()
                            if (store.preferences.themeColor ?? "橙") == name { Image(systemName: "checkmark").foregroundStyle(store.preferences.accent) }
                        }.contentShape(Rectangle())
                    }.buttonStyle(.plain)
                        .accessibilityIdentifier("theme-" + name)
                        .accessibilityValue((store.preferences.themeColor ?? "橙") == name ? "已选择" : "未选择")
                }
            }
            Section {
                ForEach(icons, id: \.0) { title, name in
                    Button {
                        guard !changingIcon, currentIcon != name else { return }; changingIcon = true
                        let previous = currentIcon
                        currentIcon = name
                        UIApplication.shared.setAlternateIconName(name) { error in
                            Task { @MainActor in
                                changingIcon = false
                                if let error { currentIcon = previous; store.report(error) }
                                else { currentIcon = name }
                            }
                        }
                    } label: {
                        HStack(spacing: 14) {
                            Image("Preview" + (name ?? "AppIcon")).resizable().frame(width: 48, height: 48)
                                .clipShape(RoundedRectangle(cornerRadius: 11))
                            Text(title).foregroundStyle(Color.primary)
                            Spacer()
                            if currentIcon == name { Image(systemName: "checkmark").foregroundStyle(store.preferences.accent) }
                        }.padding(.vertical, 4).contentShape(Rectangle())
                    }.buttonStyle(.plain).disabled(changingIcon || !UIApplication.shared.supportsAlternateIcons)
                        .accessibilityIdentifier("icon-" + (name ?? "AppIcon"))
                        .accessibilityValue(currentIcon == name ? "已选择" : "未选择")
                }
            } header: { Text("App 图标") } footer: { Text("保留经典图标，新增四款。选择后由 iOS 更换主屏幕图标。") }
            Section("效果预览") {
                Label("JM downloader", systemImage: "books.vertical.fill").foregroundStyle(store.preferences.accent)
                ProgressView(value: 0.65).tint(store.preferences.accent)
                Text("收藏、选择标记与下载进度同步使用所选主题色。")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }.navigationTitle("主题设置").navigationBarTitleDisplayMode(.inline)
            .toolbarColorScheme(store.preferences.colorScheme, for: .navigationBar)
            .tint(store.preferences.accent)
    }
    private func color(_ name: String) -> Color { var value = Preferences(); value.themeColor = name; return value.accent }
}

// A non-canceling window gesture also covers navigation bars and presented sheets.
// Editing controls keep focus; tapping any other area dismisses the keyboard.
struct KeyboardDismissInstaller: UIViewRepresentable {
    final class HostView: UIView {
        var coordinator: Coordinator?
        override func didMoveToWindow() { super.didMoveToWindow(); coordinator?.attach(to: window) }
    }
    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        weak var window: UIWindow?
        var gesture: UITapGestureRecognizer?
        func attach(to window: UIWindow?) {
            guard self.window !== window else { return }
            if let gesture { self.window?.removeGestureRecognizer(gesture) }
            self.window = window
            guard let window else { return }
            let gesture = UITapGestureRecognizer(target: self, action: #selector(dismissKeyboard))
            gesture.cancelsTouchesInView = false; gesture.delegate = self
            window.addGestureRecognizer(gesture); self.gesture = gesture
        }
        @objc func dismissKeyboard() { window?.endEditing(true) }
        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
            var view = touch.view
            while let current = view {
                if current is UITextField || current is UITextView { return false }
                view = current.superview
            }
            return true
        }
        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool { true }
    }
    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeUIView(context: Context) -> HostView {
        let view = HostView(); view.isUserInteractionEnabled = false; view.coordinator = context.coordinator; return view
    }
    func updateUIView(_ uiView: HostView, context: Context) { context.coordinator.attach(to: uiView.window) }
    static func dismantleUIView(_ uiView: HostView, coordinator: Coordinator) { coordinator.attach(to: nil) }
}
