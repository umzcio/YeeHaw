import AppKit
import SwiftUI
import UniformTypeIdentifiers
import YeeHawCore

/// An app switched off in System Settings → Menu Bar by the user (off, and not in the journal).
struct SwitchedOffApp: Identifiable, Equatable {
    let id: BundleID
    let name: String
    /// False for an Allow-list entry whose app is no longer on this Mac; it's named by bundle ID.
    var isInstalled = true
    var ticked = false
}

/// Where the switched-off apps come from and where ticked ones go.
@MainActor
protocol SwitchedOffSource: AnyObject {
    /// `MenuBarController.userOwnedOff()`, with display names.
    func switchedOff() throws -> [SwitchedOffApp]
    /// `MenuBarController.adopt`: the apps go into Hidden and the journal.
    func adopt(_ ids: [BundleID]) async throws
}

/// The review of switched-off apps (spec "First run" step 4), shared by onboarding and Settings'
/// "Review Switched-Off Apps…". Every app starts unticked; only ticked apps are adopted, and
/// unticked ones stay the user's: off, and invisible to YeeHaw.
@MainActor
@Observable
final class SwitchedOffReviewModel {
    private(set) var apps: [SwitchedOffApp] = []
    /// Whether the list has been read; an unreadable Allow list leaves it unloaded.
    private(set) var loaded = false
    private(set) var isCommitting = false
    private(set) var error: String?
    /// How many apps the last commit moved to Hidden.
    private(set) var adoptedCount = 0

    @ObservationIgnored private let source: SwitchedOffSource

    /// What the list well says when the Allow list can't be read; each place adds what to do.
    static let unreadableMessage = "YeeHaw couldn’t read the menu bar’s Allow list."

    init(source: SwitchedOffSource) {
        self.source = source
    }

    /// Reads the list afresh, with nothing ticked: installed apps by name, then any that aren't
    /// installed any more.
    func reload() {
        do {
            apps = try source.switchedOff()
                .map { SwitchedOffApp(id: $0.id, name: $0.name, isInstalled: $0.isInstalled) }
                .sorted {
                    if $0.isInstalled != $1.isInstalled { return $0.isInstalled }
                    return $0.name.localizedStandardCompare($1.name) == .orderedAscending
                }
            loaded = true
            error = nil
        } catch {
            apps = []
            loaded = false
            self.error = Self.unreadableMessage
        }
    }

    func setTicked(_ ticked: Bool, for id: BundleID) {
        guard let index = apps.firstIndex(where: { $0.id == id }) else { return }
        apps[index].ticked = ticked
    }

    /// Select All / Select None.
    func setAllTicked(_ ticked: Bool) {
        for index in apps.indices { apps[index].ticked = ticked }
    }

    var tickedIDs: [BundleID] { apps.filter(\.ticked).map(\.id) }
    var allTicked: Bool { !apps.isEmpty && apps.allSatisfy(\.ticked) }

    /// The line above the list, while there's one.
    var countTitle: String? {
        switch apps.count {
        case 0: nil
        case 1: "1 app is switched off"
        case let n: "\(n) apps are switched off"
        }
    }

    /// The commit button's title while something is ticked, else nil.
    var commitTitle: String? {
        switch tickedIDs.count {
        case 0: nil
        case 1: "Move 1 App to Hidden"
        case let n: "Move \(n) Apps to Hidden"
        }
    }

    /// Adopts the ticked apps, if any. Returns false (keeping the ticks) when that fails.
    func commit() async -> Bool {
        let ids = tickedIDs
        guard !ids.isEmpty else {
            adoptedCount = 0
            return true
        }
        isCommitting = true
        defer { isCommitting = false }
        do {
            try await source.adopt(ids)
        } catch {
            self.error = "Couldn’t move the apps to Hidden. Check YeeHaw’s permissions in Settings."
            return false
        }
        adoptedCount = ids.count
        reload()
        return true
    }
}

/// The switched-off apps as a checklist in a rounded well, scrolling past `visibleRows`, under a
/// line that counts them and selects all or none.
struct SwitchedOffList: View {
    static let rowHeight: CGFloat = 30
    static let visibleRows = 9
    static let horizontalPadding: CGFloat = 12
    /// Where the app icons start: past the padding and the checkbox with its gap.
    static let iconInset: CGFloat = horizontalPadding + 22

    let model: SwitchedOffReviewModel
    /// The line under an unreadable list's message: what the user can do from here.
    let unreadableAdvice: String
    /// Try Again on an unreadable list.
    let retry: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let count = model.countTitle {
                header(count)
            }
            list
        }
    }

    private func header(_ count: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(count)
                .font(.callout.weight(.medium))
                .foregroundStyle(.secondary)
            Spacer(minLength: 8)
            Button(model.allTicked ? "Select None" : "Select All") {
                model.setAllTicked(!model.allTicked)
            }
            .buttonStyle(.link)
            .font(.callout)
            .disabled(model.isCommitting)
            .accessibilityHint(model.allTicked ? "Unticks every app" : "Ticks every app")
        }
        .padding(.horizontal, 2)
    }

    private var list: some View {
        let shape = RoundedRectangle(cornerRadius: 10, style: .continuous)
        return Group {
            if !model.loaded {
                unreadable
            } else if model.apps.isEmpty {
                Text("No apps are switched off.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: Self.rowHeight + 8)
            } else if model.apps.count > Self.visibleRows {
                ScrollView(.vertical) { rows }
                    .scrollIndicators(.visible)
                    // Cut through the middle of the next row, so the list plainly goes on
                    // (overlay scrollers stay hidden until the list is scrolled).
                    .frame(height: (Self.rowHeight + 1) * CGFloat(Self.visibleRows) + Self.rowHeight / 2)
            } else {
                rows
            }
        }
        .wellBox(shape)
        .clipShape(shape)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Switched-off apps")
    }

    /// The Allow list couldn't be read: what happened, what to do, and a way to read it again.
    private var unreadable: some View {
        VStack(spacing: 10) {
            VStack(spacing: 3) {
                Text(model.error ?? SwitchedOffReviewModel.unreadableMessage)
                    .font(.callout.weight(.medium))
                Text(unreadableAdvice)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityElement(children: .combine)
            Button("Try Again", action: retry)
                .accessibilityHint("Reads the menu bar’s Allow list again")
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 16)
        .frame(maxWidth: .infinity)
    }

    private var rows: some View {
        VStack(spacing: 0) {
            ForEach(Array(model.apps.enumerated()), id: \.element.id) { index, app in
                if index > 0 {
                    Divider()
                        .padding(.leading, Self.iconInset)
                        .padding(.trailing, Self.horizontalPadding)
                }
                Toggle(isOn: Binding(get: { app.ticked }, set: { model.setTicked($0, for: app.id) })) {
                    HStack(spacing: 8) {
                        Image(nsImage: AppIdentity.icon(for: app.id))
                            .resizable()
                            .interpolation(.high)
                            .frame(width: 18, height: 18)
                            .accessibilityHidden(true)
                        Text(app.name)
                            .lineLimit(1)
                        Spacer(minLength: 8)
                        if !app.isInstalled {
                            Text("Not installed")
                                .font(.callout)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .toggleStyle(.checkbox)
                .padding(.horizontal, Self.horizontalPadding)
                .frame(height: Self.rowHeight)
                .accessibilityHint("Ticked apps move to Hidden")
            }
        }
        .disabled(model.isCommitting)
    }
}

/// Display names and icons of apps by bundle ID.
@MainActor
enum AppIdentity {
    private static var icons: [BundleID: NSImage] = [:]

    /// The running app's name, else its bundle's, else the bundle ID.
    static func name(of id: BundleID) -> String {
        StatusItemController.name(of: id)
    }

    static func isInstalled(_ id: BundleID) -> Bool {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) != nil
    }

    /// The app's Finder icon, or the generic app icon when it isn't installed.
    static func icon(for id: BundleID) -> NSImage {
        if let cached = icons[id] { return cached }
        let icon = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id)
            .map { NSWorkspace.shared.icon(forFile: $0.path) }
            ?? NSWorkspace.shared.icon(for: .applicationBundle)
        icons[id] = icon
        return icon
    }
}
