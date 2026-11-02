import YeeHawCore

extension MenuBarController {
    /// The controller wired to this Mac: both protected files through their grants, the
    /// Accessibility reader, YeeHaw's defaults and real sleeps.
    static func live(grants: FileGrantStore) -> MenuBarController {
        MenuBarController(
            allowFile: GrantedPreferencesFile(file: .allowList, grants: grants),
            positionFile: GrantedPreferencesFile(file: .positions, grants: grants),
            reader: AXMenuBarReader(), store: DefaultsStateStore(), sleeper: TaskSleeper())
    }
}
