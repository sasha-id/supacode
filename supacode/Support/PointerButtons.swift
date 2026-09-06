import AppKit

extension NSEvent {
  /// The buttons a drag can be held with: primary (bit 0) and secondary (bit 1).
  private static let draggingButtonMask = 0b11

  /// Whether a button that could be dragging is currently held.
  ///
  /// Deliberately narrower than `pressedMouseButtons != 0`, which asks whether
  /// *any* of the 32 buttons is down. That reading is not safe on a real desk: a
  /// remapper on a `CGEventTap`, or a device seized and re-emitted through a
  /// virtual HID device, can drop the release half of an auxiliary button's
  /// press. macOS never reconciles that — nothing re-sends the missing release —
  /// so the button reads as held for the rest of the login session. Anything
  /// gated on "no button at all is down" then stays switched off indefinitely,
  /// with nothing to connect it back to a thumb button on a trackball.
  ///
  /// Only the primary and secondary buttons can be extending a selection or
  /// holding a context menu open, so they are the only ones worth blocking on.
  static var isDraggingButtonPressed: Bool {
    isDraggingButtonPressed(in: pressedMouseButtons)
  }

  /// Pure seam over the live `pressedMouseButtons` read, so the mask is testable
  /// without a mouse attached.
  static func isDraggingButtonPressed(in pressedButtons: Int) -> Bool {
    pressedButtons & draggingButtonMask != 0
  }
}
