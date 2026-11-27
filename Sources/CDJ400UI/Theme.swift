import SwiftUI

extension StickMode {
    /// Green for a stick ready for the CDJ-400, blue for one in Rekordbox mode.
    /// Orange is kept for things that need attention.
    var tint: Color {
        switch self {
        case .lean: .green
        case .full: .blue
        }
    }

    var symbol: String {
        switch self {
        case .lean: "checkmark"
        case .full: "smallcircle.filled.circle"
        }
    }
}

extension Color {
    /// Green below 80% full, orange below 85%, red beyond.
    static func capacity(_ fraction: Double) -> Color {
        if fraction < 0.8 { return .green }
        if fraction < 0.85 { return .orange }
        return .red
    }

    /// Playlist colours, shared by the storage bar and the playlist list so
    /// each playlist is the same colour in both.
    static let playlistPalette: [Color] = [.indigo, .pink, .cyan, .orange, .purple, .mint, .yellow, .teal]

    static func playlist(_ index: Int) -> Color { playlistPalette[index % playlistPalette.count] }

    /// The empty part of a capacity bar.
    static let freeSpace = Color.primary.opacity(0.13)
}

/// A rounded group of rows with hairlines between them, like a grouped Form
/// section but laid out by the caller.
struct Card<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) { content }
            .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.06)))
    }
}

/// A hairline between two rows of a Card.
struct CardDivider: View {
    var body: some View {
        Rectangle().fill(Color.primary.opacity(0.07)).frame(height: 1).padding(.leading, 14)
    }
}

/// A section title above a Card, with optional trailing content.
struct SectionHeader<Trailing: View>: View {
    let title: String
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title).font(.system(size: 15, weight: .semibold))
            Spacer()
            trailing
        }
        .padding(.horizontal, 4)
    }
}

extension SectionHeader where Trailing == EmptyView {
    init(_ title: String) {
        self.title = title
        trailing = EmptyView()
    }
}

/// A title with a smaller secondary line under it, for card rows.
struct RowLabel: View {
    let title: String
    var detail: String?
    var detailColor: Color = .secondary

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).fontWeight(.medium)
            if let detail {
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(detailColor)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// How a stick's space is used: one coloured segment per playlist (or the
/// Rekordbox export), an optional striped segment for a copy in progress, then
/// free space.
struct StorageBar: View {
    struct Segment: Identifiable {
        let id: String
        let label: String
        let bytes: Int64
        let color: Color
        var arriving = false
    }

    let segments: [Segment]
    let totalBytes: Int64
    var height: CGFloat = 16

    @State private var grown = false

    var body: some View {
        GeometryReader { geo in
            let gaps = CGFloat(segments.count) * 2
            let usable = max(geo.size.width - gaps, 0)
            let total = Double(max(totalBytes, 1))
            HStack(spacing: 2) {
                ForEach(segments) { segment in
                    let width = max(3, usable * CGFloat(Double(segment.bytes) / total))
                    Group {
                        if segment.arriving {
                            Stripes(color: segment.color)
                        } else {
                            Rectangle().fill(segment.color)
                        }
                    }
                    .frame(width: grown ? width : 0)
                    .help("\(segment.label): \(segment.bytes.fileSize)")
                }
                Rectangle().fill(Color.freeSpace)
            }
        }
        .frame(height: height)
        .clipShape(RoundedRectangle(cornerRadius: height / 3, style: .continuous))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(segments.map { "\($0.label) \($0.bytes.fileSize)" }.joined(separator: ", "))
        .onAppear {
            withAnimation(.easeOut(duration: 0.6)) { grown = true }
        }
    }
}

/// Diagonal stripes: space a copy in progress is about to take.
private struct Stripes: View {
    let color: Color

    var body: some View {
        Canvas { context, size in
            context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(color.opacity(0.45)))
            var x = -size.height
            while x < size.width {
                var line = Path()
                line.move(to: CGPoint(x: x, y: size.height))
                line.addLine(to: CGPoint(x: x + size.height, y: 0))
                context.stroke(line, with: .color(color), lineWidth: 4)
                x += 10
            }
        }
    }
}

extension Date {
    /// "27 Nov, 7:55 pm", with the year only when it isn't this year's.
    var shortStamp: String {
        let sameYear = Calendar.current.isDate(self, equalTo: .now, toGranularity: .year)
        return formatted(sameYear
            ? .dateTime.day().month(.abbreviated).hour().minute()
            : .dateTime.day().month(.abbreviated).year().hour().minute())
    }
}

/// A small capacity bar for sidebar rows.
struct MiniCapacityBar: View {
    let fraction: Double
    let tint: Color

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.freeSpace)
                Capsule().fill(tint).frame(width: geo.size.width * min(max(fraction, 0), 1))
            }
        }
        .frame(height: 4)
        .accessibilityHidden(true)
    }
}
