import SwiftUI

/// Garde l'app vivante quand on ferme la fenêtre : un clic sur le Dock la rouvre.
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    /// Clic sur le Dock / `open` sans fenêtre visible : SwiftUI garde la fenêtre fermée masquée, on la réaffiche.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !Self.hasWindowOnActiveSpace { Self.showMainWindow() }
        return true
    }

    /// Fermer la fenêtre masque l'app : le Dock n'envoie aucun événement à une app active sans fenêtre,
    /// alors qu'il réactive toujours une app masquée (→ `applicationDidBecomeActive` réaffiche la fenêtre).
    func applicationDidFinishLaunching(_ notification: Notification) {
        NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: nil, queue: .main) { note in
            guard let window = note.object as? NSWindow, !(window is NSPanel), window.isVisible else { return }
            DispatchQueue.main.async { NSApp.hide(nil) }
        }
    }

    /// Le Dock n'envoie pas toujours « reopen » : une activation sans fenêtre visible suffit à la réafficher.
    func applicationDidBecomeActive(_ notification: Notification) {
        if !Self.hasWindowOnActiveSpace { Self.showMainWindow() }
    }

    /// `isVisible` reste vrai pour une fenêtre d'un autre Space : il faut aussi qu'elle soit sur le Space courant.
    static var hasWindowOnActiveSpace: Bool {
        NSApp.windows.contains { !($0 is NSPanel) && $0.isVisible && $0.isOnActiveSpace }
    }

    static func showMainWindow() {
        // Une fenêtre SwiftUI fermée n'est plus « main » (canBecomeMain == false) : on prend la première fenêtre non-panneau.
        guard let window = NSApp.windows.first(where: { !($0 is NSPanel) }) else { return }
        if window.isMiniaturized { window.deminiaturize(nil) }
        window.collectionBehavior.insert(.moveToActiveSpace)
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }
}

@main
struct TchouTchouApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
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
        Window("TchouTchou", id: "main") {
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
