import SwiftUI

/// Angles are measured from 12 o'clock, clockwise, in a y-down coordinate space.
struct WheelGeometry {
    static let size: CGFloat = 400

    let count: Int
    let outer: CGFloat = 170
    let inner: CGFloat = 66
    let gap: CGFloat = 6
    /// Drops slightly outside the ring still count, so fast flicks don't miss.
    let outerTolerance: CGFloat = 14

    var span: Double { 2 * .pi / Double(max(count, 1)) }

    func angle(of index: Int) -> Double { Double(index) * span }

    func point(radius r: CGFloat, angle: Double, center c: CGPoint) -> CGPoint {
        CGPoint(x: c.x + r * CGFloat(sin(angle)), y: c.y - r * CGFloat(cos(angle)))
    }

    /// Segment under a point relative to the wheel center, or nil for the hub (cancel) and outside.
    func index(at p: CGPoint) -> Int? {
        guard count > 0 else { return nil }
        let distance = hypot(p.x, p.y)
        guard distance >= inner, distance <= outer + outerTolerance else { return nil }
        var theta = atan2(Double(p.x), Double(-p.y))
        if theta < 0 { theta += 2 * .pi }
        let shifted = (theta + span / 2).truncatingRemainder(dividingBy: 2 * .pi)
        return Int(shifted / span) % count
    }
}

/// One annular wedge with rounded corners and a constant-width gap to its neighbours.
struct SectorShape: Shape {
    let geometry: WheelGeometry
    let index: Int

    func path(in rect: CGRect) -> Path {
        let g = geometry
        let c = CGPoint(x: rect.midX, y: rect.midY)
        let ro = g.outer, ri = g.inner
        let outerCorner: CGFloat = 16, innerCorner: CGFloat = 9
        let mid = g.angle(of: index), half = g.span / 2
        let offset = { (r: CGFloat) in asin(Double(g.gap / 2 / r)) }
        let o0 = mid - half + offset(ro), o1 = mid + half - offset(ro)
        let i0 = mid - half + offset(ri), i1 = mid + half - offset(ri)
        let dOuter = Double(outerCorner * 1.2 / ro), dInner = Double(innerCorner * 1.2 / ri)
        let pt = { (r: CGFloat, a: Double) in g.point(radius: r, angle: a, center: c) }
        let steps = 28

        let a = pt(ri, i0), b = pt(ro, o0)
        let start = CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2)

        var path = Path()
        path.move(to: start)
        path.addArc(tangent1End: pt(ro, o0), tangent2End: pt(ro, o0 + dOuter), radius: outerCorner)
        for k in 0...steps {
            let t = Double(k) / Double(steps)
            path.addLine(to: pt(ro, (o0 + dOuter) + ((o1 - dOuter) - (o0 + dOuter)) * t))
        }
        path.addArc(tangent1End: pt(ro, o1), tangent2End: pt(ri, i1), radius: outerCorner)
        path.addArc(tangent1End: pt(ri, i1), tangent2End: pt(ri, i1 - dInner), radius: innerCorner)
        for k in 0...steps {
            let t = Double(k) / Double(steps)
            path.addLine(to: pt(ri, (i1 - dInner) - ((i1 - dInner) - (i0 + dInner)) * t))
        }
        path.addArc(tangent1End: pt(ri, i0), tangent2End: start, radius: innerCorner)
        path.closeSubpath()
        return path
    }
}
