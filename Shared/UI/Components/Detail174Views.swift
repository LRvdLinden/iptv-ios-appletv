import SwiftUI

// Build 174: bouwstenen van de detailpagina op de telefoon (zie Shared/Player/Build174.swift, `Detail174`).

/// Regels die afbreken zoals tekst: onderdelen naast elkaar zolang ze passen, anders op een nieuwe regel. Een onderdeel
/// dat zelf breder is dan de regel krijgt de volle breedte (en breekt dan zelf af). Gecentreerd of links uitgelijnd.
struct WrapLayout174: Layout {
    var spacing: CGFloat = 12
    var lineSpacing: CGFloat = 8
    var centered = true

    private func sizes(_ subviews: Subviews, _ maxW: CGFloat) -> [CGSize] {
        subviews.map { v in
            let ideal = v.sizeThatFits(.unspecified)
            if maxW.isFinite, ideal.width > maxW { return v.sizeThatFits(ProposedViewSize(width: maxW, height: nil)) }
            return ideal
        }
    }

    private func lines(_ s: [CGSize], _ maxW: CGFloat) -> [[Int]] {
        var out: [[Int]] = []
        var line: [Int] = []
        var w: CGFloat = 0
        for (i, sz) in s.enumerated() {
            let need = line.isEmpty ? sz.width : w + spacing + sz.width
            if !line.isEmpty, maxW.isFinite, need > maxW {
                out.append(line); line = [i]; w = sz.width
            } else {
                line.append(i); w = need
            }
        }
        if !line.isEmpty { out.append(line) }
        return out
    }

    private func lineWidth(_ l: [Int], _ s: [CGSize]) -> CGFloat {
        l.reduce(0) { $0 + s[$1].width } + spacing * CGFloat(max(0, l.count - 1))
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxW = proposal.width ?? .infinity
        let s = sizes(subviews, maxW)
        let ls = lines(s, maxW)
        var w: CGFloat = 0, h: CGFloat = 0
        for (n, l) in ls.enumerated() {
            w = max(w, lineWidth(l, s))
            h += l.map { s[$0].height }.max() ?? 0
            if n > 0 { h += lineSpacing }
        }
        return CGSize(width: maxW.isFinite ? maxW : w, height: h)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let s = sizes(subviews, bounds.width)
        var y = bounds.minY
        for l in lines(s, bounds.width) {
            let lh = l.map { s[$0].height }.max() ?? 0
            var x = bounds.minX + (centered ? max(0, (bounds.width - lineWidth(l, s)) / 2) : 0)
            for i in l {
                subviews[i].place(at: CGPoint(x: x, y: y + lh / 2), anchor: .leading, proposal: ProposedViewSize(s[i]))
                x += s[i].width + spacing
            }
            y += lh + lineSpacing
        }
    }
}

/// Knop in de rij onder Afspelen: icoon met de tekst eronder, even breed als de andere knoppen.
struct DetailActionLabel174<Icon: View>: View {
    let title: String
    @ViewBuilder var icon: () -> Icon

    var body: some View {
        VStack(spacing: 6) {
            icon().frame(height: 26)
            Text(title)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Theme.secondary)
                .lineLimit(1).minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity, minHeight: 50)
        .contentShape(Rectangle())
    }
}

struct DetailActionIcon174: View {
    let name: String
    var tint: Color = .white
    var body: some View {
        Image(systemName: name).font(.system(size: 21, weight: .semibold)).foregroundStyle(tint)
    }
}
