import AppKit
import SwiftUI
import YeeHawCore

/// The Settings window (spec "Settings"): open at login, each permission's status with a fix, and
/// the switched-off apps review. One instance, brought to the front when opened again. Spacing
/// lives in the Layout window.
@MainActor
final class SettingsWindowController: NSObject, NSWindowDelegate {
    static var current: SettingsWindowController?
    /// The system permissions are re-read this often while the window is open: they change in
    /// System Settings, which tells no one.
    static let pollInterval: TimeInterval = 1

    private let model: SettingsModel
    private let window: AuxiliaryPanel
    private var timer: Timer?
    private var placed = false

    /// Opens Settings, or brings it to the front.
    static func show(model: @autoclosure () -> SettingsModel) {
        let controller = current ?? SettingsWindowController(model: model())
        current = controller
        controller.show()
    }

    private init(model: SettingsModel) {
        self.model = model
        window = AuxiliaryPanel(width: SettingsView.width, title: "YeeHaw Settings")
        super.init()
        window.styleMask.insert(.miniaturizable)
        window.keepsTopEdge = true
        let hosting = NSHostingController(rootView: SettingsView(model: model))
        hosting.sizingOptions = [.preferredContentSize]
        window.contentViewController = hosting
        window.delegate = self
    }

    private func show() {
        let wasVisible = window.isVisible
        model.refresh()
        if !placed, let content = window.contentView {
            content.layoutSubtreeIfNeeded()
            window.setContentSize(content.fittingSize)
            window.center()
            placed = true
        }
        AppWindows.bringForward(window, name: "Settings")
        guard !wasVisible else { return }
        let timer = Timer(timeInterval: Self.pollInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.model.refreshSystemPermissions() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func windowDidBecomeKey(_ notification: Notification) {
        model.refresh()
    }

    func windowWillClose(_ notification: Notification) {
        timer?.invalidate()
        timer = nil
        model.showsReview = false
        AppWindows.windowClosing()
    }
}

// MARK: - Content

struct SettingsView: View {
    static let width: CGFloat = 560
    static let boxRadius: CGFloat = 10

    @Bindable var model: SettingsModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            section("General") {
                box { loginRow }
            }
            section("Permissions") {
                box {
                    ForEach(AppPermission.allCases) { permission in
                        if permission != .accessibility { insetDivider }
                        PermissionRow(permission: permission, state: model.state(of: permission),
                                      isBusy: model.fixing != nil) {
                            Task { await model.fix(permission) }
                        }
                    }
                }
                footnote("YeeHaw changes only the menu bar’s own settings and never reads your windows or what you type.")
            }
            .padding(.top, Self.sectionGap)
            section("Switched-Off Apps") {
                box { reviewRow }
            }
            .padding(.top, Self.sectionGap)
        }
        .padding(.horizontal, 20)
        .padding(.top, 6)
        .padding(.bottom, 20)
        .frame(width: Self.width)
        .sheet(isPresented: $model.showsReview) {
            SwitchedOffReviewSheet(model: model.review) { model.showsReview = false }
        }
    }

    private static let sectionGap: CGFloat = 20

    // MARK: Rows

    private var loginRow: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                // Read once, as the switch's label and hint.
                VStack(alignment: .leading, spacing: 2) {
                    Text("Open at Login")
                    Text(Self.loginDetail)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .accessibilityHidden(true)
                Spacer(minLength: 12)
                Toggle("Open at Login", isOn: Binding(get: { model.loginItem.isOn }, set: { model.loginItem.setOn($0) }))
                    .toggleStyle(.switch)
                    .labelsHidden()
                    .accessibilityHint(Self.loginDetail)
            }
            if model.loginItem.needsApproval {
                HStack(spacing: 8) {
                    warning("Waiting for your approval in System Settings → General → Login Items.")
                    Spacer(minLength: 8)
                    Button("Open Login Items…") { model.loginItem.openLoginItems() }
                }
            }
            if let error = model.loginItem.error {
                warning(error)
            }
        }
        .padding(.horizontal, PermissionRow.horizontalPadding)
        .padding(.vertical, 11)
    }

    private static let loginDetail = "YeeHaw starts when you log in, and keeps your hidden icons hidden."

    private var reviewRow: some View {
        HStack(spacing: 12) {
            Text("Apps you switched off in System Settings → Menu Bar stay off, and YeeHaw leaves them alone unless you move them to Hidden.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 12)
            Button("Review…") { model.openReview() }
                .accessibilityLabel("Review switched-off apps")
        }
        .padding(.horizontal, PermissionRow.horizontalPadding)
        .padding(.vertical, 11)
    }

    // MARK: Pieces

    /// A titled group: a header above its card, the same rhythm for every group.
    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title)
                .font(.headline)
                .accessibilityAddTraits(.isHeader)
                .padding(.leading, 2)
                .padding(.bottom, 8)
            content()
        }
    }

    private func footnote(_ text: String) -> some View {
        Text(text)
            .font(.callout)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.top, 8)
            .padding(.leading, 2)
    }

    private func warning(_ text: String) -> some View {
        Label(text, systemImage: "exclamationmark.triangle.fill")
            .symbolRenderingMode(.multicolor)
            .font(.callout)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func box<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: Self.boxRadius, style: .continuous)
        return VStack(spacing: 0) { content() }
            .frame(maxWidth: .infinity, alignment: .leading)
            .wellBox(shape)
            .clipShape(shape)
            .accessibilityElement(children: .contain)
    }

    private var insetDivider: some View {
        Divider()
            .padding(.leading, PermissionRow.textInset)
            .padding(.trailing, PermissionRow.horizontalPadding)
    }
}

/// One permission: an icon tile, its name and what it's for, and at the trailing edge either
/// "Allowed" or the button that fixes it. The trailing column has one width, so every row's
/// status and button end on the same line.
private struct PermissionRow: View {
    static let horizontalPadding: CGFloat = 12
    static let tileSize: CGFloat = 26
    static let tileGap: CGFloat = 10
    static let textInset: CGFloat = horizontalPadding + tileSize + tileGap
    /// Fits the widest button, "Grant Access…".
    static let trailingWidth: CGFloat = 118

    let permission: AppPermission
    let state: SettingsModel.PermissionState
    let isBusy: Bool
    let onFix: () -> Void

    var body: some View {
        HStack(spacing: Self.tileGap) {
            PermissionTile(symbol: permission.symbol, color: permission.tint, isMissing: state == .missing)
            VStack(alignment: .leading, spacing: 2) {
                Text(permission.title)
                Text(permission.detail)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .accessibilityElement(children: .combine)
            Spacer(minLength: 12)
            trailing
                .frame(width: Self.trailingWidth, alignment: .trailing)
        }
        .padding(.horizontal, Self.horizontalPadding)
        .padding(.vertical, 9)
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder
    private var trailing: some View {
        switch state {
        case .granted:
            Label {
                Text(AppPermission.grantedStatus)
            } icon: {
                Image(systemName: "checkmark.circle.fill")
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(.white, .green)
            }
            .font(.callout)
            .foregroundStyle(.secondary)
            .accessibilityLabel("\(permission.title): \(AppPermission.grantedStatus)")
        case .missing, .optionalOff:
            fixButton
        }
    }

    private var fixButton: some View {
        Button(permission.fixTitle, action: onFix)
            .disabled(isBusy)
            .help(permission.fixHelp)
            .accessibilityLabel("\(permission.fixTitle.replacingOccurrences(of: "…", with: "")): \(permission.title)")
            .accessibilityValue(state == .missing ? "Not allowed" : "Off")
    }
}

/// A System Settings-style icon: a white symbol on a coloured rounded square, badged with a
/// warning while a required permission is missing.
private struct PermissionTile: View {
    let symbol: String
    let color: Color
    var isMissing = false

    var body: some View {
        RoundedRectangle(cornerRadius: 6, style: .continuous)
            .fill(color.gradient)
            .overlay {
                Image(systemName: symbol)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white)
            }
            .frame(width: PermissionRow.tileSize, height: PermissionRow.tileSize)
            .overlay(alignment: .bottomTrailing) {
                if isMissing {
                    Image(systemName: "exclamationmark.circle.fill")
                        .font(.system(size: 13, weight: .bold))
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(.white, .orange)
                        .background(Circle().fill(Color(nsColor: .windowBackgroundColor)).padding(-1.5))
                        .offset(x: 5, y: 5)
                }
            }
            .accessibilityHidden(true)
    }
}

extension AppPermission {
    var tint: Color {
        switch self {
        case .accessibility: .blue
        case .allowList: .green
        case .layoutFile: .orange
        case .screenRecording: .purple
        }
    }
}

/// Settings' "Review…": the onboarding review step in a sheet. Ticked apps move to Hidden.
struct SwitchedOffReviewSheet: View {
    let model: SwitchedOffReviewModel
    let onDone: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Switched-Off Apps")
                .font(.headline)
                .accessibilityAddTraits(.isHeader)
            Text(OnboardingStep.review.explanation)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 4)
                .padding(.bottom, 12)
            SwitchedOffList(model: model,
                            unreadableAdvice: "Try again, or check Menu Bar Allow List under Permissions.",
                            retry: { model.reload() })
            if let error = model.error, model.loaded {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .symbolRenderingMode(.multicolor)
                    .font(.callout)
                    .padding(.top, 8)
            }
            HStack(spacing: 8) {
                if model.isCommitting {
                    ProgressView().controlSize(.small)
                }
                Spacer()
                Button("Cancel", role: .cancel, action: onDone)
                    .keyboardShortcut(.cancelAction)
                Button(model.commitTitle ?? "Move to Hidden") {
                    Task { if await model.commit() { onDone() } }
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(model.tickedIDs.isEmpty || model.isCommitting)
            }
            .padding(.top, 16)
        }
        .padding(20)
        .frame(width: 440)
    }
}
