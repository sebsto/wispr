# Issue #46 — Crash on macOS 26.3 when clicking "Install Command Line Tool"

## Problem

`showCLIInstallDialog()` in `MenuBarController.swift` (line 605) crashes with
`EXC_BREAKPOINT` (SIGTRAP) on macOS 26.3. The crash occurs during the SwiftUI
constraint update cycle when the hosting view triggers a layout pass before the
window is fully configured.

## Root Cause

The method creates an empty `NSWindow()`, then assigns `contentViewController`
and calls `setContentSize(hostingController.view.fittingSize)` as separate steps.
On macOS 26.3, this two-step pattern causes the hosting view to trigger a
constraint update on an incompletely configured window.

```swift
// Current (broken on macOS 26.3)
let window = NSWindow()                           // empty window
// ... configure style ...
window.contentViewController = hostingController   // assign after
window.setContentSize(hostingController.view.fittingSize)  // triggers crash
```

The other two window-opening methods in the same file (`openSettings()` line 515,
`openModelManagement()` line 550) already use the safe pattern:

```swift
// Safe pattern
let window = NSWindow(contentViewController: hostingController)
```

## Fix

- [ ] Move `CLIInstallDialogView` creation before the window
- [ ] Change `onDismiss` closure from `[weak self, weak window]` to `[weak self]`, closing via `self?.cliInstallWindow`
- [ ] Replace `NSWindow()` + separate `contentViewController` assignment with `NSWindow(contentViewController:)`
- [ ] Remove explicit `setContentSize(hostingController.view.fittingSize)` — `NSWindow(contentViewController:)` auto-sizes
- [ ] Verify the project builds

## Resulting Code

```swift
func showCLIInstallDialog() {
    NSApp.activate()

    if let window = cliInstallWindow, window.isVisible {
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
        return
    }

    cliInstallWindow = nil

    let dialogView = CLIInstallDialogView(
        appBundlePath: Bundle.main.bundlePath,
        symlinkPath: cliSymlinkPath,
        onDismiss: { [weak self] in
            self?.cliInstallWindow?.close()
            self?.cliInstallWindow = nil
        }
    )
    let hostingController = NSHostingController(rootView: dialogView)
    let window = NSWindow(contentViewController: hostingController)
    window.title = "Install Command Line Tool"
    window.styleMask = [.titled, .closable]
    window.isReleasedWhenClosed = false
    window.center()
    window.makeKeyAndOrderFront(nil)
    window.orderFrontRegardless()
    cliInstallWindow = window
}
```

## Why This Can't Be Reproduced Locally

The crash only manifests on macOS 26.3 (25D2128). Earlier macOS versions tolerate
the two-step window init pattern. The fix aligns with the safe pattern already
used elsewhere in the same file, so it's backwards-compatible.
