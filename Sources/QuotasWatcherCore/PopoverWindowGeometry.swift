import CoreGraphics
import Foundation

/// Pure geometry policy used to keep an already-open popover window fully
/// inside the active screen's visible frame when the fullscreen auto-hidden
/// menu bar hides or reappears. Contains no AppKit dependencies so the policy
/// is deterministically testable.
public enum PopoverWindowGeometry {
    /// Small inset from the screen's visible frame so the corrected popover
    /// never touches the exact screen edge.
    public static let defaultMargin: CGFloat = 4

    /// Returns `frame` unchanged when it already lies fully inside the visible
    /// frame (inset by `margin`); otherwise returns a same-size frame clamped
    /// into the inset visible frame. Oversized frames are pinned to the
    /// minimum edges of the inset visible frame so the result is
    /// deterministic and the window stays as reachable as possible.
    public static func correctedFrame(_ frame: CGRect, visibleFrame: CGRect, margin: CGFloat = defaultMargin) -> CGRect {
        let allowed = visibleFrame.insetBy(dx: margin, dy: margin)
        guard !allowed.isNull, allowed.width > 0, allowed.height > 0 else {
            return frame
        }

        var origin = frame.origin

        if frame.width <= allowed.width {
            if frame.minX < allowed.minX {
                origin.x = allowed.minX
            } else if frame.maxX > allowed.maxX {
                origin.x = allowed.maxX - frame.width
            }
        } else {
            origin.x = allowed.minX
        }

        if frame.height <= allowed.height {
            if frame.minY < allowed.minY {
                origin.y = allowed.minY
            } else if frame.maxY > allowed.maxY {
                origin.y = allowed.maxY - frame.height
            }
        } else {
            origin.y = allowed.minY
        }

        return CGRect(origin: origin, size: frame.size)
    }
}
