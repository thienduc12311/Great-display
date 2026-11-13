import SwiftUI
import AppKit
import GDCore

// Building blocks for the Settings window.
//
// Visual language: a soft grey canvas with raised white cards, small-caps
// section labels, a page header with chips and actions on every page, and
// pill tabs that split long pages into short ones. Explanations sit under a
// row's title, or behind an ⓘ button when "Show explanations" is off.

enum SettingsStyle {
    static let contentBackground = Color(nsColor: .windowBackgroundColor)
    static let cardFill = Color(nsColor: .controlBackgroundColor)
    static let cardStroke = Color.primary.opacity(0.07)
    static let cardRadius: CGFloat = 12
    static let rowInset: CGFloat = 16
    static let pageWidth: CGFloat = 780
}

/// NSVisualEffectView wrapper for the sidebar material.
struct VisualEffectBackground: NSViewRepresentable {
    var material: NSVisualEffectView.Material
    var blending: NSVisualEffectView.BlendingMode = .behindWindow

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = blending
        view.state = .followsWindowActiveState
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {
        view.material = material
        view.blendingMode = blending
    }
}

// MARK: - Cards and rows

/// Raised, rounded group of rows.
struct SettingsCard<Content: View>: View {
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            content()
        }
        .padding(.vertical, 4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: SettingsStyle.cardRadius, style: .continuous)
                .fill(SettingsStyle.cardFill)
                .shadow(color: .black.opacity(0.05), radius: 2, y: 1)
        )
        .overlay(
            RoundedRectangle(cornerRadius: SettingsStyle.cardRadius, style: .continuous)
                .strokeBorder(SettingsStyle.cardStroke)
        )
    }
}

/// Small-caps label above a card, with an optional symbol.
struct SettingsSectionTitle: View {
    var title: String
    var symbol: String? = nil

    var body: some View {
        HStack(spacing: 6) {
            if let symbol {
                Image(systemName: symbol).font(.system(size: 10.5, weight: .semibold))
            }
            Text(title.uppercased())
                .font(.system(size: 11, weight: .semibold))
                .tracking(0.6)
        }
        .foregroundStyle(.secondary)
        .padding(.leading, 6)
        .padding(.top, 16)
        .padding(.bottom, 2)
    }
}

/// Divider between rows, inset to the row content.
struct SettingsRowDivider: View {
    var body: some View {
        Divider().padding(.leading, SettingsStyle.rowInset).opacity(0.7)
    }
}

/// ⓘ button that shows an explanation in a popover.
struct HelpButton: View {
    let text: String
    @State private var shown = false

    var body: some View {
        Button { shown.toggle() } label: {
            Image(systemName: "info.circle")
                .font(.system(size: 12))
                .foregroundStyle(.tertiary)
        }
        .buttonStyle(.plain)
        .help(text)
        .popover(isPresented: $shown, arrowEdge: .bottom) {
            Text(text)
                .font(.system(size: 12))
                .fixedSize(horizontal: false, vertical: true)
                .frame(width: 260, alignment: .leading)
                .padding(12)
        }
    }
}

/// Title (+ explanation) on the left, any control on the right.
struct SettingsRow<Trailing: View>: View {
    var title: String
    var help: String? = nil
    @ViewBuilder var trailing: () -> Trailing
    @ObservedObject private var store = SettingsStore.shared

    var body: some View {
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 5) {
                    Text(title).font(.system(size: 13))
                    if let help, !store.state.general.showHelp { HelpButton(text: help) }
                }
                if let help, store.state.general.showHelp {
                    Text(help)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 12)
            trailing()
        }
        .padding(.horizontal, SettingsStyle.rowInset)
        .padding(.vertical, 10)
    }
}

extension SettingsRow where Trailing == Text {
    /// Read-only value row.
    init(title: String, value: String, help: String? = nil) {
        self.title = title
        self.help = help
        self.trailing = {
            Text(value)
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
        }
    }
}

/// Row with a trailing switch.
struct SettingsToggleRow: View {
    var title: String
    var help: String? = nil
    @Binding var isOn: Bool
    var enabled: Bool = true

    var body: some View {
        SettingsRow(title: title, help: help) {
            Toggle("", isOn: $isOn)
                .toggleStyle(.switch)
                .labelsHidden()
                .disabled(!enabled)
        }
        .opacity(enabled ? 1 : 0.55)
    }
}

/// Row with a slider and its value.
struct SettingsSliderRow: View {
    var title: String
    var help: String? = nil
    @Binding var value: Double
    var range: ClosedRange<Double> = 0...1
    var text: String
    var tint: Color? = nil

    var body: some View {
        SettingsRow(title: title, help: help) {
            HStack(spacing: 10) {
                if let tint {
                    Circle().fill(tint).frame(width: 8, height: 8)
                }
                Slider(value: $value, in: range)
                    .frame(width: 230)
                Text(text)
                    .font(.system(size: 12).monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(width: 56, alignment: .trailing)
            }
        }
    }
}

/// Right-aligned row of buttons at the bottom of a card.
struct SettingsButtonRow<Content: View>: View {
    @ViewBuilder var content: () -> Content
    var body: some View {
        HStack(spacing: 8) {
            Spacer()
            content()
        }
        .padding(.horizontal, SettingsStyle.rowInset)
        .padding(.vertical, 8)
    }
}

/// Card header with a tinted icon tile.
struct SettingsIconHeader<Trailing: View>: View {
    var symbol: String
    var title: String
    var tint: Color = .accentColor
    var subtitle: String? = nil
    @ViewBuilder var trailing: () -> Trailing

    var body: some View {
        HStack(spacing: 12) {
            IconTile(symbol: symbol, tint: tint)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.system(size: 13, weight: .semibold))
                if let subtitle {
                    Text(subtitle).font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }
            Spacer()
            trailing()
        }
        .padding(.horizontal, SettingsStyle.rowInset)
        .padding(.vertical, 10)
    }
}

extension SettingsIconHeader where Trailing == EmptyView {
    init(symbol: String, title: String, tint: Color = .accentColor, subtitle: String? = nil) {
        self.init(symbol: symbol, title: title, tint: tint, subtitle: subtitle, trailing: { EmptyView() })
    }
}

struct IconTile: View {
    var symbol: String
    var tint: Color = .accentColor
    var size: CGFloat = 30

    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.26, style: .continuous)
            .fill(LinearGradient(colors: [tint.opacity(0.8), tint], startPoint: .top, endPoint: .bottom))
            .frame(width: size, height: size)
            .overlay(
                Image(systemName: symbol)
                    .font(.system(size: size * 0.48, weight: .semibold))
                    .foregroundStyle(.white)
            )
    }
}

/// Explanatory paragraph inside a card (hidden when explanations are off).
struct SettingsHelpText: View {
    var text: String
    @ObservedObject private var store = SettingsStore.shared

    var body: some View {
        if store.state.general.showHelp {
            Text(text)
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, SettingsStyle.rowInset)
                .padding(.vertical, 6)
        }
    }
}

// MARK: - Page structure

/// Scrolling page body, centred and width-limited.
struct DetailScroll<Content: View>: View {
    @ViewBuilder var content: () -> Content

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                content()
            }
            .padding(.horizontal, 32)
            .padding(.top, 40)
            .padding(.bottom, 32)
            .frame(maxWidth: SettingsStyle.pageWidth, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
    }
}

/// Large header at the top of every page: icon, title, subtitle, chips, actions.
struct PageHeader<Icon: View, Actions: View>: View {
    var title: String
    var subtitle: String? = nil
    var chips: [StatusChip] = []
    @ViewBuilder var icon: () -> Icon
    @ViewBuilder var actions: () -> Actions

    var body: some View {
        HStack(alignment: .center, spacing: 16) {
            icon()
            VStack(alignment: .leading, spacing: 5) {
                Text(title)
                    .font(.system(size: 22, weight: .bold))
                    .lineLimit(1)
                if let subtitle {
                    Text(subtitle).font(.system(size: 12)).foregroundStyle(.secondary)
                }
                if !chips.isEmpty {
                    HStack(spacing: 6) { ForEach(chips) { $0 } }
                        .padding(.top, 1)
                }
            }
            Spacer(minLength: 12)
            HStack(spacing: 8) { actions() }
        }
        .padding(.bottom, 10)
    }
}

extension PageHeader where Actions == EmptyView {
    init(title: String, subtitle: String? = nil, chips: [StatusChip] = [], @ViewBuilder icon: @escaping () -> Icon) {
        self.init(title: title, subtitle: subtitle, chips: chips, icon: icon, actions: { EmptyView() })
    }
}

/// Capsule label such as "Main", "HDR" or "DDC".
struct StatusChip: View, Identifiable {
    var text: String
    var symbol: String? = nil
    var tint: Color = .secondary
    var id: String { text }

    var body: some View {
        HStack(spacing: 4) {
            if let symbol { Image(systemName: symbol).font(.system(size: 9, weight: .bold)) }
            Text(text).font(.system(size: 10.5, weight: .semibold))
        }
        .foregroundStyle(tint)
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background(Capsule().fill(tint.opacity(0.13)))
    }
}

/// Pill-shaped tabs that split a long page into short ones.
struct PillTabs<Value: Hashable>: View {
    struct Item: Identifiable {
        let value: Value
        let title: String
        let symbol: String
        var id: String { title }
    }

    let items: [Item]
    @Binding var selection: Value
    @Namespace private var namespace

    var body: some View {
        HStack(spacing: 2) {
            ForEach(items) { item in
                let selected = item.value == selection
                Button {
                    withAnimation(.snappy(duration: 0.22)) { selection = item.value }
                } label: {
                    Label(item.title, systemImage: item.symbol)
                        .font(.system(size: 12.5, weight: selected ? .semibold : .regular))
                        .foregroundStyle(selected ? Color.primary : Color.secondary)
                        .padding(.horizontal, 14)
                        .frame(height: 28)
                        .background {
                            if selected {
                                Capsule()
                                    .fill(SettingsStyle.cardFill)
                                    .shadow(color: .black.opacity(0.12), radius: 1.5, y: 1)
                                    .matchedGeometryEffect(id: "pill", in: namespace)
                            }
                        }
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(3)
        .background(Capsule().fill(Color.primary.opacity(0.06)))
    }
}

/// Coloured banner for things that need the user's attention.
struct Callout<Actions: View>: View {
    var symbol: String
    var tint: Color
    var title: String
    var message: String? = nil
    @ViewBuilder var actions: () -> Actions

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 20)
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.system(size: 13, weight: .semibold))
                if let message {
                    Text(message)
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 8)
            HStack(spacing: 8) { actions() }
                .controlSize(.small)
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: SettingsStyle.cardRadius, style: .continuous)
                .fill(tint.opacity(0.09))
        )
        .overlay(
            RoundedRectangle(cornerRadius: SettingsStyle.cardRadius, style: .continuous)
                .strokeBorder(tint.opacity(0.25))
        )
    }
}

/// Page scaffold for preference panes: header, then cards.
struct SettingsPage<Content: View>: View {
    var title: String
    var subtitle: String? = nil
    var symbol: String = "gearshape"
    var tint: Color = .gray
    @ViewBuilder var content: () -> Content

    var body: some View {
        DetailScroll {
            PageHeader(title: title, subtitle: subtitle) {
                IconTile(symbol: symbol, tint: tint, size: 44)
            }
            content()
        }
    }
}

// MARK: - Display thumbnails

/// A small screen drawn with the display's aspect ratio; the main display
/// carries a menu bar strip.
struct ScreenThumbnail: View {
    var aspect: CGFloat
    var selected: Bool = false
    var isMain: Bool = false
    var dimmed: Bool = false
    var dashed: Bool = false
    var box: CGSize = CGSize(width: 30, height: 22)

    var body: some View {
        let size = fitted
        let shape = RoundedRectangle(cornerRadius: max(2, size.height * 0.14), style: .continuous)
        ZStack(alignment: .top) {
            shape.fill(fill)
            if isMain {
                Rectangle()
                    .fill(Color.white.opacity(selected ? 0.55 : 0.4))
                    .frame(height: max(1.5, size.height * 0.12))
            }
            if dashed {
                shape.strokeBorder(style: StrokeStyle(lineWidth: 1.2, dash: [3, 2]))
                    .foregroundStyle(selected ? Color.white.opacity(0.8) : Color.secondary)
            }
        }
        .clipShape(shape)
        .frame(width: size.width, height: size.height)
        .opacity(dimmed ? 0.4 : 1)
        .frame(width: box.width, height: box.height)
    }

    private var fill: AnyShapeStyle {
        if dashed && !selected { return AnyShapeStyle(Color.primary.opacity(0.06)) }
        if selected {
            return AnyShapeStyle(LinearGradient(colors: [Color.accentColor.opacity(0.75), Color.accentColor],
                                                startPoint: .top, endPoint: .bottom))
        }
        return AnyShapeStyle(LinearGradient(colors: [Color.gray.opacity(0.55), Color.gray.opacity(0.8)],
                                            startPoint: .top, endPoint: .bottom))
    }

    private var fitted: CGSize {
        let ratio = max(0.3, min(4, aspect))
        if ratio >= box.width / box.height {
            return CGSize(width: box.width, height: box.width / ratio)
        }
        return CGSize(width: box.height * ratio, height: box.height)
    }
}

extension DisplayInfo {
    /// Width / height of the desktop, for thumbnails.
    var aspect: CGFloat {
        bounds.height > 0 ? bounds.width / bounds.height : 16.0 / 9
    }
}
