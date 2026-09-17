import SwiftUI

@main
struct LensScanApp: App {
    @State private var store = ScanStore()

    var body: some Scene {
        WindowGroup {
            LibraryView()
                .environment(store)
        }
    }
}
