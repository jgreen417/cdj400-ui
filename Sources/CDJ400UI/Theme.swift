import SwiftUI

extension StickMode {
    /// Green for a lean stick, orange for a Rekordbox export.
    var tint: Color {
        switch self {
        case .lean: .green
        case .full: .orange
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
}
