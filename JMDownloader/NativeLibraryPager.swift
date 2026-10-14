import SwiftUI
import UIKit
import Combine

// Only the shared notice viewport subscribes to these frame-by-frame updates. The
// SwiftUI page tree does not rebuild while the finger is moving.
@MainActor final class LibraryPagingPosition {
    let positions = CurrentValueSubject<CGFloat, Never>(1)
    var onTopDrag: ((CGFloat) -> Void)?
    var onTopDragEnd: ((Int) -> Void)?
    func report(_ position: CGFloat) {
        let next = min(CGFloat(LibraryTab.allCases.count - 1), max(0, position))
        if abs(positions.value - next) > 0.0001 { positions.send(next) }
    }
}

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
        control.selectedSegmentIndex = LibraryTab.allCases.firstIndex(of: selection)!
    }
    func sizeThatFits(_ proposal: ProposedViewSize, uiView: TrackingLibraryTabs, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? uiView.intrinsicContentSize.width,
               height: proposal.height ?? uiView.intrinsicContentSize.height)
    }
    final class Coordinator: NSObject {
        var parent: NativeLibraryTabs
        init(_ parent: NativeLibraryTabs) { self.parent = parent }
        @objc func selectTab(_ control: UISegmentedControl) {
            guard LibraryTab.allCases.indices.contains(control.selectedSegmentIndex) else { return }
            parent.selection = LibraryTab.allCases[control.selectedSegmentIndex]
        }
    }
}

/// The same fractional position drives the page and the selected glass pill.
/// UIControl tracking also accepts a gesture that begins over an unselected tab.
final class TrackingLibraryTabs: UISegmentedControl {
    private let indicator = CALayer()
    private var glassIndicator: UIVisualEffectView?
    private var subscription: AnyCancellable?
    private let paging: LibraryPagingPosition
    private var position: CGFloat = 1
    var indicatorFrame: CGRect { indicator.frame }

    init(paging: LibraryPagingPosition) {
        self.paging = paging
        super.init(frame: .zero)
        for (index, tab) in LibraryTab.allCases.enumerated() {
            insertSegment(withTitle: tab.rawValue, at: index, animated: false)
        }
        accessibilityIdentifier = "libraryTabs"
        accessibilityLabel = "浏览类型"
        selectedSegmentTintColor = .clear
        let format = UIGraphicsImageRendererFormat(); format.opaque = false
        let clear = UIGraphicsImageRenderer(size: CGSize(width: 1, height: 1), format: format).image { _ in }
        let states: [UIControl.State] = [.normal, .selected, .highlighted, [.selected, .highlighted]]
        for state in states { setBackgroundImage(clear, for: state, barMetrics: .default) }
        for left in states { for right in states {
            setDividerImage(clear, forLeftSegmentState: left, rightSegmentState: right, barMetrics: .default)
        } }
        layer.insertSublayer(indicator, at: 0)
        #if compiler(>=6.2)
        if #available(iOS 26.0, *), !AppAppearance.forceTraditional {
            let effect = UIGlassEffect(style: .regular)
            effect.isInteractive = true
            let glass = UIVisualEffectView(effect: effect)
            glass.isUserInteractionEnabled = false
            glass.isAccessibilityElement = false
            glass.clipsToBounds = true
            glass.cornerConfiguration = .capsule()
            insertSubview(glass, at: 0)
            glassIndicator = glass
            indicator.isHidden = true
        }
        #endif
        layer.masksToBounds = true
        let longPress = UILongPressGestureRecognizer(target: self, action: #selector(trackLongPress(_:)))
        longPress.minimumPressDuration = 0.18
        longPress.allowableMovement = 18
        longPress.cancelsTouchesInView = true
        addGestureRecognizer(longPress)
        subscription = paging.positions.sink { [weak self] value in
            self?.position = value
            self?.drawIndicator()
        }
        updateAppearance()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    override var intrinsicContentSize: CGSize {
        CGSize(width: super.intrinsicContentSize.width,
               height: max(34, UIFont.preferredFont(forTextStyle: .subheadline).pointSize + 12))
    }
    override func layoutSubviews() { super.layoutSubviews(); drawIndicator() }
    override func traitCollectionDidChange(_ previous: UITraitCollection?) {
        super.traitCollectionDidChange(previous); updateAppearance()
    }
    private var traditional: Bool {
        if #available(iOS 26.0, *), !AppAppearance.forceTraditional { return false }
        return true
    }
    private func updateAppearance() {
        backgroundColor = traditional ? .tertiarySystemFill : .clear
        let size = UIFont.preferredFont(forTextStyle: .subheadline).pointSize
        setTitleTextAttributes([.foregroundColor: UIColor.label, .font: UIFont.systemFont(ofSize: size, weight: .medium)], for: .normal)
        setTitleTextAttributes([.foregroundColor: UIColor.label, .font: UIFont.systemFont(ofSize: size, weight: .semibold)], for: .selected)
        drawIndicator()
    }
    private func drawIndicator() {
        guard numberOfSegments > 0 else { return }
        let inset: CGFloat = 3
        let segment = max(0, bounds.width - inset * 2) / CGFloat(numberOfSegments)
        let height = max(0, bounds.height - inset * 2)
        CATransaction.begin(); CATransaction.setDisableActions(true)
        layer.cornerRadius = traditional ? 8 : bounds.height / 2
        indicator.frame = CGRect(x: inset + position * segment, y: inset, width: segment, height: height)
        indicator.cornerRadius = traditional ? 6 : height / 2
        indicator.backgroundColor = (traitCollection.userInterfaceStyle == .dark ? UIColor(white: 0.36, alpha: 1) : UIColor.white).cgColor
        indicator.shadowColor = UIColor.black.cgColor; indicator.shadowOpacity = traditional ? 0.12 : 0
        indicator.shadowRadius = 2; indicator.shadowOffset = CGSize(width: 0, height: 1)
        glassIndicator?.frame = indicator.frame
        CATransaction.commit()
    }
    private func touchPosition(_ point: CGPoint) -> CGFloat {
        let inset: CGFloat = 3
        let width = max(1, bounds.width - inset * 2) / CGFloat(numberOfSegments)
        return min(CGFloat(numberOfSegments - 1), max(0, (point.x - inset) / width - 0.5))
    }
    @objc private func trackLongPress(_ gesture: UILongPressGestureRecognizer) {
        let position = touchPosition(gesture.location(in: self))
        switch gesture.state {
        case .began, .changed:
            paging.onTopDrag?(position)
        case .ended:
            let target = min(numberOfSegments - 1, max(0, Int(position.rounded())))
            selectedSegmentIndex = target
            sendActions(for: .valueChanged)
            paging.onTopDragEnd?(target)
        case .cancelled, .failed:
            paging.onTopDragEnd?(selectedSegmentIndex)
        default: break
        }
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
        paging.onTopDrag = { [weak controller] in controller?.setInteractivePosition($0) }
        paging.onTopDragEnd = { [weak controller] in controller?.finishInteractivePosition($0, animated: animated) }
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
