import SwiftUI

// Keep Build 29's native control on older systems. The modern control changes
// only the header; it still drives the same binding and native page container.
struct LibraryTabPicker: View {
    let options: [LibraryTab]
    @Binding var selection: LibraryTab

    var body: some View {
        Group {
            #if compiler(>=6.2)
            if #available(iOS 26.0, *), !AppAppearance.forceTraditional, !useReferencePicker {
                // Measure the native Picker, then place two siblings in its
                // exact bounds. Hiding/disabling the sizing reference must not
                // propagate to the interactive glass view.
                LibraryTabSizeLayout {
                    nativePicker.hidden().allowsHitTesting(false).accessibilityHidden(true)
                    LiquidLibraryTabs(options: options, selection: $selection).id(options)
                        .accessibilityIdentifier("libraryTabs")
                }
            } else { nativePicker.accessibilityIdentifier("libraryTabs") }
            #else
            nativePicker.accessibilityIdentifier("libraryTabs")
            #endif
        }
    }

    private var nativePicker: some View {
        Picker("浏览类型", selection: $selection) {
            ForEach(options, id: \.self) { Text($0.rawValue).tag($0) }
        }.pickerStyle(.segmented).labelsHidden()
    }

    private var useReferencePicker: Bool {
        #if DEBUG
        return ProcessInfo.processInfo.arguments.contains("--build29-tabs-fixture")
        #else
        return false
        #endif
    }
}

#if compiler(>=6.2)
private struct LibraryTabSizeLayout: Layout {
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        subviews[0].sizeThatFits(proposal)
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for subview in subviews {
            subview.place(at: bounds.origin, anchor: .topLeading, proposal: ProposedViewSize(bounds.size))
        }
    }
}

@available(iOS 26.0, *)
private struct LiquidLibraryTabs: View {
    let options: [LibraryTab]
    @Binding var selection: LibraryTab
    @GestureState private var dragPosition: CGFloat?
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private let inset: CGFloat = 2

    private var position: CGFloat {
        dragPosition ?? CGFloat(options.firstIndex(of: selection) ?? 0)
    }

    var body: some View {
        GeometryReader { geometry in
            control(width: geometry.size.width, height: geometry.size.height)
        }
    }

    private func control(width: CGFloat, height: CGFloat) -> some View {
        HStack(spacing: 0) {
            ForEach(options, id: \.self) { option in
                Button { selection = option } label: {
                    Text(option.rawValue)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .contentShape(Rectangle())
                }.buttonStyle(.plain)
                    .accessibilityAddTraits(selection == option ? [.isSelected] : [])
            }
        }
        .font(.subheadline.weight(.medium))
        .lineLimit(1).minimumScaleFactor(0.75)
        .padding(.horizontal, inset)
        // Geometry is proposed by LibraryTabSizeLayout; it cannot enlarge the
        // header. Read it synchronously, without a preference crossing glass.
        .frame(width: width, height: height)
        // One glass surface on the view that owns the gesture. A moving shape
        // defines the lens without an opaque tint or a non-interactive overlay.
        .glassEffect(.regular.interactive(), in: LibrarySelectionLens(position: position, count: options.count, inset: inset))
        .background(Capsule().fill(.primary.opacity(scheme == .dark ? 0.12 : 0.06)))
        .contentShape(Rectangle())
        .highPriorityGesture(DragGesture(minimumDistance: 0)
            .updating($dragPosition) { value, state, transaction in
                transaction.animation = nil
                state = position(at: value.location.x, width: width)
            }
            .onChanged { value in choose(at: value.location.x, width: width) }
            .onEnded { value in
                choose(at: value.location.x, width: width)
                #if DEBUG
                print("TAB_DRAG_END x=\(value.location.x) width=\(width) selection=\(selection.rawValue)")
                #endif
            })
        .animation(dragPosition == nil && !reduceMotion ? .spring(response: 0.24, dampingFraction: 0.86) : nil, value: position)
        .accessibilityElement(children: .contain)
    }

    private func position(at x: CGFloat, width: CGFloat) -> CGFloat {
        let slot = max(1, width - 2 * inset) / CGFloat(max(1, options.count))
        return min(CGFloat(max(0, options.count - 1)), max(0, (x - inset) / slot - 0.5))
    }

    private func choose(at x: CGFloat, width: CGFloat) {
        guard width > 2 * inset, !options.isEmpty else { return }
        let option = options[Int(position(at: x, width: width).rounded())]
        if selection != option {
            selection = option
            #if DEBUG
            print("TAB_DRAG_SELECT x=\(x) width=\(width) selection=\(option.rawValue)")
            #endif
        }
    }
}

private struct LibrarySelectionLens: Shape {
    var position: CGFloat
    let count: Int
    let inset: CGFloat
    var animatableData: CGFloat {
        get { position }
        set { position = newValue }
    }
    func path(in rect: CGRect) -> Path {
        let track = rect.insetBy(dx: inset, dy: inset)
        let slot = max(0, track.width) / CGFloat(max(1, count))
        let bounded = min(CGFloat(max(0, count - 1)), max(0, position))
        return Capsule().path(in: CGRect(x: track.minX + bounded * slot, y: track.minY,
                                        width: slot, height: max(0, track.height)))
    }
}
#endif

// Keep native controls mounted when unrelated progress values change.
struct StableControl<Key: Equatable, Content: View>: View, Equatable {
    let key: Key
    let content: Content
    init(key: Key, @ViewBuilder content: () -> Content) {
        self.key = key; self.content = content()
    }
    static func == (lhs: Self, rhs: Self) -> Bool { lhs.key == rhs.key }
    var body: some View { content }
}

struct LibraryMenuState: Equatable {
    let pageOwner: ObjectIdentifier
    let page: LibraryTab
    let mode: SelectionMode
    let visibility: FavoriteVisibility
    let showDownloadedRecommendations: Bool
    let hasSelection: Bool
    let deletionAnchor: String?
    let deletionIDs: Set<String>
}

struct FolderMenuState: Equatable {
    let pageOwner: ObjectIdentifier
    let selected: String
    let folders: [String]
}

#if DEBUG
// Baseline for comparing the platform's own pressed/dragged appearance.
struct NativePickerReferenceView: View {
    @State private var selection: LibraryTab = .favorites
    var body: some View {
        NavigationStack {
            VStack {
                Picker("浏览类型", selection: $selection) {
                    ForEach([LibraryTab.downloads, .favorites, .recommendations], id: \.self) {
                        Text($0.rawValue).tag($0)
                    }
                }.pickerStyle(.segmented).labelsHidden()
                    .accessibilityIdentifier("libraryTabs")
                Spacer()
            }.padding(.horizontal, 16)
                .background(Color(uiColor: .systemGroupedBackground))
                .navigationTitle("系统控件对照").navigationBarTitleDisplayMode(.inline)
        }
    }
}
#endif
