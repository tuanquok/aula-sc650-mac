import SwiftUI

enum Theme {
    static let bg = Color(red: 0.05, green: 0.05, blue: 0.08)
    static let panel = Color(red: 0.09, green: 0.09, blue: 0.14)
    static let stroke = Color.white.opacity(0.08)
    static let accent = Color(red: 1.0, green: 0.18, blue: 0.35)
    static let accent2 = Color(red: 0.0, green: 0.85, blue: 1.0)
    static let text = Color.white.opacity(0.92)
    static let muted = Color.white.opacity(0.5)
}

struct Panel<Content: View>: View {
    let title: String
    @ViewBuilder var content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(title.uppercased())
                .font(.system(size: 11, weight: .heavy, design: .monospaced))
                .tracking(2).foregroundStyle(Theme.accent2)
            content
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 14).fill(Theme.panel))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(Theme.stroke))
    }
}

struct GamingButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .heavy, design: .rounded)).tracking(1.5)
            .padding(.horizontal, 22).padding(.vertical, 10)
            .background(
                LinearGradient(colors: [Theme.accent, Theme.accent.opacity(0.65)], startPoint: .leading, endPoint: .trailing),
                in: RoundedRectangle(cornerRadius: 10))
            .shadow(color: Theme.accent.opacity(configuration.isPressed ? 0.2 : 0.55), radius: 12)
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
    }
}
