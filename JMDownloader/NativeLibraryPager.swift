import SwiftUI
import UIKit
import Combine

@MainActor final class LibraryPagingPosition {
    let positions = CurrentValueSubject<CGFloat, Never>(1)
    var onTopDrag: ((CGFloat) -> Void)?
    var onTopDragEnd: ((Int) -> Void)?
    func report(_ position: CGFloat) {
        let next = min(CGFloat(LibraryTab.allCases.count - 1), max(0, position))
        if abs(positions.value - next) > 0.0001 { positions.send(next) }
    }
}

// Keep the same system segmented control used by Build 22's segmented Picker.
// No replacement backgrounds, glass layers, labels or gesture recognizers.
struct NativeLibraryTabs: UIViewRepresentable {
    @Binding var selection: LibraryTab
    let paging: LibraryPagingPosition
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeUIView(context: Context) -> TrackingLibraryTabs {
        let control = TrackingLibraryTabs(paging: paging)
        control.addTarget(context.coordinator, action: #selector(Coordinator.selectTab(_:)), for: .valueChanged)
        return control
    }
    func updateUIView(_ control: TrackingLibraryTabs, context: Context) {
        context.coordinator.parent = self
        control.synchronizeSelection(LibraryTab.allCases.firstIndex(of: selection)!)
    }
    final class Coordinator: NSObject {
        var parent: NativeLibraryTabs
        init(_ parent: NativeLibraryTabs) { self.parent = parent }
        @objc func selectTab(_ control: TrackingLibraryTabs) {
            guard !control.handlingTouch, LibraryTab.allCases.indices.contains(control.selectedSegmentIndex) else { return }
            parent.selection = LibraryTab.allCases[control.selectedSegmentIndex]
        }
    }
}

final class TrackingLibraryTabs: UISegmentedControl {
    private let paging: LibraryPagingPosition
    private var subscription: AnyCancellable?
    private var transition: UIViewPropertyAnimator?
    private var transitionStart: Int?
    private var touchStart = 1
    private var position: CGFloat = 1
    private(set) var handlingTouch = false

    init(paging: LibraryPagingPosition) {
        self.paging = paging
        super.init(frame: .zero)
        for (index, tab) in LibraryTab.allCases.enumerated() {
            insertSegment(withTitle: tab.rawValue, at: index, animated: false)
        }
        selectedSegmentIndex = 1
        accessibilityIdentifier = "libraryTabs"
        accessibilityLabel = "浏览类型"
        subscription = paging.positions.sink { [weak self] in self?.followPage($0) }
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    func synchronizeSelection(_ index: Int) {
        guard !handlingTouch, transition == nil, selectedSegmentIndex != index else { return }
        selectedSegmentIndex = index
    }
    private func settle(at index: Int) {
        transition?.stopAnimation(true)
        transition = nil
        transitionStart = nil
        UIView.performWithoutAnimation {
            self.selectedSegmentIndex = index
            self.setNeedsLayout()
            self.layoutIfNeeded()
        }
    }
    private func followPage(_ value: CGFloat) {
        position = value
        guard !handlingTouch, bounds.width > 0 else { return }
        let lower = min(numberOfSegments - 1, max(0, Int(value.rounded(.down))))
        let fraction = value - CGFloat(lower)
        if fraction < 0.001 || lower == numberOfSegments - 1 {
            settle(at: Int(value.rounded()))
            return
        }
        if transitionStart != lower {
            settle(at: lower)
            let animator = UIViewPropertyAnimator(duration: 0.3, curve: .linear) { [weak self] in
                guard let self else { return }
                self.selectedSegmentIndex = lower + 1
                self.setNeedsLayout()
                self.layoutIfNeeded()
            }
            animator.scrubsLinearly = true
            transitionStart = lower
            transition = animator
            animator.startAnimation()
            animator.pauseAnimation()
        }
        transition?.fractionComplete = fraction
    }
    private func fingerPosition(_ touch: UITouch) -> CGFloat {
        let width = max(1, bounds.width) / CGFloat(numberOfSegments)
        return min(CGFloat(numberOfSegments - 1), max(0, touch.location(in: self).x / width - 0.5))
    }
    override func beginTracking(_ touch: UITouch, with event: UIEvent?) -> Bool {
        touchStart = Int(position.rounded())
        settle(at: touchStart)
        handlingTouch = true
        let accepted = super.beginTracking(touch, with: event)
        if !accepted { handlingTouch = false }
        return accepted
    }
    override func continueTracking(_ touch: UITouch, with event: UIEvent?) -> Bool {
        let accepted = super.continueTracking(touch, with: event)
        if accepted { paging.onTopDrag?(fingerPosition(touch)) }
        return accepted
    }
    override func endTracking(_ touch: UITouch?, with event: UIEvent?) {
        super.endTracking(touch, with: event)
        let target = touch.map { Int(fingerPosition($0).rounded()) } ?? selectedSegmentIndex
        handlingTouch = false
        selectedSegmentIndex = target
        paging.onTopDragEnd?(target)
        sendActions(for: .valueChanged)
    }
    override func cancelTracking(with event: UIEvent?) {
        super.cancelTracking(with: event)
        handlingTouch = false
        settle(at: touchStart)
        paging.onTopDragEnd?(touchStart)
    }
}

/// Native paging keeps both pages under the finger throughout a drag. Each
/// hosting view owns a full viewport without adding another safe-area inset.
struct NativeLibraryPager: UIViewControllerRepresentable {
    @Binding var selection: LibraryTab
    let paging: LibraryPagingPosition
    let animated: Bool
    let pages: [AnyView]

    func makeUIViewController(context: Context) -> LibraryPagerController {
        let controller = LibraryPagerController()
        configure(controller)
        return controller
    }
    func updateUIViewController(_ controller: LibraryPagerController, context: Context) { configure(controller) }
    private func configure(_ controller: LibraryPagerController) {
        controller.onPosition = { paging.report($0) }
        let shouldAnimate = animated
        Task { @MainActor in
            paging.onTopDrag = { [weak controller] in controller?.setInteractivePosition($0) }
            paging.onTopDragEnd = { [weak controller] in controller?.finishInteractivePosition($0, animated: shouldAnimate) }
        }
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
    var onPosition: (@MainActor (CGFloat) -> Void)?

    func setInteractivePosition(_ position: CGFloat) {
        loadViewIfNeeded()
        guard scroll.bounds.width > 0 else { return }
        let bounded = min(CGFloat(max(0, hosts.count - 1)), max(0, position))
        scroll.setContentOffset(CGPoint(x: bounded * scroll.bounds.width, y: 0), animated: false)
    }
    func finishInteractivePosition(_ index: Int, animated: Bool) {
        loadViewIfNeeded()
        guard scroll.bounds.width > 0 else { return }
        let bounded = min(max(0, hosts.count - 1), max(0, index))
        let target = CGPoint(x: CGFloat(bounded) * scroll.bounds.width, y: 0)
        let needsScroll = abs(scroll.contentOffset.x - target.x) > 0.5
        scroll.setContentOffset(target, animated: animated && needsScroll)
        if !animated || !needsScroll { finishPaging() }
    }

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
    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        guard scrollView.bounds.width > 0, !hosts.isEmpty else { return }
        onPosition?(scrollView.contentOffset.x / scrollView.bounds.width)
    }
    func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
        if !decelerate { finishPaging() }
    }
    func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) { finishPaging() }
    func scrollViewDidEndScrollingAnimation(_ scrollView: UIScrollView) { finishPaging() }
}
