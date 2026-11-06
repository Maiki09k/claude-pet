import CoreGraphics

/// Exact opaque-window coverage, including several windows covering different pieces.
/// A sampling grid can miss a visible sliver and pause a sprite that is still on screen.
enum WindowCoverage {
    static func covers(_ area: CGRect, with windows: [CGRect]) -> Bool {
        guard !area.isEmpty else { return true }
        var uncovered = [area]
        for window in windows {
            uncovered = uncovered.flatMap { remaining -> [CGRect] in
                let overlap = remaining.intersection(window)
                guard !overlap.isNull, !overlap.isEmpty else { return [remaining] }
                return [
                    CGRect(x: remaining.minX, y: remaining.minY,
                           width: overlap.minX - remaining.minX, height: remaining.height),
                    CGRect(x: overlap.maxX, y: remaining.minY,
                           width: remaining.maxX - overlap.maxX, height: remaining.height),
                    CGRect(x: overlap.minX, y: remaining.minY,
                           width: overlap.width, height: overlap.minY - remaining.minY),
                    CGRect(x: overlap.minX, y: overlap.maxY,
                           width: overlap.width, height: remaining.maxY - overlap.maxY)
                ].filter { $0.width > 0 && $0.height > 0 }
            }
            if uncovered.isEmpty { return true }
        }
        return false
    }
}
