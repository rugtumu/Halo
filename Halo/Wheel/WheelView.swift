import SwiftUI

@MainActor
final class WheelModel: ObservableObject {
    @Published var kind: WheelKind = .conversion
    @Published var items: [WheelItem] = []
    @Published var hovered: Int?
    @Published var fired: Int?
    @Published var visible = false
    @Published var thumbnail: NSImage?
    @Published var caption = ""
    @Published var style: WheelStyle = .glass
}

struct WheelView: View {
    @ObservedObject var model: WheelModel

    var body: some View {
        let geometry = WheelGeometry(count: model.items.count)
        let glass = model.style == .glass
        ZStack {
            Color.clear
                .frame(width: (geometry.outer + 9) * 2, height: (geometry.outer + 9) * 2)
                .haloSurface(Circle(), glass: glass)
                .overlay(Circle().strokeBorder(HaloPalette.spectrum, lineWidth: 1.2).opacity(0.6))
                .shadow(color: .black.opacity(0.35), radius: 24, y: 10)

            ForEach(Array(model.items.enumerated()), id: \.element.id) { index, item in
                SegmentView(item: item, index: index, geometry: geometry,
                            hovered: model.hovered == index, fired: model.fired == index, glass: glass)
            }

            hub(geometry, glass: glass)
        }
        .frame(width: WheelGeometry.size, height: WheelGeometry.size)
        .scaleEffect(model.visible ? 1 : 0.8)
        .opacity(model.visible ? 1 : 0)
        .environment(\.colorScheme, .dark)
    }

    private var hubCaption: String {
        guard let index = model.hovered, model.items.indices.contains(index) else { return model.caption }
        let item = model.items[index]
        return model.kind == .conversion ? "To \(item.title)" : item.title
    }

    private func hub(_ geometry: WheelGeometry, glass: Bool) -> some View {
        let diameter = (geometry.inner - 10) * 2
        return ZStack {
            Circle().fill(.black.opacity(0.25))
            if let thumbnail = model.thumbnail {
                Image(nsImage: thumbnail)
                    .resizable()
                    .scaledToFill()
                    .frame(width: diameter, height: diameter)
                    .clipShape(Circle())
            }
            Circle().strokeBorder(.white.opacity(0.18), lineWidth: 1)
        }
        .frame(width: diameter, height: diameter)
        .overlay(alignment: .bottom) {
            Text(hubCaption)
                .font(.system(size: 10.5, weight: .semibold, design: .rounded))
                .foregroundStyle(.white)
                .lineLimit(1)
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .haloSurface(Capsule(), glass: glass)
                .fixedSize()
                .offset(y: 12)
                .contentTransition(.opacity)
        }
    }
}

private struct SegmentView: View {
    let item: WheelItem
    let index: Int
    let geometry: WheelGeometry
    let hovered: Bool
    let fired: Bool
    let glass: Bool

    var body: some View {
        let shape = SectorShape(geometry: geometry, index: index)
        let center = CGPoint(x: WheelGeometry.size / 2, y: WheelGeometry.size / 2)
        let labelPoint = geometry.point(radius: (geometry.outer + geometry.inner) / 2 + 3,
                                        angle: geometry.angle(of: index), center: center)
        ZStack {
            shape.fill(hovered ? AnyShapeStyle(HaloPalette.spectrum)
                               : AnyShapeStyle(Color.white.opacity(glass ? 0.10 : 0.07)))
            shape.stroke(LinearGradient(colors: [.white.opacity(hovered ? 0.55 : 0.22), .white.opacity(0.04)],
                                        startPoint: .top, endPoint: .bottom),
                         lineWidth: 0.8)
            label.position(labelPoint)
        }
        .frame(width: WheelGeometry.size, height: WheelGeometry.size)
        .shadow(color: HaloPalette.cobalt.opacity(0.55), radius: hovered ? 16 : 0)
        .scaleEffect(fired ? 0.97 : hovered ? 1.045 : 1)
        .brightness(fired ? 0.15 : 0)
    }

    @ViewBuilder
    private var label: some View {
        if let symbol = item.symbol {
            VStack(spacing: 5) {
                Image(systemName: symbol).font(.system(size: 18, weight: .semibold))
                Text(item.title.uppercased()).font(.system(size: 9.5, weight: .bold)).tracking(0.9)
            }
            .foregroundStyle(.white.opacity(hovered ? 1 : 0.86))
        } else {
            Text(item.title)
                .font(.system(size: 15, weight: .heavy, design: .rounded))
                .tracking(0.6)
                .foregroundStyle(.white.opacity(hovered ? 1 : 0.86))
        }
    }
}

extension WheelModel {
    /// A static, always-visible model for the Settings preview.
    static func preview(_ items: [WheelItem], kind: WheelKind, style: WheelStyle) -> WheelModel {
        let model = WheelModel()
        model.kind = kind
        model.items = items
        model.style = style
        model.visible = true
        model.caption = "Preview"
        return model
    }
}
