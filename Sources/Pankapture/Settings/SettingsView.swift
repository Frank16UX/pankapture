import SwiftUI

struct SettingsView: View {
    var body: some View {
        TabView {
            Tab("General", systemImage: "gearshape") {
                GeneralSettingsView()
            }
            Tab("Shortcuts", systemImage: "command") {
                ShortcutsSettingsView()
            }
            Tab("Permissions", systemImage: "lock.shield") {
                PermissionsSettingsView()
            }
        }
        .scenePadding()
        .frame(width: 520)
        .frame(minHeight: 380)
        .onAppear {
            // Accessory apps don't activate on their own; bring Settings forward.
            NSApp.activate()
        }
    }
}
