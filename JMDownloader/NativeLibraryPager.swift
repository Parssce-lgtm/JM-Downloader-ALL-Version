import SwiftUI
import UIKit

/// Native paging keeps both pages under the finger throughout a drag. Each
/// hosting view owns a full viewport without adding another safe-area inset.
struct NativeLibraryPager: UIViewControllerRepresentable {
    @Binding var selection: LibraryTab
    let animated: Bool
    let pages: [AnyView]

    func makeUIViewController(context: Context) -> LibraryPagerController {
        let controller = LibraryPagerController()
        configure(controller)
        return controller
    }
    func updateUIViewController(_ controller: LibraryPagerController, context: Context) { configure(controller) }
    private func configure(_ controller: LibraryPagerController) {
        controller.onSelection = { index in
            let next = LibraryTab.allCases[index]
            if selection != next { selection = next }
        }
        controller.update(pages: pages, selectedIndex: LibraryTab.allCases.firstIndex(of: selection)!, animated: animated)
    }
}

final class LibraryPagerController: UIViewController, UIScrollViewDelegate {
    private let scroll = UIScrollView()
    private var hosts: [UIHostingController<AnyView>] = []
    private var selectedIndex = 0
    private var lastSize: CGSize = .zero
    var onSelection: ((Int) -> Void)?

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .clear
        scroll.backgroundColor = .clear
        scroll.isPagingEnabled = true
        scroll.isDirectionalLockEnabled = true
        scroll.showsHorizontalScrollIndicator = false
        scroll.showsVerticalScrollIndicator = false
        scroll.alwaysBounceVertical = false
        scroll.contentInsetAdjustmentBehavior = .never
        scroll.keyboardDismissMode = .onDrag
        scroll.accessibilityIdentifier = "libraryPager"
        scroll.delegate = self
        view.addSubview(scroll)
    }

    func update(pages: [AnyView], selectedIndex index: Int, animated: Bool) {
        loadViewIfNeeded()
        if hosts.isEmpty {
            for page in pages {
                let host = UIHostingController(rootView: hostingPage(page))
                if #available(iOS 16.4, *) { host.safeAreaRegions = [] }
                host.view.backgroundColor = .clear
                addChild(host)
                scroll.addSubview(host.view)
                host.didMove(toParent: self)
                hosts.append(host)
            }
        } else {
            for (host, page) in zip(hosts, pages) { host.rootView = hostingPage(page) }
        }
        let changed = selectedIndex != index
        selectedIndex = index
        updateAccessibility()
        view.setNeedsLayout()
        if changed && scroll.bounds.width > 0 && !scroll.isDragging {
            scroll.setContentOffset(CGPoint(x: CGFloat(index) * scroll.bounds.width, y: 0), animated: animated)
        }
    }

    private func hostingPage(_ page: AnyView) -> AnyView {
        if #available(iOS 16.4, *) { return page }
        return AnyView(page.ignoresSafeArea(.container))
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        let size = view.bounds.size
        scroll.frame = view.bounds
        for (index, host) in hosts.enumerated() {
            host.view.frame = CGRect(x: CGFloat(index) * size.width, y: 0, width: size.width, height: size.height)
        }
        scroll.contentSize = CGSize(width: CGFloat(hosts.count) * size.width, height: size.height)
        if lastSize != size {
            lastSize = size
            if !scroll.isDragging && !scroll.isDecelerating {
                scroll.setContentOffset(CGPoint(x: CGFloat(selectedIndex) * size.width, y: 0), animated: false)
            }
        }
    }

    private func updateAccessibility() {
        for (index, host) in hosts.enumerated() {
            host.view.accessibilityElementsHidden = index != selectedIndex
            host.view.isUserInteractionEnabled = index == selectedIndex
        }
    }
    private func finishPaging() {
        guard scroll.bounds.width > 0, !hosts.isEmpty else { return }
        let index = min(hosts.count - 1, max(0, Int((scroll.contentOffset.x / scroll.bounds.width).rounded())))
        guard index != selectedIndex else { return }
        selectedIndex = index
        updateAccessibility()
        onSelection?(index)
    }
    func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
        if !decelerate { finishPaging() }
    }
    func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) { finishPaging() }
    func scrollViewDidEndScrollingAnimation(_ scrollView: UIScrollView) { finishPaging() }
}
