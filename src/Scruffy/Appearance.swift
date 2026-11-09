import SwiftUI

enum Appearance: String, CaseIterable, Identifiable {
    case system, light, dark
    var id: String { rawValue }
    var title: String { rawValue.capitalized }
    var colorScheme: ColorScheme? {
        switch self {
        case .system: nil
        case .light: .light
        case .dark: .dark
        }
    }
}

// MILL5 cyan and slate, with accessible text accents for each appearance.
struct ScruffyTheme {
    let scheme: ColorScheme
    private var dark: Bool { scheme == .dark }
    static let cyan = Color(red: 17 / 255, green: 155 / 255, blue: 197 / 255)
    var accent: Color { dark ? Self.cyan : Color(red: 7 / 255, green: 112 / 255, blue: 145 / 255) }
    var canvas: Color { dark ? Color(red: 18 / 255, green: 28 / 255, blue: 34 / 255) : Color(red: 246 / 255, green: 250 / 255, blue: 252 / 255) }
    var sidebar: Color { dark ? Color(red: 34 / 255, green: 43 / 255, blue: 48 / 255) : Color(red: 229 / 255, green: 241 / 255, blue: 247 / 255) }
    var card: Color { dark ? Color(red: 30 / 255, green: 47 / 255, blue: 57 / 255) : .white }
    var text: Color { dark ? Color(red: 237 / 255, green: 247 / 255, blue: 251 / 255) : Color(red: 34 / 255, green: 43 / 255, blue: 48 / 255) }
    var border: Color { Self.cyan.opacity(dark ? 0.22 : 0.17) }
}

struct BrandButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .semibold))
            .padding(.horizontal, 17).padding(.vertical, 11)
            .foregroundStyle(Color(red: 6 / 255, green: 23 / 255, blue: 30 / 255))
            .background(ScruffyTheme.cyan.opacity(isEnabled ? (configuration.isPressed ? 0.72 : 1) : 0.25), in: RoundedRectangle(cornerRadius: 9))
            .opacity(isEnabled ? 1 : 0.55)
    }
}

struct ResponsiveSheet<Content: View>: View {
    let width: CGFloat
    let idealHeight: CGFloat
    let windowSize: CGSize
    @ViewBuilder var content: () -> Content
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        ScrollView {
            content().padding(24).frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(width: min(width, max(320, windowSize.width - 60)),
               height: min(idealHeight, max(260, windowSize.height - 80)))
        .background(ScruffyTheme(scheme: colorScheme).canvas)
        .foregroundStyle(ScruffyTheme(scheme: colorScheme).text)
    }
}

struct PaginationControls: View {
    let count: Int
    @Binding var page: Int
    let pageSize: Int
    let noun: String
    private var pageCount: Int { max(1, (count + pageSize - 1) / pageSize) }
    private var currentPage: Int { min(page, pageCount - 1) }

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack { range; Spacer(minLength: 16); buttons }
            VStack(alignment: .leading, spacing: 8) {
                range
                HStack { Spacer(); buttons }
            }
        }
    }

    private var range: some View {
        Text("Showing \(currentPage * pageSize + 1)–\(min((currentPage + 1) * pageSize, count)) of \(count.formatted()) \(noun)")
            .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: true, vertical: false)
    }
    private var buttons: some View {
        HStack(spacing: 8) {
            Button("Previous") { page = currentPage - 1 }.disabled(currentPage == 0)
            Text("Page \(currentPage + 1) of \(pageCount)").font(.caption).monospacedDigit().fixedSize()
            Button("Next") { page = currentPage + 1 }.disabled(currentPage + 1 == pageCount)
        }.fixedSize()
    }
}
