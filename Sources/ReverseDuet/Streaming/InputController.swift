import CoreGraphics
import Foundation

/// Turns pointer / keyboard messages from the browser into macOS input events
/// on the display being streamed. Requires the Accessibility permission.
final class InputController {
    private let displayID: CGDirectDisplayID
    private var pressedButtons = Set<Int>()
    private var lastClick: (time: TimeInterval, point: CGPoint, button: Int, count: Int)?

    init(displayID: CGDirectDisplayID) {
        self.displayID = displayID
    }

    func handle(_ message: [String: Any]) {
        guard let type = message["t"] as? String else { return }
        switch type {
        case "mouse": handleMouse(message)
        case "wheel": handleWheel(message)
        case "key": handleKey(message)
        case "text": handleText(message)
        default: break
        }
    }

    /// Release anything still held when the browser disconnects.
    func releaseAll() {
        for button in pressedButtons {
            post(mouse: upType(for: button), at: currentLocation(), button: button, clickCount: 1)
        }
        pressedButtons.removeAll()
    }

    // MARK: Mouse

    private func point(from message: [String: Any]) -> CGPoint {
        let bounds = CGDisplayBounds(displayID)
        let x = min(max(message["x"] as? Double ?? 0, 0), 1)
        let y = min(max(message["y"] as? Double ?? 0, 0), 1)
        return CGPoint(x: bounds.minX + x * (bounds.width - 1), y: bounds.minY + y * (bounds.height - 1))
    }

    private func handleMouse(_ message: [String: Any]) {
        let action = message["a"] as? String ?? "move"
        let button = message["b"] as? Int ?? 0
        let location = point(from: message)

        switch action {
        case "down":
            let now = ProcessInfo.processInfo.systemUptime
            var count = 1
            if let last = lastClick, last.button == button, now - last.time < 0.4,
               hypot(last.point.x - location.x, last.point.y - location.y) < 6 {
                count = min(last.count + 1, 3)
            }
            lastClick = (now, location, button, count)
            pressedButtons.insert(button)
            post(mouse: downType(for: button), at: location, button: button, clickCount: count)
        case "up":
            pressedButtons.remove(button)
            post(mouse: upType(for: button), at: location, button: button, clickCount: lastClick?.count ?? 1)
        default:
            if pressedButtons.contains(0) {
                post(mouse: .leftMouseDragged, at: location, button: 0, clickCount: 1)
            } else if pressedButtons.contains(2) {
                post(mouse: .rightMouseDragged, at: location, button: 2, clickCount: 1)
            } else if let other = pressedButtons.first {
                post(mouse: .otherMouseDragged, at: location, button: other, clickCount: 1)
            } else {
                post(mouse: .mouseMoved, at: location, button: 0, clickCount: 0)
            }
        }
    }

    private func handleWheel(_ message: [String: Any]) {
        let dx = message["dx"] as? Double ?? 0
        let dy = message["dy"] as? Double ?? 0
        // Browser: positive deltaY scrolls content down. macOS: positive wheel1 scrolls up.
        guard let event = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2,
                                  wheel1: Int32(clamping: Int(-dy.rounded())),
                                  wheel2: Int32(clamping: Int(-dx.rounded())),
                                  wheel3: 0) else { return }
        if message["x"] != nil { event.location = point(from: message) }
        event.post(tap: .cghidEventTap)
    }

    private func currentLocation() -> CGPoint {
        CGEvent(source: nil)?.location ?? .zero
    }

    private func downType(for button: Int) -> CGEventType {
        switch button {
        case 0: return .leftMouseDown
        case 2: return .rightMouseDown
        default: return .otherMouseDown
        }
    }

    private func upType(for button: Int) -> CGEventType {
        switch button {
        case 0: return .leftMouseUp
        case 2: return .rightMouseUp
        default: return .otherMouseUp
        }
    }

    private func post(mouse type: CGEventType, at location: CGPoint, button: Int, clickCount: Int) {
        // Browser buttons: 0 left, 1 middle, 2 right. CGMouseButton: 0 left, 1 right, 2 center.
        let cgButton: CGMouseButton = button == 0 ? .left : (button == 2 ? .right : .center)
        guard let event = CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: location, mouseButton: cgButton) else { return }
        if clickCount > 0 {
            event.setIntegerValueField(.mouseEventClickState, value: Int64(clickCount))
        }
        event.post(tap: .cghidEventTap)
    }

    // MARK: Keyboard

    private func handleKey(_ message: [String: Any]) {
        guard let code = message["code"] as? String, let keyCode = Self.keyCodes[code] else { return }
        let isDown = (message["a"] as? String) != "up"
        guard let event = CGEvent(keyboardEventSource: nil, virtualKey: keyCode, keyDown: isDown) else { return }
        var flags: CGEventFlags = []
        if message["shift"] as? Bool == true { flags.insert(.maskShift) }
        if message["ctrl"] as? Bool == true { flags.insert(.maskControl) }
        if message["alt"] as? Bool == true { flags.insert(.maskAlternate) }
        if message["meta"] as? Bool == true { flags.insert(.maskCommand) }
        event.flags = flags
        event.post(tap: .cghidEventTap)
    }

    /// Text typed on a touch keyboard (where key codes aren't reliable).
    private func handleText(_ message: [String: Any]) {
        guard let text = message["s"] as? String, !text.isEmpty else { return }
        for character in text {
            let units = Array(String(character).utf16)
            for isDown in [true, false] {
                guard let event = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: isDown) else { continue }
                units.withUnsafeBufferPointer { buffer in
                    event.keyboardSetUnicodeString(stringLength: buffer.count, unicodeString: buffer.baseAddress)
                }
                event.post(tap: .cghidEventTap)
            }
        }
    }

    /// `KeyboardEvent.code` → macOS virtual key code (ANSI layout).
    static let keyCodes: [String: CGKeyCode] = [
        "KeyA": 0x00, "KeyS": 0x01, "KeyD": 0x02, "KeyF": 0x03, "KeyH": 0x04, "KeyG": 0x05,
        "KeyZ": 0x06, "KeyX": 0x07, "KeyC": 0x08, "KeyV": 0x09, "IntlBackslash": 0x0A, "KeyB": 0x0B,
        "KeyQ": 0x0C, "KeyW": 0x0D, "KeyE": 0x0E, "KeyR": 0x0F, "KeyY": 0x10, "KeyT": 0x11,
        "Digit1": 0x12, "Digit2": 0x13, "Digit3": 0x14, "Digit4": 0x15, "Digit6": 0x16, "Digit5": 0x17,
        "Equal": 0x18, "Digit9": 0x19, "Digit7": 0x1A, "Minus": 0x1B, "Digit8": 0x1C, "Digit0": 0x1D,
        "BracketRight": 0x1E, "KeyO": 0x1F, "KeyU": 0x20, "BracketLeft": 0x21, "KeyI": 0x22, "KeyP": 0x23,
        "Enter": 0x24, "KeyL": 0x25, "KeyJ": 0x26, "Quote": 0x27, "KeyK": 0x28, "Semicolon": 0x29,
        "Backslash": 0x2A, "Comma": 0x2B, "Slash": 0x2C, "KeyN": 0x2D, "KeyM": 0x2E, "Period": 0x2F,
        "Tab": 0x30, "Space": 0x31, "Backquote": 0x32, "Backspace": 0x33, "Escape": 0x35,
        "MetaRight": 0x36, "MetaLeft": 0x37, "ShiftLeft": 0x38, "CapsLock": 0x39, "AltLeft": 0x3A,
        "ControlLeft": 0x3B, "ShiftRight": 0x3C, "AltRight": 0x3D, "ControlRight": 0x3E,
        "NumpadDecimal": 0x41, "NumpadMultiply": 0x43, "NumpadAdd": 0x45, "NumLock": 0x47,
        "NumpadDivide": 0x4B, "NumpadEnter": 0x4C, "NumpadSubtract": 0x4E, "NumpadEqual": 0x51,
        "Numpad0": 0x52, "Numpad1": 0x53, "Numpad2": 0x54, "Numpad3": 0x55, "Numpad4": 0x56,
        "Numpad5": 0x57, "Numpad6": 0x58, "Numpad7": 0x59, "Numpad8": 0x5B, "Numpad9": 0x5C,
        "F1": 0x7A, "F2": 0x78, "F3": 0x63, "F4": 0x76, "F5": 0x60, "F6": 0x61, "F7": 0x62,
        "F8": 0x64, "F9": 0x65, "F10": 0x6D, "F11": 0x67, "F12": 0x6F,
        "Home": 0x73, "PageUp": 0x74, "Delete": 0x75, "End": 0x77, "PageDown": 0x79,
        "ArrowLeft": 0x7B, "ArrowRight": 0x7C, "ArrowDown": 0x7D, "ArrowUp": 0x7E,
    ]
}
