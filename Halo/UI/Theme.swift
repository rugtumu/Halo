import SwiftUI

enum HaloPalette {
    /// Electric cyan highlight.
    static let ice = Color(red: 0.13, green: 0.83, blue: 0.93)
    /// Steel cobalt — the main accent (sliders, ticks, glow).
    static let cobalt = Color(red: 0.23, green: 0.51, blue: 0.96)
    /// Deep indigo shadow end.
    static let indigo = Color(red: 0.26, green: 0.22, blue: 0.79)

    /// The signature spectrum that runs around the ring; a hovered segment lights up with its slice.
    static let spectrum = AngularGradient(colors: [ice, cobalt, indigo, cobalt, ice], center: .center)
}

extension View {
    /// Liquid Glass in the glass style, a near-black slab in the solid style.
    @ViewBuilder
    func haloSurface<S: Shape>(_ shape: S, glass: Bool) -> some View {
        if glass {
            glassEffect(.regular, in: shape)
        } else {
            background(Color(white: 0.09).opacity(0.96), in: shape)
        }
    }
}
