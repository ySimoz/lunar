import SwiftUI

/// Monochrome Lunar Folio vector mark from `logo-redesign.md` (256x256 canonical grid).
/// Render with `.fill(..., style: FillStyle(eoFill: true))` so the crescent punches cleanly
/// out of the front folio card.
public struct LunarFolioMark: Shape {
    public init() {}

    public func path(in rect: CGRect) -> Path {
        let size = min(rect.width, rect.height)
        guard size > 0 else { return Path() }

        let scale = size / 256.0
        let dx = rect.midX - size / 2.0
        let dy = rect.midY - size / 2.0

        func pt(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            CGPoint(x: dx + x * scale, y: dy + y * scale)
        }

        var path = Path()

        // 1. Stepped rear card top bar: x 56..200, y 24..46, top radius 12, bottom radius 4
        let rearRect = CGRect(
            x: dx + 56 * scale,
            y: dy + 24 * scale,
            width: 144 * scale,
            height: 22 * scale
        )
        let rearRadii = RectangleCornerRadii(
            topLeading: 12 * scale,
            bottomLeading: 4 * scale,
            bottomTrailing: 4 * scale,
            topTrailing: 12 * scale
        )
        path.addRoundedRect(in: rearRect, cornerRadii: rearRadii, style: .continuous)

        // 2. Front card body: x 40..216, y 60..232, radius 24
        let frontRect = CGRect(
            x: dx + 40 * scale,
            y: dy + 60 * scale,
            width: 176 * scale,
            height: 172 * scale
        )
        path.addRoundedRect(
            in: frontRect,
            cornerSize: CGSize(width: 24 * scale, height: 24 * scale),
            style: .continuous
        )

        // 3. Crescent cutout: M 120.7 91.2 A 52 52 0 1 0 182.8 153.3 A 44 44 0 0 1 120.7 91.2 Z
        let pStart = CGPoint(x: 120.7, y: 91.2)
        let pEnd = CGPoint(x: 182.8, y: 153.3)
        let cOuter = CGPoint(x: 132.055, y: 141.945)
        let cInner = CGPoint(x: 153.725, y: 120.275)

        let outerStartAngle = Angle(radians: atan2(pStart.y - cOuter.y, pStart.x - cOuter.x))
        let outerEndAngle = Angle(radians: atan2(pEnd.y - cOuter.y, pEnd.x - cOuter.x))
        let innerStartAngle = Angle(radians: atan2(pEnd.y - cInner.y, pEnd.x - cInner.x))
        let innerEndAngle = Angle(radians: atan2(pStart.y - cInner.y, pStart.x - cInner.x))

        path.move(to: pt(pStart.x, pStart.y))
        path.addArc(
            center: pt(cOuter.x, cOuter.y),
            radius: 52 * scale,
            startAngle: outerStartAngle,
            endAngle: outerEndAngle,
            clockwise: true
        )
        path.addArc(
            center: pt(cInner.x, cInner.y),
            radius: 44 * scale,
            startAngle: innerStartAngle,
            endAngle: innerEndAngle,
            clockwise: false
        )
        path.closeSubpath()

        return path
    }
}

/// Convenience view rendering `LunarFolioMark` with even-odd fill.
public struct LunarFolioIcon: View {
    public var size: CGFloat
    public var color: Color

    public init(size: CGFloat = 20, color: Color = .primary) {
        self.size = size
        self.color = color
    }

    public var body: some View {
        LunarFolioMark()
            .fill(color, style: FillStyle(eoFill: true))
            .frame(width: size, height: size)
            .accessibilityLabel("Lunar")
    }
}
