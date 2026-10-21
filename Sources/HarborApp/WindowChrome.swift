import AppKit
import SwiftUI

/// Keep real macOS window controls. Attached sheets retain their native Cancel
/// action; only independent windows can minimize or enter fullscreen.
struct NativeWindowChrome: NSViewRepresentable {
    var integratedTitlebar = false
    func makeNSView(context: Context) -> WindowChromeView {
        let view = WindowChromeView()
        view.integratedTitlebar = integratedTitlebar
        return view
    }
    func updateNSView(_ nsView: WindowChromeView, context: Context) {
        nsView.integratedTitlebar = integratedTitlebar
        nsView.restoreControls()
    }
}

final class WindowChromeView: NSView {
    var integratedTitlebar = false
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        restoreControls()
        DispatchQueue.main.async { [weak self] in self?.restoreControls() }
    }

    func restoreControls() {
        guard let window, window.sheetParent == nil else { return }
        window.styleMask.formUnion([.titled, .closable, .miniaturizable, .resizable])
        if integratedTitlebar {
            window.styleMask.insert(.fullSizeContentView)
            window.titleVisibility = .hidden
            window.titlebarAppearsTransparent = true
            window.titlebarSeparatorStyle = .none
        } else {
            window.titleVisibility = .visible
            window.titlebarAppearsTransparent = false
        }
        window.isMovable = true
        for kind in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            guard let button = window.standardWindowButton(kind) else { continue }
            button.isHidden = false
            button.isEnabled = true
            button.alphaValue = 1
        }
    }
}

private struct SheetCloseModifier: ViewModifier {
    @Environment(\.dismiss) private var dismiss
    var disabled: Bool

    func body(content: Content) -> some View {
        content.overlay(alignment: .topTrailing) {
            Button { dismiss() } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 26, height: 26)
                    .background(.quaternary, in: Circle())
            }
            .buttonStyle(.plain)
            .disabled(disabled)
            .help("Close dialog")
            .accessibilityLabel("Close dialog")
            .padding(18)
        }
    }
}

extension View {
    func sheetCloseButton(disabled: Bool = false) -> some View {
        modifier(SheetCloseModifier(disabled: disabled))
    }
}
