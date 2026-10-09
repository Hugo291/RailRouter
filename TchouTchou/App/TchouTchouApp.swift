import SwiftUI

@main
struct TchouTchouApp: App {
    @StateObject private var modelManager = ModelManager()

    init() {
        if CommandLine.arguments.contains("--serve-gateway") {
            let args = CommandLine.arguments
            let index = args.firstIndex(of: "--port")
            let port = index.flatMap { $0 + 1 < args.count ? UInt16(args[$0 + 1]) : nil } ?? GatewayController.port
            do {
                let server = UnifiedGateway(port: port)
                try server.start()
                withExtendedLifetime(server) { dispatchMain() }
            } catch {
                fputs("TchouTchou endpoint : \(error.localizedDescription)\n", stderr)
                Foundation.exit(1)
            }
        }
        // Mode tests : `TchouTchou --run-tests` → exécute le mini-harness
        // (TchouTchou/Tests) et quitte. Permet `make test` sans Xcode.
        if CommandLine.arguments.contains("--run-tests") {
            let ok = runTestSuite()
            Foundation.exit(ok ? 0 : 1)
        }
        // Plein écran : garder la barre d'outils (recherche, actions) visible au lieu de l'auto-masquer.
        NotificationCenter.default.addObserver(forName: NSWindow.willEnterFullScreenNotification, object: nil, queue: .main) { _ in
            NSApp.presentationOptions = [.fullScreen, .autoHideMenuBar, .autoHideDock]
        }
    }
    
    var body: some Scene {
        WindowGroup {
            ContentView()
                .id(modelManager.language)
                .environment(\.locale, Locale(identifier: modelManager.language.localeIdentifier))
                .environmentObject(modelManager)
                .frame(minWidth: 1000, minHeight: 720)
        }
        .windowToolbarStyle(.unified)
        .commands {
            CommandMenu(L("Navigation")) {
                Button(L("Modèles")) { modelManager.selectedSection = .models }
                    .keyboardShortcut("1", modifiers: .command)
                Button(L("En mémoire")) { modelManager.selectedSection = .memory }
                    .keyboardShortcut("2", modifiers: .command)
                Button(L("Découvrir")) { modelManager.selectedSection = .discover }
                    .keyboardShortcut("3", modifiers: .command)
                Button(L("Endpoint")) { modelManager.selectedSection = .gateway }
                    .keyboardShortcut("4", modifiers: .command)
            }
        }
    }
}
