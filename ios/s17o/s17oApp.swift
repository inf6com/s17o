import SwiftUI

@main
struct s17oApp: App {
    @StateObject private var model = AppModel()
    @StateObject private var browser = BrowserController()

    var body: some Scene {
        WindowGroup {
            if model.isSetupComplete {
                ContentView()
                    .environmentObject(model)
                    .environmentObject(browser)
                    .onAppear {
                        model.attach(browserController: browser)
                        if let url = URL(string: "https://www.mlb.tv") {
                            browser.navigate(to: url)
                        }
                    }
            } else {
                OnboardingView()
                    .environmentObject(model)
            }
        }
    }
}
