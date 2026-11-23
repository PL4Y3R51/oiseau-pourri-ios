import SwiftUI
import OiseauCore

/// A Lucide icon from the asset catalog (`lucide_bird`…), tinted like text.
struct LucideIcon: View {
    let name: String
    var size: CGFloat = 20

    init(_ name: String, size: CGFloat = 20) {
        self.name = name
        self.size = size
    }

    var body: some View {
        Image("lucide_\(name)")
            .renderingMode(.template)
            .resizable()
            .scaledToFit()
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}

/// Mascot artwork (spec §14). The cartoon poses everywhere; the base photo only for
/// default avatars and the welcome's hello.
enum MascottePose: String {
    case cartoon, wave, search, place, celebrate, sad, photo
}

struct Mascotte: View {
    let pose: MascottePose
    var label: String?

    init(_ pose: MascottePose, label: String? = nil) {
        self.pose = pose
        self.label = label
    }

    var body: some View {
        let image = Image("mascotte_\(pose.rawValue)").resizable()
        Group {
            if pose == .photo { image.scaledToFill() } else { image.scaledToFit() }
        }
        .accessibilityLabel(label ?? "")
        .accessibilityHidden(label == nil)
    }
}

/// The web's three button looks (packages/ui/src/Button.css), in relief.
enum OpButtonVariant { case primary, secondary, danger }

struct OpButtonStyle: ButtonStyle {
    var variant: OpButtonVariant = .primary
    var fullWidth = false
    @Environment(\.isEnabled) private var enabled

    init(variant: OpButtonVariant = .primary, fullWidth: Bool = false) {
        self.variant = variant
        self.fullWidth = fullWidth
    }

    func makeBody(configuration: Configuration) -> some View {
        let (fill, text): (Color, Color) = {
            guard enabled else { return (Zine.surfaceVariant, Zine.muted) }
            switch variant {
            case .primary: return (Zine.ink, Zine.yellow)
            case .secondary: return (Zine.panel, Zine.ink)
            case .danger: return (Zine.panel, Zine.error)
            }
        }()
        let shape = RoundedRectangle(cornerRadius: Zine.radiusSmall)
        return configuration.label
            .font(.zLabel)
            .foregroundStyle(text)
            .padding(.horizontal, 18)
            .padding(.vertical, 12)
            .frame(maxWidth: fullWidth ? .infinity : nil, minHeight: 48)
            .background(fill)
            .modifier(ButtonRelief(shape: shape, pressed: configuration.isPressed, enabled: enabled))
            .animation(.easeOut(duration: 0.08), value: configuration.isPressed)
    }
}

/// In relief while it can be pressed; flat, without outline or shadow, when disabled.
private struct ButtonRelief<S: Shape>: ViewModifier {
    let shape: S
    let pressed: Bool
    let enabled: Bool

    func body(content: Content) -> some View {
        if enabled {
            content.relief(shape, sunk: pressed)
        } else {
            content.clipShape(shape)
        }
    }
}

/// The one button of the app: text, an optional Lucide icon.
struct OpButton: View {
    let title: String
    var icon: String?
    var variant: OpButtonVariant = .primary
    var fullWidth = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                if let icon { LucideIcon(icon, size: 20) }
                Text(title).multilineTextAlignment(.center)
            }
        }
        .buttonStyle(OpButtonStyle(variant: variant, fullWidth: fullWidth))
    }
}

/// A quiet text button (Material's TextButton).
struct LinkButton: View {
    let title: String
    var color: Color = Zine.ink
    var font: Font = .zLabel
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title).font(font).foregroundStyle(color).multilineTextAlignment(.center)
                .padding(.vertical, 10).padding(.horizontal, 12)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// What a field holds: drives the keyboard, masking and autofill.
enum FieldKind { case text, name, email, password, newPassword }

/// Text input with its label above: a white box outlined in black, pink while typing.
struct OpTextField: View {
    let label: String
    @Binding var text: String
    var kind: FieldKind = .text
    var supporting: String?
    var isError = false
    var submitLabel: SubmitLabel = .next
    var onSubmit: () -> Void = {}
    /// The UI tests find the field by this.
    var identifier: String?
    @FocusState private var focused: Bool

    init(
        label: String, text: Binding<String>, kind: FieldKind = .text, supporting: String? = nil, isError: Bool = false,
        submitLabel: SubmitLabel = .next, identifier: String? = nil, onSubmit: @escaping () -> Void = {}
    ) {
        self.label = label
        _text = text
        self.kind = kind
        self.supporting = supporting
        self.isError = isError
        self.submitLabel = submitLabel
        self.identifier = identifier
        self.onSubmit = onSubmit
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).font(.zBody).foregroundStyle(Zine.muted)
            Group {
                if kind == .password || kind == .newPassword {
                    SecureField("", text: $text)
                } else {
                    TextField("", text: $text)
                }
            }
            .font(.zBodyLarge)
            .foregroundStyle(Zine.ink)
            .tint(Zine.ink)
            .focused($focused)
            .textContentType(contentType)
            .keyboardType(kind == .email ? .emailAddress : .default)
            .textInputAutocapitalization(kind == .name ? .words : .never)
            .autocorrectionDisabled(kind != .text)
            .submitLabel(submitLabel)
            .onSubmit(onSubmit)
            .padding(.horizontal, 16)
            .frame(minHeight: 56)
            .background(Zine.panel, in: RoundedRectangle(cornerRadius: Zine.radiusSmall))
            .overlay {
                RoundedRectangle(cornerRadius: Zine.radiusSmall)
                    .stroke(isError ? Zine.error : (focused ? Zine.pink : Zine.ink), lineWidth: focused ? 2 : 1)
            }
            .accessibilityLabel(label)
            .accessibilityIdentifier(identifier ?? "")
            if let supporting {
                Text(supporting).font(.zBodySmall).foregroundStyle(isError ? Zine.error : Zine.muted).padding(.horizontal, 16)
            }
        }
    }

    private var contentType: UITextContentType? {
        switch kind {
        case .email: return .username
        case .password: return .password
        case .newPassword: return .newPassword
        case .name: return .nickname
        case .text: return nil
        }
    }
}

/// A square check box in the look: white, outlined, black once ticked.
struct ZineCheckbox: View {
    @Binding var isOn: Bool
    var label: String

    var body: some View {
        Button { isOn.toggle() } label: {
            ZStack {
                RoundedRectangle(cornerRadius: 3).fill(isOn ? Zine.ink : Zine.panel)
                RoundedRectangle(cornerRadius: 3).stroke(Zine.ink, lineWidth: 2)
                if isOn { LucideIcon("check", size: 16).foregroundStyle(Zine.yellow) }
            }
            .frame(width: 22, height: 22)
            .frame(width: 44, height: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
        .accessibilityValue(isOn ? "1" : "0")
        .accessibilityAddTraits(.isButton)
    }
}
