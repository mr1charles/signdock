import SwiftUI

/// The shared look of DockBox's own screens.
enum DBTheme {
    static let accent = Color(red: 0.36, green: 0.36, blue: 0.95)
    static let gradient = LinearGradient(colors: [Color(red: 0.42, green: 0.36, blue: 0.98), Color(red: 0.16, green: 0.56, blue: 0.96)],
                                         startPoint: .topLeading, endPoint: .bottomTrailing)
}

/// A rounded tile with the app's initial. Colour comes from the name, so an app keeps its colour between launches.
struct DBAppTile: View {
    let name: String
    var size: CGFloat = 46

    private var hue: Double {
        Double(name.unicodeScalars.reduce(UInt32(7)) { ($0 &* 31) &+ $1.value } % 360) / 360
    }

    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.24, style: .continuous)
            .fill(LinearGradient(colors: [Color(hue: hue, saturation: 0.6, brightness: 0.92),
                                          Color(hue: hue, saturation: 0.75, brightness: 0.68)],
                                 startPoint: .topLeading, endPoint: .bottomTrailing))
            .frame(width: size, height: size)
            .overlay(Text(String(name.prefix(1)).uppercased())
                .font(.system(size: size * 0.44, weight: .bold, design: .rounded))
                .foregroundColor(.white))
            .accessibilityHidden(true)
    }
}

struct DBStatusChip: View {
    enum Tone { case good, warn, neutral }
    let icon: String, text: String, tone: Tone

    private var color: Color {
        switch tone {
        case .good: return .green
        case .warn: return .orange
        case .neutral: return .secondary
        }
    }

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: icon).font(.caption2.weight(.semibold)).foregroundColor(color)
            Text(text).font(.caption.weight(.medium)).lineLimit(1)
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
        .background(Capsule().fill(Color(.secondarySystemBackground)))
    }
}
