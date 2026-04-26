import AppKit

protocol NoteHeaderViewDelegate: AnyObject {
    func headerDidRequestClose()
    func headerDidRequestColorChange(to color: NoteColor)
    func headerDidToggleCollapse()
}

final class NoteHeaderView: NSView {
    weak var delegate: NoteHeaderViewDelegate?

    private let closeButton = NSButton()
    private let colorButton = NSButton()
    static let height: CGFloat = 26

    override var isFlipped: Bool { true }

    init(color: NoteColor) {
        super.init(frame: .zero)
        wantsLayer = true
        applyColor(color)

        closeButton.translatesAutoresizingMaskIntoConstraints = false
        closeButton.bezelStyle = .inline
        closeButton.isBordered = false
        closeButton.title = "×"
        closeButton.font = NSFont.systemFont(ofSize: 14, weight: .medium)
        closeButton.contentTintColor = NSColor.black.withAlphaComponent(0.55)
        closeButton.target = self
        closeButton.action = #selector(closeClicked)
        addSubview(closeButton)

        colorButton.translatesAutoresizingMaskIntoConstraints = false
        colorButton.bezelStyle = .inline
        colorButton.isBordered = false
        colorButton.title = "●"
        colorButton.font = NSFont.systemFont(ofSize: 12)
        colorButton.contentTintColor = NSColor.black.withAlphaComponent(0.45)
        colorButton.target = self
        colorButton.action = #selector(colorClicked)
        addSubview(colorButton)

        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: NoteHeaderView.height),
            closeButton.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            closeButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            closeButton.widthAnchor.constraint(equalToConstant: 18),
            closeButton.heightAnchor.constraint(equalToConstant: 18),
            colorButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            colorButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            colorButton.widthAnchor.constraint(equalToConstant: 18),
            colorButton.heightAnchor.constraint(equalToConstant: 18)
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    func applyColor(_ color: NoteColor) {
        layer?.backgroundColor = NSColor(hex: color.headerHex)?.cgColor
    }

    override func mouseDown(with event: NSEvent) {
        // Forward drag to window. Detect double-click to collapse.
        if event.clickCount == 2 {
            delegate?.headerDidToggleCollapse()
            return
        }
        window?.performDrag(with: event)
    }

    @objc private func closeClicked() {
        delegate?.headerDidRequestClose()
    }

    @objc private func colorClicked() {
        let menu = NSMenu()
        for color in NoteColor.allCases {
            let item = NSMenuItem(title: color.displayName, action: #selector(pickColor(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = color.rawValue
            let swatch = NSImage(size: NSSize(width: 14, height: 14), flipped: false) { rect in
                let path = NSBezierPath(roundedRect: rect.insetBy(dx: 0.5, dy: 0.5), xRadius: 3, yRadius: 3)
                NSColor(hex: color.bodyHex)?.setFill()
                path.fill()
                NSColor.black.withAlphaComponent(0.18).setStroke()
                path.lineWidth = 0.5
                path.stroke()
                return true
            }
            item.image = swatch
            menu.addItem(item)
        }
        menu.popUp(positioning: nil, at: NSPoint(x: colorButton.frame.minX, y: colorButton.frame.maxY), in: self)
    }

    @objc private func pickColor(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let color = NoteColor(rawValue: raw) else { return }
        delegate?.headerDidRequestColorChange(to: color)
    }
}

extension NSColor {
    convenience init?(hex: String) {
        var s = hex
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6, let val = UInt32(s, radix: 16) else { return nil }
        let r = CGFloat((val >> 16) & 0xFF) / 255.0
        let g = CGFloat((val >> 8) & 0xFF) / 255.0
        let b = CGFloat(val & 0xFF) / 255.0
        self.init(srgbRed: r, green: g, blue: b, alpha: 1.0)
    }
}
