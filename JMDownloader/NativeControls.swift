import SwiftUI

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
