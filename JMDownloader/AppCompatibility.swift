import SwiftUI
import UIKit

enum AppAppearance {
    static var forceTraditional: Bool {
        #if DEBUG
        return ProcessInfo.processInfo.arguments.contains("--traditional-ui-fixture")
        #else
        return false
        #endif
    }
    static var systemDescription: String {
        let version = UIDevice.current.systemVersion
        if #available(iOS 26.0, *), !forceTraditional { return "iOS \(version) · 液态玻璃" }
        return "iOS \(version) · 传统 SwiftUI"
    }
}

// Layout uses the available safe-area viewport, not model names or inches.
struct AppLayout: Equatable {
    let width: CGFloat
    let height: CGFloat
    var contentWidth: CGFloat { min(max(0, width), 600) }
    var sideInset: CGFloat { contentWidth <= 375 ? 12 : 16 }
    var cardWidth: CGFloat { max(0, contentWidth - sideInset * 2) }
    var previewHeight: CGFloat { max(140, min(420, height * 0.65)) }
}
struct CardWidthKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}
private struct AppLayoutKey: EnvironmentKey {
    static let defaultValue = AppLayout(width: 390, height: 750)
}
extension EnvironmentValues {
    var appLayout: AppLayout {
        get { self[AppLayoutKey.self] }
        set { self[AppLayoutKey.self] = newValue }
    }
}

struct AppButton: View {
    let title: String
    let systemImage: String
    let role: ButtonRole?
    let action: () -> Void
    init(_ title: String, systemImage: String, role: ButtonRole? = nil, action: @escaping () -> Void) {
        self.title = title; self.systemImage = systemImage; self.role = role; self.action = action
    }
    var body: some View { Button(role: role, action: action) { Label(title, systemImage: systemImage) } }
}

struct AppEmptyView: View {
    let title: String
    let systemImage: String
    var description: Text?
    init(_ title: String, systemImage: String, description: Text? = nil) {
        self.title = title; self.systemImage = systemImage; self.description = description
    }
    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: systemImage).font(.system(size: 42)).foregroundStyle(.secondary)
            Text(title).font(.headline)
            if let description { description.font(.subheadline).foregroundStyle(.secondary) }
        }.multilineTextAlignment(.center).padding(24).frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct ChangeCompatibility<Value: Equatable>: ViewModifier {
    let value: Value
    let action: (Value, Value) -> Void
    @State private var previous: Value
    init(value: Value, action: @escaping (Value, Value) -> Void) {
        self.value = value; self.action = action; _previous = State(initialValue: value)
    }
    func body(content: Content) -> some View {
        content.onChange(of: value) { next in
            let old = previous; previous = next; action(old, next)
        }
    }
}

enum AppFeedback { case success, error }
extension View {
    func onChangeCompat<Value: Equatable>(of value: Value, perform action: @escaping (Value, Value) -> Void) -> some View {
        modifier(ChangeCompatibility(value: value, action: action))
    }
    func appFeedback<Value: Equatable>(_ feedback: AppFeedback, trigger: Value) -> some View {
        onChangeCompat(of: trigger) { _, _ in
            UINotificationFeedbackGenerator().notificationOccurred(feedback == .success ? .success : .error)
        }
    }
    @ViewBuilder func appPulse(active: Bool) -> some View {
        if #available(iOS 17.0, *) { symbolEffect(.pulse, options: .repeating, isActive: active) }
        else { self }
    }
    @ViewBuilder func appCompactConfirmation() -> some View {
        if #available(iOS 16.4, *) { presentationCompactAdaptation(.popover) }
        else { presentationDetents([.height(160)]).presentationDragIndicator(.visible) }
    }
}
extension Animation {
    static var appTransition: Animation { .interactiveSpring(response: 0.32, dampingFraction: 0.88) }
}
