import AppKit

/// Asks which unpinned apps to keep before a profile switch quits them.
enum UnpinnedAppsAlert {

    /// Shows a checklist of `apps`. Returns the apps the user checked to pin
    /// to the outgoing profile, or nil if the user cancelled the switch.
    static func run(apps: [NSRunningApplication],
                    outgoingName: String,
                    incomingName: String) -> [NSRunningApplication]? {
        let alert = NSAlert()
        alert.messageText = "Close apps that are not pinned?"
        alert.informativeText = "Switching to \u{201C}\(incomingName)\u{201D} quits these apps. "
            + "Check an app to pin it to \u{201C}\(outgoingName)\u{201D} instead."
        alert.addButton(withTitle: "Switch")
        alert.addButton(withTitle: "Cancel")

        let checkboxes = apps.map(checkbox(for:))
        let stack = NSStackView(views: checkboxes)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        stack.frame.size = stack.fittingSize
        alert.accessoryView = stack

        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        return zip(apps, checkboxes).filter { $0.1.state == .on }.map(\.0)
    }

    private static func checkbox(for app: NSRunningApplication) -> NSButton {
        let name = app.localizedName ?? app.bundleIdentifier ?? "Unknown app"
        let button = NSButton(checkboxWithTitle: "Pin \(name)", target: nil, action: nil)
        if let icon = app.icon?.copy() as? NSImage {
            icon.size = NSSize(width: 16, height: 16)
            button.image = icon
            button.imagePosition = .imageLeading
        }
        return button
    }
}
