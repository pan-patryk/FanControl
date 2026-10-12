import SwiftUI
import Charts
import AppKit

// The XY plot inside the curve editor: knots as draggable marks, the operating-point
// dot, and the grid the whole thing is drawn against.
//
// It is `Equatable` so that per-second sensor noise which does not move the dot a
// visible step produces zero re-plots — the re-render is driven by the inputs
// (knots, dragging id, smoothed dot), not by the view model's publish rate.
// `PlotRectKey` publishes the plot's frame in the editor's own coordinate space so
// gestures hit-tested outside SwiftUI can convert a click back into data values.

// MARK: - The plot

struct CurveLineChart: View, Equatable {
    var points: [CurvePoint]
    var draggingID: UUID?
    var dot: (x: Double, y: Double)?
    var xDomain: ClosedRange<Double>
    var onDrag: (_ data: CGPoint, _ moved: Bool) -> Void
    var onEnd: (_ pos: CGPoint, _ moved: Bool) -> Void

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.points == rhs.points
            && lhs.draggingID == rhs.draggingID
            && lhs.dot?.x == rhs.dot?.x
            && lhs.dot?.y == rhs.dot?.y
            && lhs.xDomain == rhs.xDomain
    }

    var body: some View {
        Chart {
            ForEach(points) { point in
                LineMark(
                    x: .value("Temp", point.x),
                    y: .value("Fan", point.y)
                )
                .foregroundStyle(DS.fan)
                .lineStyle(StrokeStyle(lineWidth: 2))
            }
            ForEach(points) { point in
                PointMark(
                    x: .value("Temp", point.x),
                    y: .value("Fan", point.y)
                )
                .symbolSize(point.id == draggingID ? 170 : 80)
                .foregroundStyle(DS.fan)
            }
            if let dot {
                PointMark(
                    x: .value("Temp", dot.x),
                    y: .value("Fan", dot.y)
                )
                .symbolSize(150)
                .foregroundStyle(.orange)
            }
        }
        .chartXScale(domain: xDomain)
        .chartYScale(domain: 0...100)
        .chartXAxisLabel("Temperature °C", alignment: .trailing)
        .chartYAxisLabel("Fan %")
        .chartOverlay { proxy in
            GeometryReader { geo in
                let plot = geo[proxy.plotAreaFrame]
                Rectangle()
                    .fill(Color.clear)
                    .contentShape(Rectangle())
                    .frame(width: plot.width, height: plot.height)
                    .offset(x: plot.minX, y: plot.minY)
                    // Report the plot in this window's global (top-left origin)
                    // space. A preference is used because writing @State during body
                    // evaluation is illegal; the right-click monitor converts its
                    // event into the same space (preference = safe, async delivery).
                    .preference(key: PlotRectKey.self, value: {
                        let global = geo.frame(in: .global)
                        return CGRect(
                            x: global.minX + plot.minX,
                            y: global.minY + plot.minY,
                            width: plot.width,
                            height: plot.height
                        )
                    }())
                    .gesture(
                        // minimumDistance 0 → a plain tap is also a drag event,
                        // which the end-handler disambiguates via travel distance.
                        DragGesture(minimumDistance: 0)
                            .onChanged { drag in
                                let pos = CGPoint(
                                    x: drag.location.x - plot.minX,
                                    y: drag.location.y - plot.minY
                                )
                                let moved = hypot(drag.translation.width, drag.translation.height) > 3
                                onDrag(dataValues(pos, proxy: proxy), moved)
                            }
                            .onEnded { drag in
                                let pos = CGPoint(
                                    x: drag.location.x - plot.minX,
                                    y: drag.location.y - plot.minY
                                )
                                let moved = hypot(drag.translation.width, drag.translation.height) > 3
                                onEnd(dataValues(pos, proxy: proxy), moved)
                            }
                    )
            }
        }
    }

    /// Plot-area coordinates → chart data values, clamped to the domains.
    private func dataValues(_ pos: CGPoint, proxy: ChartProxy) -> CGPoint {
        let x = proxy.value(atX: pos.x, as: Double.self).flatMap {
            min(max($0, xDomain.lowerBound), xDomain.upperBound)
        } ?? 0
        let y = proxy.value(atY: pos.y, as: Double.self).flatMap {
            min(max($0, 0), 100)
        } ?? 0
        return CGPoint(x: x, y: y)
    }
}

/// Carries the plot area's rect, in the hosting window's `.global` (top-left
/// origin) coordinate space, out of the chart overlay.
struct PlotRectKey: PreferenceKey {
    static var defaultValue: CGRect = .zero
    static func reduce(value: inout CGRect, nextValue: () -> CGRect) {
        let next = nextValue()
        if next != .zero { value = next }
    }
}
