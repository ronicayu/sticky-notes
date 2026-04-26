import AppKit

final class NoteWindowController: NSWindowController, NSWindowDelegate, NSTextViewDelegate, NSLayoutManagerDelegate, NoteHeaderViewDelegate {
    private var note: Note
    private let store: NoteStore
    private let onClosed: (UUID) -> Void

    private let header: NoteHeaderView
    private let textView: NSTextView
    private let textStorage: NSTextStorage
    private let layoutManager: NSLayoutManager
    private let scrollView: NSScrollView
    private let backgroundView: HoverTrackingView

    private var saveWorkItem: DispatchWorkItem?
    private var preCollapseHeight: CGFloat
    private var isHovering = false

    private static let blurAlpha: CGFloat = 0.65
    private static let activeAlpha: CGFloat = 1.0

    init(note: Note, store: NoteStore, onClosed: @escaping (UUID) -> Void) {
        self.note = note
        self.store = store
        self.onClosed = onClosed
        self.preCollapseHeight = CGFloat(note.height)

        // If the note was archived while collapsed, the saved `note.height` is
        // still the expanded height (we never overwrite it during collapse).
        // Open the window at the matching display height so a collapsed note
        // shows as a slim header rather than a tall empty box.
        let displayHeight: CGFloat = note.collapsed ? NoteHeaderView.height : CGFloat(note.height)
        let frame = NSRect(x: note.positionX, y: note.positionY, width: note.width, height: displayHeight)
        let window = NoteWindow(contentRect: frame)

        backgroundView = HoverTrackingView(frame: .zero)
        backgroundView.wantsLayer = true
        backgroundView.layer?.backgroundColor = NSColor(hex: note.color.bodyHex)?.cgColor
        backgroundView.layer?.cornerRadius = 10
        backgroundView.layer?.masksToBounds = true

        header = NoteHeaderView(color: note.color)
        header.translatesAutoresizingMaskIntoConstraints = false

        // Build a TextKit 1 stack manually so we can hook NSLayoutManagerDelegate
        // and substitute glyphs for hidden markdown markers.
        textStorage = NSTextStorage(string: note.content)
        layoutManager = NSLayoutManager()
        textStorage.addLayoutManager(layoutManager)
        let container = NSTextContainer(size: NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude))
        container.widthTracksTextView = true
        container.heightTracksTextView = false
        layoutManager.addTextContainer(container)

        textView = NSTextView(frame: .zero, textContainer: container)
        textView.isRichText = false
        textView.allowsUndo = true
        textView.backgroundColor = .clear
        textView.drawsBackground = false
        textView.textContainerInset = NSSize(width: 6, height: 8)
        textView.typingAttributes = [
            .font: NSFont.systemFont(ofSize: MarkdownStyler.baseFontSize),
            .foregroundColor: MarkdownStyler.bodyTextColor
        ]
        textView.insertionPointColor = MarkdownStyler.bodyTextColor
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)

        scrollView = NSScrollView()
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false
        scrollView.scrollerStyle = .overlay
        scrollView.autohidesScrollers = true
        scrollView.documentView = textView

        // Hairline separator between header and content for subtle definition.
        let separator = NSView()
        separator.translatesAutoresizingMaskIntoConstraints = false
        separator.wantsLayer = true
        separator.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.08).cgColor

        backgroundView.addSubview(header)
        backgroundView.addSubview(separator)
        backgroundView.addSubview(scrollView)

        NSLayoutConstraint.activate([
            header.leadingAnchor.constraint(equalTo: backgroundView.leadingAnchor),
            header.trailingAnchor.constraint(equalTo: backgroundView.trailingAnchor),
            header.topAnchor.constraint(equalTo: backgroundView.topAnchor),
            separator.leadingAnchor.constraint(equalTo: backgroundView.leadingAnchor),
            separator.trailingAnchor.constraint(equalTo: backgroundView.trailingAnchor),
            separator.topAnchor.constraint(equalTo: header.bottomAnchor),
            separator.heightAnchor.constraint(equalToConstant: 1),
            scrollView.leadingAnchor.constraint(equalTo: backgroundView.leadingAnchor, constant: 4),
            scrollView.trailingAnchor.constraint(equalTo: backgroundView.trailingAnchor, constant: -4),
            scrollView.topAnchor.constraint(equalTo: separator.bottomAnchor),
            scrollView.bottomAnchor.constraint(equalTo: backgroundView.bottomAnchor, constant: -6)
        ])

        window.contentView = backgroundView
        if note.collapsed {
            scrollView.isHidden = true
        }

        super.init(window: window)
        window.delegate = self
        window.alphaValue = NoteWindowController.blurAlpha
        window.initialFirstResponder = textView
        textView.delegate = self
        header.delegate = self
        layoutManager.delegate = self
        backgroundView.onHoverChange = { [weak self] hovering in
            self?.isHovering = hovering
            self?.updateAlpha()
        }
        MarkdownStyler.apply(to: textView)
        refreshMarkerVisibility()
    }

    func focusEditor() {
        guard let window = window else { return }
        window.makeFirstResponder(textView)
        // place cursor at end of existing content
        let end = NSRange(location: textView.string.utf16.count, length: 0)
        textView.setSelectedRange(end)
    }

    required init?(coder: NSCoder) { fatalError() }

    // MARK: - NSWindowDelegate

    func windowDidMove(_ notification: Notification) {
        guard let frame = window?.frame else { return }
        note.positionX = Double(frame.origin.x)
        note.positionY = Double(frame.origin.y)
        scheduleSave()
    }

    func windowDidBecomeKey(_ notification: Notification) {
        updateAlpha()
    }

    func windowDidResignKey(_ notification: Notification) {
        updateAlpha()
    }

    private func updateAlpha() {
        guard let window = window else { return }
        let isKey = window.isKeyWindow
        let target: CGFloat = (isKey || isHovering) ? NoteWindowController.activeAlpha : NoteWindowController.blurAlpha
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.18
            window.animator().alphaValue = target
        }
    }

    func windowDidResize(_ notification: Notification) {
        guard let frame = window?.frame else { return }
        note.width = Double(frame.size.width)
        if !note.collapsed {
            note.height = Double(frame.size.height)
            preCollapseHeight = frame.size.height
        }
        scheduleSave()
    }

    // MARK: - NSTextViewDelegate

    func textDidChange(_ notification: Notification) {
        note.content = textView.string
        MarkdownStyler.apply(to: textView)
        refreshMarkerVisibility()
        scheduleSave()
    }

    func textViewDidChangeSelection(_ notification: Notification) {
        refreshMarkerVisibility()
    }

    private func refreshMarkerVisibility() {
        let selection = textView.selectedRange()
        MarkdownStyler.updateMarkerVisibility(in: textStorage, selection: selection)
        let full = NSRange(location: 0, length: textStorage.length)
        layoutManager.invalidateGlyphs(forCharacterRange: full, changeInLength: 0, actualCharacterRange: nil)
        layoutManager.ensureLayout(for: layoutManager.textContainers[0])
    }

    // MARK: - NSLayoutManagerDelegate

    func layoutManager(
        _ layoutManager: NSLayoutManager,
        shouldGenerateGlyphs glyphs: UnsafePointer<CGGlyph>,
        properties props: UnsafePointer<NSLayoutManager.GlyphProperty>,
        characterIndexes charIndexes: UnsafePointer<Int>,
        font aFont: NSFont,
        forGlyphRange glyphRange: NSRange
    ) -> Int {
        guard let storage = layoutManager.textStorage else { return 0 }

        var modified = false
        var newProps = [NSLayoutManager.GlyphProperty](repeating: .null, count: glyphRange.length)
        for i in 0..<glyphRange.length {
            var prop = props[i]
            let charIdx = charIndexes[i]
            if charIdx < storage.length {
                let attrs = storage.attributes(at: charIdx, effectiveRange: nil)
                if attrs[.mdHidden] != nil {
                    prop = .null
                    modified = true
                }
            }
            newProps[i] = prop
        }

        guard modified else { return 0 }

        newProps.withUnsafeBufferPointer { buffer in
            layoutManager.setGlyphs(
                glyphs,
                properties: buffer.baseAddress!,
                characterIndexes: charIndexes,
                font: aFont,
                forGlyphRange: glyphRange
            )
        }
        return glyphRange.length
    }

    // MARK: - NoteHeaderViewDelegate

    func headerDidRequestClose() {
        let isEmpty = note.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        if isEmpty {
            store.discardActive(note)
        } else {
            store.archive(note)
        }
        window?.close()
        onClosed(note.id)
    }

    func headerDidRequestColorChange(to color: NoteColor) {
        note.color = color
        backgroundView.layer?.backgroundColor = NSColor(hex: color.bodyHex)?.cgColor
        header.applyColor(color)
        scheduleSave()
    }

    func headerDidToggleCollapse() {
        guard let window = window else { return }
        note.collapsed.toggle()
        var frame = window.frame
        if note.collapsed {
            preCollapseHeight = frame.size.height
            scrollView.isHidden = true
            let newHeight = NoteHeaderView.height
            frame.origin.y += frame.size.height - newHeight
            frame.size.height = newHeight
            window.setFrame(frame, display: true, animate: true)
        } else {
            scrollView.isHidden = false
            let newHeight = preCollapseHeight
            frame.origin.y -= newHeight - frame.size.height
            frame.size.height = newHeight
            window.setFrame(frame, display: true, animate: true)
            note.height = Double(newHeight)
        }
        scheduleSave()
    }

    // MARK: - Persistence

    private func scheduleSave() {
        saveWorkItem?.cancel()
        let item = DispatchWorkItem { [weak self] in
            guard let self = self else { return }
            self.note.updatedAt = Date()
            self.store.save(self.note)
        }
        saveWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: item)
    }
}
