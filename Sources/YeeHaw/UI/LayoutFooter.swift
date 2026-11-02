import SwiftUI

/// The Layout window's footer, like a document window's: what Apply would do, then Revert and
/// Apply (the default button), both off while the draft matches the menu bar. While Apply runs it
/// shows its progress instead.
struct LayoutFooter: View {
    /// Its height with one line of summary, kept free below the scrolling content.
    static let height: CGFloat = 52

    let model: LayoutModel
    let spacing: SpacingModel

    var body: some View {
        VStack(spacing: 0) {
            Divider()
            HStack(spacing: 12) {
                status
                Spacer(minLength: 12)
                Button("Revert") { model.revert() }
                    .disabled(!canCommit)
                    .help("Puts the rows and the spacing back as they are")
                    .accessibilityLabel("Revert changes")
                Button("Apply") { model.apply() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canCommit)
                    .help("Applies your changes to the menu bar")
                    .accessibilityLabel("Apply changes")
            }
            .font(.callout)
            .padding(.horizontal, LayoutMetrics.windowPadding)
            .padding(.vertical, 14)
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Changes")
        }
    }

    private var canCommit: Bool { model.isDirty && !model.editsLocked }

    @ViewBuilder
    private var status: some View {
        if model.applying || spacing.isApplying {
            HStack(spacing: 6) {
                ProgressView()
                    .controlSize(.small)
                Text(progress)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .lineLimit(1)
            }
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.updatesFrequently)
        } else if model.isDirty {
            VStack(alignment: .leading, spacing: 2) {
                Text(model.summary)
                    .lineLimit(1)
                if !model.restarting.isEmpty {
                    Text(SpacingSection.restartNote(model.restarting))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            // Read as one line of the footer, before its buttons.
            .accessibilityElement(children: .combine)
        }
    }

    /// "Applying…" for the layout, then the spacing's own progress.
    private var progress: String {
        guard let step = spacing.progress else { return "Applying…" }
        return step.count == 0 ? "Saving the spacing…" : "Restarting \(step.name)… (\(step.index + 1) of \(step.count))"
    }
}
