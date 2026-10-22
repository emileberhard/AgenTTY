import Observation
import SwiftUI
import UIKit

// MARK: - Sheet detail mode

enum SheetDetailMode<T> {
    case add
    case edit(T)

    var isAdd: Bool {
        if case .add = self { return true }
        return false
    }

    var existing: T? {
        if case .edit(let v) = self { return v }
        return nil
    }
}

// MARK: - Theme invalidation token

@MainActor
@Observable
final class AppThemeToken {
    private(set) var nonce = 0
    func invalidate() { nonce &+= 1 }
}

// MARK: - Sheet presentation state

@MainActor
@Observable
final class SheetPresentation {
    var showSettings = false
    var showTips = false
    var showHosts = false
    var showSSHKeys = false
    var showThemes = false
    var pendingHostEditorID: UUID?

    func presentHosts(hostEditorID: UUID? = nil) {
        pendingHostEditorID = hostEditorID
        showHosts = true
    }
}

// MARK: - Sheet presentation helpers

extension View {
    func esmaTermSheetBackground() -> some View {
        presentationBackground {
            Rectangle().fill(AppTheme.terminalBackground.opacity(0.3))
        }
    }

    func sheetDestructiveAlert(
        title: String,
        confirmTitle: String,
        message: String,
        isPresented: Binding<Bool>,
        onConfirm: @escaping () -> Void
    ) -> some View {
        modifier(
            SheetDestructiveAlertModifier(
                title: title,
                confirmTitle: confirmTitle,
                message: message,
                isPresented: isPresented,
                onConfirm: onConfirm
            )
        )
    }
}

@safe
private struct SheetDestructiveAlertModifier: ViewModifier {
    let title: String
    let confirmTitle: String
    let message: String
    let isPresented: Binding<Bool>
    let onConfirm: () -> Void

    func body(content: Content) -> some View {
        content.alert(title, isPresented: isPresented) {
            Button(confirmTitle, role: .destructive, action: onConfirm)
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(message)
        }
    }
}

// MARK: - Shared sheet form field row

@safe
struct SheetFormFieldRow<Field: Hashable>: View {
    let icon: String
    let label: String
    let placeholder: String
    @Binding var text: String
    let field: Field
    var focusedField: FocusState<Field?>.Binding
    let isValid: Bool
    var keyboardType: UIKeyboardType = .default
    var autocapitalization: TextInputAutocapitalization = .never
    var submitLabel: SubmitLabel = .next
    var onSubmit: () -> Void = {}
    var showsValidationIndicator = true
    var trailingAccessory: AnyView? = nil

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(
                    focusedField.wrappedValue == field ? AppTheme.primaryText : AppTheme.secondaryText
                )
                .frame(width: 18)
                .animation(.easeOut(duration: 0.2), value: focusedField.wrappedValue)

            Text(label)
                .foregroundStyle(AppTheme.primaryText)

            Spacer(minLength: 4)

            TextField(placeholder, text: $text)
                .multilineTextAlignment(.trailing)
                .textInputAutocapitalization(autocapitalization)
                .autocorrectionDisabled()
                .keyboardType(keyboardType)
                .focused(focusedField, equals: field)
                .submitLabel(submitLabel)
                .onSubmit(onSubmit)

            if let trailingAccessory {
                trailingAccessory
            } else if showsValidationIndicator {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 14))
                    .foregroundStyle(.green.opacity(0.7))
                    .opacity(isValid ? 1 : 0)
                    .scaleEffect(isValid ? 1 : 0.5)
                    .frame(width: 16)
                    .animation(.spring(duration: 0.3, bounce: 0.3), value: isValid)
            }
        }
        .padding(.vertical, 4)
        .listRowBackground(
            focusedField.wrappedValue == field
                ? AppTheme.surfaceOrnamentFill
                : AppTheme.sheetListRowBackground
        )
    }
}

// MARK: - Sheet detail navigation

@MainActor
@Observable
final class SheetNavigationCoordinator<Route: Hashable> {
    var path: [Route] = []
    var selectedDetent: PresentationDetent = .medium
    var pendingRoute: Route?

    func navigate(to route: Route) {
        guard path.isEmpty else { return }
        presentDetail(route)
    }

    func presentDetail(_ route: Route) {
        withAnimation(.spring(duration: 0.3)) {
            selectedDetent = .large
        }
        pendingRoute = route
    }

    func resetToRoot(detent: PresentationDetent = .medium) {
        pendingRoute = nil
        withAnimation(.spring(duration: 0.3)) {
            path.removeAll()
            selectedDetent = detent
        }
    }
}

extension View {
    func sheetDetailNavigation<Route: Hashable>(
        _ coordinator: SheetNavigationCoordinator<Route>
    ) -> some View {
        task(id: coordinator.pendingRoute) {
            guard let route = coordinator.pendingRoute else { return }
            try? await Task.sleep(for: .milliseconds(100))
            guard !Task.isCancelled else { return }
            coordinator.path.append(route)
            coordinator.pendingRoute = nil
        }
    }
}

// MARK: - Sheet destructive action button

@safe
struct SheetDestructiveActionButton: View {
    let action: () -> Void

    var body: some View {
        Button(role: .destructive, action: action) {
            HStack(spacing: 10) {
                Image(systemName: "trash")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.red)
                Text("Delete")
                    .font(.subheadline.weight(.semibold))
            }
            .frame(maxWidth: .infinity, minHeight: 44)
        }
        .buttonStyle(.glassProminent)
        .tint(Color.red.opacity(0.13))
    }
}

// MARK: - Shared sheet picker row

@safe
struct SheetPickerRow<SelectionValue: Hashable, Content: View>: View {
    let icon: String
    let label: String
    let selection: Binding<SelectionValue>
    @ViewBuilder let content: () -> Content

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(AppTheme.secondaryText)
                .frame(width: 18)

            Picker(label, selection: selection, content: content)
                .tint(AppTheme.secondaryText)
        }
        .padding(.vertical, 4)
        .listRowBackground(AppTheme.sheetListRowBackground)
    }
}
