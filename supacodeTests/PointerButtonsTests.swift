import AppKit
import Testing

@testable import supacode

struct PointerButtonsTests {
  @Test func primaryAndSecondaryButtonsCountAsDragging() {
    #expect(NSEvent.isDraggingButtonPressed(in: 0b01))
    #expect(NSEvent.isDraggingButtonPressed(in: 0b10))
    #expect(NSEvent.isDraggingButtonPressed(in: 0b11))
  }

  @Test func noButtonsIsNotDragging() {
    #expect(!NSEvent.isDraggingButtonPressed(in: 0))
  }

  // The regression this guard exists for: a remapper or a seized device
  // re-emitted through a virtual HID device can strand an auxiliary button
  // down, and macOS never sends the missing release. Hover-focus has to keep
  // working through that, so nothing above bit 1 may count as a drag.
  @Test func latchedAuxiliaryButtonIsNotDragging() {
    // Button 3 (a trackball thumb button) stuck down on its own.
    #expect(!NSEvent.isDraggingButtonPressed(in: 0b1000))
    // Middle button, and every other auxiliary button, likewise.
    #expect(!NSEvent.isDraggingButtonPressed(in: 0b100))
    #expect(!NSEvent.isDraggingButtonPressed(in: 0b1111_1100))
  }

  // A real drag still has to be seen while an auxiliary button is stranded.
  @Test func latchedAuxiliaryButtonDoesNotMaskARealDrag() {
    #expect(NSEvent.isDraggingButtonPressed(in: 0b1001))
    #expect(NSEvent.isDraggingButtonPressed(in: 0b1010))
  }
}
