import SwiftUI

// MARK: - Tool chip (timeline tool dock)
public struct CSToolChip: View {
    public let icon: CSIcon
    public let label: String
    public var isSelected = false
    public var action: () -> Void = {}

    public init(_ icon: CSIcon, _ label: String, isSelected: Bool = false, action: @escaping () -> Void = {}) {
        self.icon = icon; self.label = label; self.isSelected = isSelected; self.action = action
    }

    public var body: some View {
        Button {
            CSHaptics.tick()
            action()
        } label: {
            VStack(spacing: CSSpacing.xs) {
                icon.symbol
                    .font(.system(size: 20, weight: .medium))
                Text(label).font(CSType.chip)
            }
            .foregroundStyle(isSelected ? CSTheme.bg : CSTheme.textPrimary)
            .padding(.horizontal, CSSpacing.l)
            .padding(.vertical, CSSpacing.s)
            .background(isSelected ? CSTheme.accent : CSTheme.surfaceHigh)
            .clipShape(Capsule())
        }
        .buttonStyle(.plain)
        .animation(CSMotion.fastOut, value: isSelected)
        .accessibilityLabel(label)
    }
}

// MARK: - Primary gradient CTA ("New project", Export)
public struct CSPrimaryButton: View {
    public let title: String
    public let icon: CSIcon?
    public var action: () -> Void = {}

    public init(_ title: String, icon: CSIcon? = nil, action: @escaping () -> Void = {}) {
        self.title = title; self.icon = icon; self.action = action
    }

    public var body: some View {
        Button(action: action) {
            HStack(spacing: CSSpacing.s) {
                icon?.symbol.font(.system(size: 16, weight: .semibold))
                Text(title).font(CSType.title)
            }
            .foregroundStyle(.black)
            .padding(.horizontal, CSSpacing.l + CSSpacing.xs)
            .padding(.vertical, CSSpacing.m)
            .background(CSTheme.accentGradient)
            .clipShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
    }
}

// MARK: - Surface card
public struct CSCard<Content: View>: View {
    let content: Content
    public init(@ViewBuilder content: () -> Content) { self.content = content() }

    public var body: some View {
        content
            .padding(CSSpacing.l)
            .background(CSTheme.surface)
            .clipShape(RoundedRectangle(cornerRadius: CSRadius.card, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: CSRadius.card, style: .continuous)
                    .strokeBorder(CSTheme.hairline, lineWidth: 1)
            )
    }
}

// MARK: - Empty state
public struct CSEmptyState: View {
    public let icon: CSIcon
    public let title: String
    public let subtitle: String

    public init(_ icon: CSIcon, _ title: String, _ subtitle: String) {
        self.icon = icon; self.title = title; self.subtitle = subtitle
    }

    public var body: some View {
        VStack(spacing: CSSpacing.m) {
            icon.symbol
                .font(.system(size: 44, weight: .light))
                .foregroundStyle(CSTheme.textSecondary)
            Text(title).font(CSType.title).foregroundStyle(CSTheme.textPrimary)
            Text(subtitle).font(CSType.body)
                .foregroundStyle(CSTheme.textSecondary)
                .multilineTextAlignment(.center)
        }
        .padding(CSSpacing.l + CSSpacing.m)
    }
}

// MARK: - Drawer grabber handle (bottom sheets)
public struct CSGrabber: View {
    public init() {}
    public var body: some View {
        Capsule()
            .fill(CSTheme.hairline)
            .frame(width: 40, height: 5)
            .padding(.top, CSSpacing.s)
            .accessibilityHidden(true)
    }
}
