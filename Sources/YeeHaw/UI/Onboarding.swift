import AppKit
import SwiftUI
import YeeHawCore

/// The first-run window (spec "First run"): one window with the five steps as a checklist. The
/// current step is open; finished steps show a tick and can be opened again. Done closes it.
@MainActor
final class OnboardingWindowController: NSObject, NSWindowDelegate {
    /// The open window; kept alive until it closes.
    private static var current: OnboardingWindowController?
    /// Accessibility is polled this often while the window is open.
    static let pollInterval: TimeInterval = 1

    private let model: OnboardingModel
    private let window: AuxiliaryPanel
    private var timer: Timer?
    private var finished = false
    private var completion: CheckedContinuation<Bool, Never>?

    /// Shows onboarding and returns when its window closes: true after Done, false when it was
    /// closed before then.
    static func run(model: OnboardingModel) async -> Bool {
        await model.start()
        return await withCheckedContinuation { continuation in
            let controller = OnboardingWindowController(model: model, completion: continuation)
            current = controller
            controller.show()
        }
    }

    private init(model: OnboardingModel, completion: CheckedContinuation<Bool, Never>) {
        self.model = model
        self.completion = completion
        window = AuxiliaryPanel(width: OnboardingView.width, title: "Welcome to YeeHaw")
        super.init()

        window.titleVisibility = .hidden
        window.keepsTopEdge = true
        // Onboarding is finished, not put away: no minimize, and nothing to zoom.
        window.standardWindowButton(.miniaturizeButton)?.isHidden = true
        window.standardWindowButton(.zoomButton)?.isHidden = true
        let hosting = NSHostingController(rootView: OnboardingView(model: model))
        hosting.sizingOptions = [.preferredContentSize]
        window.contentViewController = hosting
        window.delegate = self
        model.onFinish = { [weak self] in
            self?.finished = true
            self?.window.close()
        }
        // The user turned Accessibility on in System Settings: bring the window back.
        model.onTrusted = { [weak self] in
            guard let self else { return }
            AppWindows.bringForward(window, name: "Onboarding")
        }
    }

    private func show() {
        if let content = window.contentView {
            content.layoutSubtreeIfNeeded()
            window.setContentSize(content.fittingSize)
        }
        window.center()
        AppWindows.bringForward(window, name: "Onboarding")
        let timer = Timer(timeInterval: Self.pollInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.model.tick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func windowWillClose(_ notification: Notification) {
        timer?.invalidate()
        timer = nil
        AppWindows.windowClosing()
        completion?.resume(returning: finished)
        completion = nil
        Self.current = nil
    }
}

// MARK: - Content

struct OnboardingView: View {
    static let width: CGFloat = 560

    let model: OnboardingModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(.bottom, 20)
            steps
            footer
                .padding(.top, 18)
        }
        .padding(.horizontal, 24)
        .padding(.top, 8)
        .padding(.bottom, 20)
        .frame(width: Self.width)
        .animation(reduceMotion ? nil : .spring(duration: 0.35, bounce: 0.08), value: model.expanded)
    }

    private var header: some View {
        HStack(spacing: 14) {
            HatBadge()
            VStack(alignment: .leading, spacing: 3) {
                Text("Welcome to YeeHaw")
                    .font(.title2.weight(.semibold))
                    .accessibilityAddTraits(.isHeader)
                Text("Five quick steps, and your menu bar is yours to tidy.")
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var steps: some View {
        let shape = RoundedRectangle(cornerRadius: 12, style: .continuous)
        return VStack(spacing: 0) {
            ForEach(OnboardingStep.allCases) { step in
                if step != .accessibility {
                    Divider()
                        .padding(.leading, OnboardingStepRow.textInset)
                        .padding(.trailing, OnboardingStepRow.horizontalPadding)
                }
                OnboardingStepRow(step: step, model: model)
            }
        }
        .wellBox(shape)
        .clipShape(shape)
    }

    private var footer: some View {
        HStack(spacing: 12) {
            Text("You can change all of this later in YeeHaw’s Settings.")
                .font(.callout)
                .foregroundStyle(.secondary)
            Spacer(minLength: 12)
            // Prominent only once it's the thing to do; until then the open step's button is.
            if model.isComplete {
                Button("Done") { model.finish() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
            } else {
                Button("Done") { model.finish() }
                    .disabled(true)
                    .help("Finish the steps above first")
            }
        }
    }
}

extension Color {
    /// YeeHaw's own colour, the same on every Mac (the system accent varies), for its hat tile.
    static let yeehawBrand = Color(red: 0.84, green: 0.35, blue: 0.17)
}

/// YeeHaw's hat on a tile in its brand colour, standing in for the app icon at the top.
private struct HatBadge: View {
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 12, style: .continuous)
        shape
            .fill(Color.yeehawBrand.gradient)
            .overlay {
                Image(nsImage: StatusGlyph.image())
                    .renderingMode(.template)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: 38, height: 38)
                    .foregroundStyle(.white)
                    .offset(y: 1)
            }
            .overlay {
                shape.strokeBorder(.black.opacity(contrast == .increased ? 0.4 : 0.12), lineWidth: 0.5)
            }
            .frame(width: 52, height: 52)
            .shadow(color: .black.opacity(0.18), radius: 1.5, y: 1)
            .accessibilityHidden(true)
    }
}

/// One step: a header line with its badge, title and (once done) a summary; open, it adds the
/// explanation and the step's controls.
private struct OnboardingStepRow: View {
    static let horizontalPadding: CGFloat = 14
    static let badgeSize: CGFloat = 22
    static let badgeGap: CGFloat = 12
    /// Where the titles and explanations start.
    static let textInset: CGFloat = horizontalPadding + badgeSize + badgeGap

    let step: OnboardingStep
    let model: OnboardingModel

    private var isExpanded: Bool { model.expanded == step }
    private var isDone: Bool { model.isDone(step) }
    /// A finished step can be opened and closed; the step in progress can be gone back to while
    /// another is open.
    private var isSelectable: Bool { (isDone && step != model.current) || (step == model.current && !isExpanded) }
    private var isUpcoming: Bool { !isDone && step != model.current }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if isSelectable {
                Button { model.select(step) } label: { headerLine }
                    .buttonStyle(StepHeaderButtonStyle())
                    .accessibilityHint(isExpanded ? "Hides this step"
                                       : (step == model.current ? "Goes back to this step" : "Shows this step again"))
            } else {
                headerLine
            }
            if isExpanded {
                OnboardingStepDetail(step: step, model: model)
                    .padding(.leading, Self.textInset - Self.horizontalPadding)
                    .padding(.bottom, 16)
                    .transition(.opacity)
            }
        }
        .padding(.horizontal, Self.horizontalPadding)
        .accessibilityElement(children: .contain)
    }

    private var headerLine: some View {
        HStack(spacing: Self.badgeGap) {
            StepBadge(number: step.number, state: isDone ? .done : (isUpcoming ? .upcoming : .current))
            Text(step.title)
                .fontWeight(isExpanded ? .semibold : .regular)
                .foregroundStyle(isUpcoming ? .secondary : .primary)
            Spacer(minLength: 8)
            if isDone, !isExpanded, let summary = model.summary(of: step) {
                Text(summary)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            if isDone, step != model.current {
                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .rotationEffect(.degrees(isExpanded ? 90 : 0))
                    .accessibilityHidden(true)
            }
        }
        .frame(height: 44)
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Step \(step.number) of \(OnboardingStep.allCases.count): \(step.title)")
        .accessibilityValue(isDone ? (model.summary(of: step) ?? "Done") : (isUpcoming ? "Not yet" : "In progress"))
        .accessibilityAddTraits(isExpanded ? [.isHeader, .isSelected] : .isHeader)
    }
}

/// A step header that can be clicked: a faint rounded highlight while the pointer is over it,
/// a little stronger while pressed, like a sidebar row.
private struct StepHeaderButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        Highlighted(configuration: configuration)
    }

    private struct Highlighted: View {
        let configuration: Configuration
        @State private var hovering = false
        @Environment(\.colorSchemeContrast) private var contrast

        var body: some View {
            let strength = configuration.isPressed ? 0.09 : (hovering ? 0.05 : 0)
            configuration.label
                .background {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Color.primary.opacity(contrast == .increased ? strength * 1.8 : strength))
                        .padding(.horizontal, -8)
                        .padding(.vertical, 5)
                }
                .onHover { hovering = $0 }
        }
    }
}

/// A step's number in a circle: filled with the accent colour while in progress, a green tick
/// once done, an outline before then.
private struct StepBadge: View {
    enum State { case current, done, upcoming }

    let number: Int
    let state: State
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        ZStack {
            switch state {
            case .done:
                Image(systemName: "checkmark.circle.fill")
                    .resizable()
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(.white, .green)
            case .current:
                Circle().fill(Color.accentColor)
                Text("\(number)")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(.white)
            case .upcoming:
                Circle().strokeBorder(contrast == .increased ? Color.primary.opacity(0.6) : Color(nsColor: .tertiaryLabelColor),
                                      lineWidth: 1.5)
                Text("\(number)")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: OnboardingStepRow.badgeSize, height: OnboardingStepRow.badgeSize)
        .accessibilityHidden(true)
    }
}

/// An open step's explanation and controls.
private struct OnboardingStepDetail: View {
    let step: OnboardingStep
    let model: OnboardingModel

    private var isDone: Bool { model.isDone(step) }
    /// The step's own action answers Return while it's the step in progress.
    private var isCurrent: Bool { model.current == step }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 6) {
                Text(step.explanation)
                if step == .accessibility, !isDone {
                    Text("Turn on YeeHaw in the list. If it isn’t listed, click + and choose it from Applications. "
                         + "This step completes on its own.")
                }
            }
            .font(.callout)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            switch step {
            case .accessibility: accessibility
            case .allowList: grant(.allowList)
            case .layoutFile: grant(.positions)
            case .review: review
            case .placeIcon: placeIcon
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var accessibility: some View {
        actionRow(note: nil) {
            if isDone {
                doneLabel(AppPermission.grantedStatus)
            } else {
                primary("Open System Settings") { model.openAccessibility() }
            }
        }
    }

    private func grant(_ file: GrantedFile) -> some View {
        actionRow(note: model.grantRefused == file ? "YeeHaw didn’t get access. Keep the selected file and click Allow." : nil,
                  warning: true) {
            if isDone {
                doneLabel(AppPermission.grantedStatus)
            } else {
                primary(AppPermission.grantActionTitle) { Task { await model.requestGrant(file) } }
                    .disabled(step != model.current)
            }
        }
    }

    private var review: some View {
        VStack(alignment: .leading, spacing: 12) {
            SwitchedOffList(model: model.review,
                            unreadableAdvice: "Try again, or continue and review these apps later in Settings.",
                            retry: { model.retryReview() })
            // A read failure shows in the list itself; only a failed move shows here.
            actionRow(note: model.review.loaded ? model.review.error : nil, warning: true) {
                if model.review.isCommitting {
                    ProgressView().controlSize(.small)
                }
                primary(model.review.commitTitle ?? "Continue") { Task { await model.finishReview() } }
                    .disabled(!model.canFinishReview)
            }
        }
    }

    private var placeIcon: some View {
        actionRow(note: model.placementError, warning: true) {
            if isDone {
                doneLabel(model.placement == .placed ? "Next to Control Center" : "Left where macOS puts it")
            } else {
                if model.isPlacing {
                    ProgressView().controlSize(.small)
                }
                Button("Skip") { model.skipPlacement() }
                    .disabled(model.isPlacing)
                primary("Place Icon") { Task { await model.placeIcon() } }
                    .disabled(model.isPlacing || !model.isDone(.layoutFile))
            }
        }
    }

    // MARK: Pieces

    /// A row of controls at the trailing edge, with an optional note at the leading edge.
    private func actionRow<Controls: View>(note: String?, warning: Bool = false,
                                           @ViewBuilder controls: () -> Controls) -> some View {
        HStack(alignment: .center, spacing: 8) {
            if let note {
                if warning {
                    Label(note, systemImage: "exclamationmark.triangle.fill")
                        .symbolRenderingMode(.multicolor)
                        .font(.callout)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    Text(note)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 8)
            controls()
        }
        .frame(minHeight: 24)
    }

    @ViewBuilder
    private func primary(_ title: String, action: @escaping () -> Void) -> some View {
        if isCurrent {
            Button(title, action: action)
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
        } else {
            Button(title, action: action)
        }
    }

    private func doneLabel(_ text: String) -> some View {
        Label {
            Text(text)
        } icon: {
            Image(systemName: "checkmark.circle.fill")
                .symbolRenderingMode(.palette)
                .foregroundStyle(.white, .green)
        }
        .font(.callout)
        .foregroundStyle(.secondary)
    }
}

// MARK: - Words

extension OnboardingStep {
    var title: String {
        switch self {
        case .accessibility: "Allow \(AppPermission.accessibility.title)"
        case .allowList: "Give access to the \(AppPermission.allowList.title)"
        case .layoutFile: "Give access to the \(AppPermission.layoutFile.title)"
        case .review: "Review switched-off apps"
        case .placeIcon: "Place YeeHaw’s icon"
        }
    }

    var explanation: String {
        switch self {
        case .accessibility:
            "That’s macOS’s name for this permission. YeeHaw uses it for two things: to see which icons are "
                + "in the menu bar, and to click a hidden icon for you when you pick it from the strip. It never "
                + "reads what’s in your windows or what you type."
        case .allowList:
            "macOS keeps the list of apps allowed in the menu bar in a protected file. YeeHaw hides an icon by "
                + "switching its app off there, and switches it back on when you quit YeeHaw. The file is "
                + "already selected in the window that opens: just click Allow."
        case .layoutFile:
            "macOS remembers the order of your menu bar icons in a second protected file. YeeHaw changes it "
                + "when you rearrange icons, and briefly to open a hidden icon next to its own. The file is "
                + "already selected: just click Allow."
        case .review:
            "These apps are switched off in System Settings → Menu Bar. Select any you’d like YeeHaw to look "
                + "after: they move to Hidden and open from YeeHaw’s strip. The rest stay off, and YeeHaw leaves "
                + "them alone."
        case .placeIcon:
            "YeeHaw’s hat goes right next to Control Center. You can move it later like any other icon: hold "
                + "Command and drag it."
        }
    }
}

extension OnboardingModel {
    /// A finished step's one-line result, shown at the end of its header line.
    func summary(of step: OnboardingStep) -> String? {
        guard isDone(step) else { return nil }
        switch step {
        case .accessibility, .allowList, .layoutFile: return AppPermission.grantedStatus
        case .review:
            if review.adoptedCount > 0 {
                return review.adoptedCount == 1 ? "1 app moved to Hidden" : "\(review.adoptedCount) apps moved to Hidden"
            }
            return reviewed ? "Left as they are" : "None switched off"
        case .placeIcon: return placement == .placed ? "Next to Control Center" : "Skipped"
        }
    }
}
