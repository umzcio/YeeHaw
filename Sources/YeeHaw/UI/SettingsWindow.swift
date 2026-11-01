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
        window = AuxiliaryPanel(width: SettingsView.width, title: "Settings")
        super.init()
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
    static let width: CGFloat = 520
    static let boxRadius: CGFloat = 10

    @Bindable var model: SettingsModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            box { loginRow }
            sectionTitle("Permissions")
                .padding(.top, 22)
            box {
                ForEach(AppPermission.allCases) { permission in
                    if permission != .accessibility { insetDivider }
                    PermissionRow(permission: permission, state: model.state(of: permission),
                                  isBusy: model.fixing != nil) {
                        Task { await model.fix(permission) }
                    }
                }
            }
            Text("YeeHaw changes only the menu bar’s own settings. Screen Recording, if you turn it on, is used only to picture menu bar icons in the strip.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 8)
            box { reviewRow }
                .padding(.top, 22)
        }
        .padding(.horizontal, 20)
        .padding(.top, 6)
        .padding(.bottom, 20)
        .frame(width: Self.width)
        .sheet(isPresented: $model.showsReview) {
            SwitchedOffReviewSheet(model: model.review) { model.showsReview = false }
        }
    }

    // MARK: Rows

    private var loginRow: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Open at Login")
                    Text("YeeHaw starts when you log in, and keeps your hidden icons hidden.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .accessibilityElement(children: .combine)
                Spacer(minLength: 12)
                Toggle("Open at Login", isOn: Binding(get: { model.loginItem.isOn }, set: { model.loginItem.setOn($0) }))
                    .toggleStyle(.switch)
                    .labelsHidden()
            }
            if model.loginItem.needsApproval {
                HStack(spacing: 8) {
                    Label("Waiting for your approval in System Settings → General → Login Items.",
                          systemImage: "exclamationmark.triangle.fill")
                        .symbolRenderingMode(.multicolor)
                        .font(.callout)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 8)
                    Button("Open Login Items…") { model.loginItem.openLoginItems() }
                        .controlSize(.small)
                }
            }
            if let error = model.loginItem.error {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .symbolRenderingMode(.multicolor)
                    .font(.callout)
            }
        }
        .padding(.horizontal, PermissionRow.horizontalPadding)
        .padding(.vertical, 11)
    }

    private var reviewRow: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Switched-Off Apps")
                Text("Apps you switched off in System Settings → Menu Bar stay off, and YeeHaw leaves them alone unless you move them to Hidden.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .accessibilityElement(children: .combine)
            Spacer(minLength: 12)
            Button("Review…") { model.openReview() }
                .accessibilityLabel("Review switched-off apps")
        }
        .padding(.horizontal, PermissionRow.horizontalPadding)
        .padding(.vertical, 11)
    }

    // MARK: Pieces

    private func sectionTitle(_ title: String) -> some View {
        Text(title)
            .font(.headline)
            .accessibilityAddTraits(.isHeader)
            .padding(.bottom, 8)
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

/// One permission: an icon tile, its name and what it's for, its status, and a fix when it's off.
private struct PermissionRow: View {
    static let horizontalPadding: CGFloat = 12
    static let tileSize: CGFloat = 26
    static let tileGap: CGFloat = 10
    static let textInset: CGFloat = horizontalPadding + tileSize + tileGap

    let permission: AppPermission
    let state: SettingsModel.PermissionState
    let isBusy: Bool
    let onFix: () -> Void

    var body: some View {
        HStack(spacing: Self.tileGap) {
            PermissionTile(symbol: permission.symbol, color: permission.tint)
            VStack(alignment: .leading, spacing: 2) {
                Text(permission.title)
                Text(permission.detail)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .accessibilityElement(children: .combine)
            Spacer(minLength: 12)
            status
            if state != .granted {
                Button(state == .optionalOff ? "Turn On…" : "Fix…", action: onFix)
                    .disabled(isBusy)
                    .help(permission.file != nil ? "Choose the file again" : "Opens Privacy & Security in System Settings")
                    .accessibilityLabel(state == .optionalOff ? "Turn on \(permission.title)" : "Fix \(permission.title)")
            }
        }
        .padding(.horizontal, Self.horizontalPadding)
        .padding(.vertical, 9)
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder
    private var status: some View {
        switch state {
        case .granted:
            Label {
                Text("Allowed")
            } icon: {
                Image(systemName: "checkmark.circle.fill")
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(.white, .green)
            }
            .font(.callout)
            .foregroundStyle(.secondary)
        case .missing:
            Label("Not Allowed", systemImage: "exclamationmark.triangle.fill")
                .symbolRenderingMode(.multicolor)
                .font(.callout)
                .foregroundStyle(.secondary)
        case .optionalOff:
            Text("Off")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }
}

/// A System Settings-style icon: a white symbol on a coloured rounded square.
private struct PermissionTile: View {
    let symbol: String
    let color: Color

    var body: some View {
        RoundedRectangle(cornerRadius: 6, style: .continuous)
            .fill(color.gradient)
            .overlay {
                Image(systemName: symbol)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white)
            }
            .frame(width: PermissionRow.tileSize, height: PermissionRow.tileSize)
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
            SwitchedOffList(model: model)
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
