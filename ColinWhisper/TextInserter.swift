import AppKit

/// Inserts text at the cursor of the frontmost app: clipboard + simulated ⌘V,
/// then restores the previous clipboard. Posting keys needs Accessibility.
enum TextInserter {
    static let restoreDelay: Duration = .milliseconds(300)

    static func paste(_ text: String) async {
        let pasteboard = NSPasteboard.general
        // Save every item with all its types, not just the string.
        let saved: [[(NSPasteboard.PasteboardType, Data)]] = pasteboard.pasteboardItems?.map { item in
            item.types.compactMap { type in item.data(forType: type).map { (type, $0) } }
        } ?? []

        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        // Convention understood by clipboard managers: don't record this entry.
        pasteboard.setData(Data(), forType: NSPasteboard.PasteboardType("org.nspasteboard.TransientType"))
        let ownChangeCount = pasteboard.changeCount

        postCommandV()
        try? await Task.sleep(for: restoreDelay)

        // Someone else wrote to the clipboard meanwhile — keep theirs.
        guard pasteboard.changeCount == ownChangeCount else { return }
        pasteboard.clearContents()
        pasteboard.writeObjects(saved.map { pairs in
            let item = NSPasteboardItem()
            for (type, data) in pairs { item.setData(data, forType: type) }
            return item
        })
    }

    static func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    private static func postCommandV() {
        let source = CGEventSource(stateID: .combinedSessionState)
        let vKey: CGKeyCode = 0x09  // kVK_ANSI_V: key position, same on QWERTZ
        for keyDown in [true, false] {
            let event = CGEvent(keyboardEventSource: source, virtualKey: vKey, keyDown: keyDown)
            event?.flags = .maskCommand
            event?.post(tap: .cghidEventTap)
        }
    }
}
