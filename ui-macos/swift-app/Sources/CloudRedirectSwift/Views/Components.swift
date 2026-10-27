import SwiftUI
import AppKit

struct PageLayout<Content: View>: View {
    let title: String
    let subtitle: String
    @ViewBuilder var content: Content
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                VStack(alignment: .leading, spacing: 7) {
                    Text(title).font(.system(size: 27, weight: .bold, design: .rounded))
                    Text(subtitle).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }.padding(.bottom, 2)
                content
            }
            .frame(maxWidth: 960, alignment: .leading)
            .padding(.horizontal, 32).padding(.top, 20).padding(.bottom, 32)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
    }
}

struct Panel<Content: View>: View {
    var spacing: CGFloat = 18
    @ViewBuilder var content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: spacing) { content }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(22)
            .background(.background.opacity(0.55), in: RoundedRectangle(cornerRadius: 20))
            .overlay { RoundedRectangle(cornerRadius: 20).strokeBorder(.primary.opacity(0.055)) }
            .shadow(color: .black.opacity(0.025), radius: 12, y: 4)
    }
}


struct SettingLine<Content: View>: View {
    let title: String
    let detail: String
    @ViewBuilder var content: Content
    var body: some View {
        HStack(alignment: .center, spacing: 20) {
            VStack(alignment: .leading, spacing: 5) {
                Text(title).fontWeight(.semibold)
                Text(detail).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 12)
            content
        }.frame(maxWidth: .infinity)
    }
}

struct ModernControls: ViewModifier {
    func body(content: Content) -> some View {
        content.buttonStyle(ModernActionStyle())
    }
}

struct ActionButton: View {
    let title: String
    var primary = false
    var action: () -> Void
    var body: some View {
        Button(title, action: action).buttonStyle(ModernActionStyle(primary: primary))
    }
}

struct ModernActionStyle: ButtonStyle {
    var primary = false
    @Environment(\.isEnabled) private var enabled
    @State private var hovered = false
    func makeBody(configuration: Configuration) -> some View {
        surface(configuration.label
            .font(.system(size: 13, weight: .regular))
            .foregroundStyle(Color.black)
            .padding(.horizontal, 18).frame(minHeight: 36)
            .contentShape(Capsule()))
            .overlay { Capsule().fill(Color.primary.opacity(hovered && enabled ? 0.045 : 0)) }
            .onHover { hovered = $0 }
            .opacity(enabled ? (configuration.isPressed ? 0.75 : 1) : 0.4)
    }
    @ViewBuilder private func surface<Label: View>(_ label: Label) -> some View {
        if #available(macOS 26.0, *) {
            label.glassEffect(primary ? .regular.tint(sage).interactive() : .regular.interactive(), in: Capsule())
        } else {
            label.background(primary ? sage : Color.primary.opacity(0.06), in: Capsule())
        }
    }
}

struct RoundedInputStyle: TextFieldStyle {
    func _body(configuration: TextField<Self._Label>) -> some View {
        FocusedInput(content: configuration.textFieldStyle(.plain))
    }
}

private struct FocusedInput<Content: View>: View {
    let content: Content
    @FocusState private var focused: Bool
    var body: some View {
        content.focused($focused)
            .padding(.horizontal, 13).padding(.vertical, 11)
            .background(.background.opacity(0.8), in: RoundedRectangle(cornerRadius: 12))
            .overlay {
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(focused ? sageIcon : Color.primary.opacity(0.1), lineWidth: focused ? 2 : 1)
            }
            .shadow(color: focused ? sage.opacity(0.35) : .clear, radius: 3)
    }
}

private enum ControlCenterAlignment: AlignmentID {
    static func defaultValue(in context: ViewDimensions) -> CGFloat { context[VerticalAlignment.center] }
}
extension VerticalAlignment {
    static let controlCenter = VerticalAlignment(ControlCenterAlignment.self)
}

struct ChoiceMenu<Value: Hashable>: View {
    let title: String
    @Binding var selection: Value
    let options: [(Value, String)]
    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(title).font(.caption).fontWeight(.medium).foregroundStyle(.secondary)
            NativeChoice(title: title, selection: $selection, options: options)
                .frame(height: 38).padding(.horizontal, 10)
                .background(.background.opacity(0.85), in: RoundedRectangle(cornerRadius: 12))
                .overlay { RoundedRectangle(cornerRadius: 12).strokeBorder(.primary.opacity(0.1)) }
                .alignmentGuide(.controlCenter) { $0[VerticalAlignment.center] }

        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct NativeChoice<Value: Hashable>: NSViewRepresentable {
    let title: String
    @Binding var selection: Value
    let options: [(Value, String)]
    @Environment(\.isEnabled) private var enabled
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeNSView(context: Context) -> NSPopUpButton {
        let popup = NSPopUpButton(frame: .zero, pullsDown: false)
        popup.isBordered = false
        popup.alignment = .left
        popup.font = .systemFont(ofSize: 13, weight: .medium)
        popup.contentTintColor = .labelColor
        popup.setContentHuggingPriority(.defaultLow, for: .horizontal)
        popup.target = context.coordinator
        popup.action = #selector(Coordinator.changed(_:))
        return popup
    }
    func updateNSView(_ popup: NSPopUpButton, context: Context) {
        context.coordinator.parent = self
        let titles = options.map { $0.1 }
        if popup.itemTitles != titles { popup.removeAllItems(); popup.addItems(withTitles: titles) }
        if let index = options.firstIndex(where: { $0.0 == selection }) { popup.selectItem(at: index) }
        popup.isEnabled = enabled
        popup.setAccessibilityLabel(title)
    }
    final class Coordinator: NSObject {
        var parent: NativeChoice
        init(_ parent: NativeChoice) { self.parent = parent }
        @objc func changed(_ popup: NSPopUpButton) {
            let index = popup.indexOfSelectedItem
            guard parent.options.indices.contains(index) else { return }
            parent.selection = parent.options[index].0
        }
    }
}

struct GameArt: View {
    let url: String
    var body: some View {
        AsyncImage(url: URL(string: url)) { image in image.resizable().scaledToFill() }
        placeholder: { ZStack { Color.secondary.opacity(0.09); Image(systemName: "gamecontroller").foregroundStyle(.secondary) } }
            .frame(width: 104, height: 49).clipShape(RoundedRectangle(cornerRadius: 10))
    }
}

struct IconActionStyle: ButtonStyle {
    @State private var hovered = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.padding(4)
            .foregroundStyle(.secondary)
            .background(.primary.opacity(configuration.isPressed ? 0.14 : hovered ? 0.09 : 0.045), in: RoundedRectangle(cornerRadius: 10))
            .contentShape(RoundedRectangle(cornerRadius: 10))
            .onHover { hovered = $0 }
    }
}
