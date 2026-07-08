import UIKit

/// Walks the running app's `UIAccessibility` tree and turns it into `AXNode`s.
///
/// Mirrors how VoiceOver discovers elements: it prefers an object's
/// `accessibilityElements` when present, otherwise descends the view hierarchy,
/// capturing anything that is an accessibility element or carries a label.
private final class WeakRef {
    weak var object: NSObject?
    init(_ object: NSObject) { self.object = object }
}

@MainActor
public enum AccessibilityWalker {

    /// Maps element ids (from the last snapshot) to live objects, so DeviceHub
    /// can trigger actions (increment/decrement/custom action) on them.
    private static var registry: [String: WeakRef] = [:]

    public static func snapshot() -> AXSnapshot {
        registry.removeAll(keepingCapacity: true)
        let windows = activeWindows()
        let screen = UIScreen.main.bounds.size

        // Find every view flagged `accessibilityViewIsModal` (popover/sheet/
        // alert). Some are empty dimming/dismiss layers, so scope to the modal
        // branch that actually has content — that's what VoiceOver reads.
        var modals: [NSObject] = []
        for window in windows { collectModals(in: window, into: &modals) }

        var bestBranch: AXNode?
        var bestCount = 0
        for modal in modals {
            guard let node = buildNode(modal, depth: 0) else { continue }
            let count = elementCount(node)
            if count > bestCount { bestCount = count; bestBranch = node }
        }

        // Scope strictly to a content-bearing `accessibilityViewIsModal` branch —
        // exactly what VoiceOver traps focus on. If a sheet fails to mark its
        // content modal, we intentionally show everything, surfacing that as the
        // app-side accessibility bug it is (rather than papering over it).
        let roots: [AXNode]
        if let bestBranch, bestCount > 0 {
            roots = [bestBranch]
        } else {
            roots = windows.compactMap { buildNode($0, depth: 0) }
        }

        return AXSnapshot(
            appName: appName(),
            screenSize: [Double(screen.width), Double(screen.height)],
            roots: roots,
            modalPresented: !modals.isEmpty,
            modalLabel: bestBranch.flatMap(headerLabel)
        )
    }

    private static func headerLabel(in node: AXNode) -> String? {
        if node.traits.contains("header"), let label = node.label { return label }
        for child in node.children {
            if let label = headerLabel(in: child) { return label }
        }
        return nil
    }

    /// Performs the VoiceOver "escape" (scrub) action — dismisses the presented
    /// popover/sheet/alert, mirroring the two-finger scrub gesture.
    @discardableResult
    static func performEscape() -> Bool {
        guard let vc = topPresentedViewController(in: activeWindows()) else { return false }
        // Try the app's own escape handling up the responder chain first.
        var responder: UIResponder? = vc.view
        while let current = responder {
            if current.accessibilityPerformEscape() { return true }
            responder = current.next
        }
        // Fallback to the system's default escape behavior: dismiss the modal.
        vc.dismiss(animated: true)
        return true
    }

    /// Performs the VoiceOver "magic tap" (two-finger double-tap) — the app's
    /// primary action. Walks the responder chain the way VoiceOver dispatches it.
    @discardableResult
    static func performMagicTap() -> Bool {
        var responder = topResponder(in: activeWindows())
        while let current = responder {
            if current.accessibilityPerformMagicTap() { return true }
            responder = current.next
        }
        if let delegate = UIApplication.shared.delegate as? NSObject,
           delegate.accessibilityPerformMagicTap() {
            return true
        }
        return false
    }

    /// The deepest sensible responder to start a gesture traversal from: the
    /// presented modal's view if any, else the key window's root view.
    private static func topResponder(in windows: [UIWindow]) -> UIResponder? {
        if let presented = topPresentedViewController(in: windows) { return presented.view }
        let keyWindow = windows.first { $0.isKeyWindow } ?? windows.first
        return keyWindow?.rootViewController?.view ?? keyWindow
    }

    private static func topPresentedViewController(in windows: [UIWindow]) -> UIViewController? {
        for window in windows {
            guard let root = window.rootViewController else { continue }
            var top = root
            var presentedSomething = false
            while let presented = top.presentedViewController {
                top = presented
                presentedSomething = true
            }
            if presentedSomething { return top }
        }
        return nil
    }

    /// Collects every view marked `accessibilityViewIsModal`, descending fully
    /// (a modal may contain a nested modal, and dimming/content are siblings).
    private static func collectModals(in object: NSObject, into result: inout [NSObject]) {
        if let view = object as? UIView, view.isHidden || view.alpha < 0.01 { return }
        if object.accessibilityViewIsModal { result.append(object) }
        var children: [NSObject] = []
        if let elements = object.accessibilityElements as? [NSObject] {
            children = elements
        } else if let view = object as? UIView {
            children = view.subviews
        }
        for child in children { collectModals(in: child, into: &result) }
    }

    /// Number of accessibility elements in a built subtree.
    private static func elementCount(_ node: AXNode) -> Int {
        (node.isElement ? 1 : 0) + node.children.reduce(0) { $0 + elementCount($1) }
    }

    // MARK: Traversal

    private static func buildNode(_ object: NSObject, depth: Int) -> AXNode? {
        guard depth < 200 else { return nil }

        if let view = object as? UIView {
            if view.isHidden || view.alpha < 0.01 || view.accessibilityElementsHidden {
                return nil
            }
        }

        let isElement = object.isAccessibilityElement
        let label = nonEmpty(object.accessibilityLabel)
        let value = nonEmpty(object.accessibilityValue)
        let hint = nonEmpty(object.accessibilityHint)
        let identifier = nonEmpty((object as? UIAccessibilityIdentification)?.accessibilityIdentifier)
        let traits = decodeTraits(object.accessibilityTraits)

        // Children: explicit accessibility elements win; otherwise subviews.
        // Authored `accessibilityElements` already carry VoiceOver's read order;
        // subview order is z-order, so we sort those into reading order below.
        var childObjects: [NSObject] = []
        var fromExplicitOrder = false
        if let elements = object.accessibilityElements as? [NSObject], !elements.isEmpty {
            childObjects = elements
            fromExplicitOrder = true
        } else if !isElement, let view = object as? UIView {
            childObjects = view.subviews
        }
        var children = childObjects.compactMap { buildNode($0, depth: depth + 1) }
        if !fromExplicitOrder {
            children.sort(by: readingOrderBefore)
        }

        // Accessibility container: a grouping VoiceOver's rotor treats as a unit.
        // Only real containers count — a typed container or one that explicitly
        // groups its children. (A labeled wrapper around a single element, e.g. a
        // button with an icon child, is NOT a container.)
        let containerType = decodeContainerType(object.accessibilityContainerType)
        let isContainer = !children.isEmpty
            && (containerType != nil || object.shouldGroupAccessibilityChildren)

        let meaningful = isElement || label != nil || value != nil || !traits.isEmpty || isContainer
        if !meaningful {
            // A structural wrapper: drop it, but keep its content. Collapse a
            // single-child chain to reduce noise.
            if children.isEmpty { return nil }
            if children.count == 1 { return children[0] }
        }

        let frame = object.accessibilityFrame
        let id = "\(UInt(bitPattern: ObjectIdentifier(object).hashValue))"
        registry[id] = WeakRef(object)

        return AXNode(
            id: id,
            label: label,
            value: value,
            hint: hint,
            identifier: identifier,
            traits: traits,
            isElement: isElement,
            isContainer: isContainer,
            containerType: containerType,
            frame: [Double(frame.minX), Double(frame.minY), Double(frame.width), Double(frame.height)],
            voiceOver: compose(label: label, value: value, traits: traits, hint: hint),
            customActions: (object.accessibilityCustomActions ?? []).map(\.name),
            customContent: customContent(of: object),
            children: children
        )
    }

    private static func decodeContainerType(_ type: UIAccessibilityContainerType) -> String? {
        switch type {
        case .dataTable: return "table"
        case .list: return "list"
        case .landmark: return "landmark"
        case .semanticGroup: return "group"
        default: return nil
        }
    }

    private static func customContent(of object: NSObject) -> [String] {
        guard let provider = object as? AXCustomContentProvider else { return [] }
        return provider.accessibilityCustomContent.map { entry in
            let value = entry.value
            return value.isEmpty ? entry.label : "\(entry.label): \(value)"
        }
    }

    // MARK: Actions (triggered by DeviceHub)

    /// Activate an element by id — VoiceOver's single-tap. Returns success.
    @discardableResult
    static func activate(id: String) -> Bool {
        guard let object = registry[id]?.object else { return false }
        return object.accessibilityActivate()
    }

    /// Increment/decrement an adjustable element by id. Returns success.
    @discardableResult
    static func adjust(id: String, increment: Bool) -> Bool {
        guard let object = registry[id]?.object else { return false }
        if increment { object.accessibilityIncrement() } else { object.accessibilityDecrement() }
        return true
    }

    /// Invoke a named custom action on an element by id. Returns success.
    @discardableResult
    static func performCustomAction(id: String, name: String) -> Bool {
        guard let object = registry[id]?.object,
              let action = (object.accessibilityCustomActions ?? []).first(where: { $0.name == name })
        else { return false }
        if let handler = action.actionHandler { return handler(action) }
        if let target = action.target as? NSObject, target.responds(to: action.selector) {
            _ = target.perform(action.selector, with: action)
            return true
        }
        return false
    }

    // MARK: Helpers

    private static func activeWindows() -> [UIWindow] {
        let windows = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
            .filter { !$0.isHidden && $0.windowLevel == .normal }
        // Key window first so the visible screen leads the snapshot.
        return windows.sorted { ($0.isKeyWindow ? 0 : 1) < ($1.isKeyWindow ? 0 : 1) }
    }

    private static func appName() -> String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
            ?? Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String
            ?? "App"
    }

    /// VoiceOver-style reading order: top-to-bottom, then left-to-right, with a
    /// tolerance so items on the same visual row aren't split by a few points.
    private static func readingOrderBefore(_ a: AXNode, _ b: AXNode) -> Bool {
        let ay = a.frame.count > 1 ? a.frame[1] : 0
        let by = b.frame.count > 1 ? b.frame[1] : 0
        if abs(ay - by) > 10 { return ay < by }
        let ax = a.frame.first ?? 0
        let bx = b.frame.first ?? 0
        return ax < bx
    }

    private static func nonEmpty(_ string: String?) -> String? {
        guard let string, !string.isEmpty else { return nil }
        return string
    }

    private static func compose(label: String?, value: String?, traits: [String], hint: String?) -> String {
        let roleWord = traits.first { ["button", "link", "header", "image", "adjustable"].contains($0) }
        let parts = [label, value, roleWord, hint].compactMap { $0 }
        return parts.isEmpty ? "(no description)" : parts.joined(separator: ", ")
    }

    private static func decodeTraits(_ traits: UIAccessibilityTraits) -> [String] {
        let table: [(UIAccessibilityTraits, String)] = [
            (.button, "button"), (.link, "link"), (.header, "header"),
            (.searchField, "searchField"), (.image, "image"), (.selected, "selected"),
            (.staticText, "staticText"), (.summaryElement, "summaryElement"),
            (.notEnabled, "notEnabled"), (.updatesFrequently, "updatesFrequently"),
            (.startsMediaSession, "startsMediaSession"), (.adjustable, "adjustable"),
            (.allowsDirectInteraction, "allowsDirectInteraction"),
            (.causesPageTurn, "causesPageTurn"), (.keyboardKey, "keyboardKey"),
            (.playsSound, "playsSound"), (.tabBar, "tabBar"),
        ]
        return table.filter { traits.contains($0.0) }.map(\.1)
    }
}
