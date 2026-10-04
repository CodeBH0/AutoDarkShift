import SwiftUI
import UIKit

@MainActor
struct ControlView: View {
    @StateObject private var controller = AppComposition.makeController()
    @Environment(\.scenePhase) private var scenePhase
    @State private var showingExport = false

    var body: some View {
        TabView {
            NavigationStack {
                DashboardView(controller: controller)
            }
            .tabItem { Label("仪表", systemImage: "rectangle.grid.2x2") }

            NavigationStack {
                KeepAliveView(controller: controller)
            }
            .tabItem { Label("保活", systemImage: "bolt.heartbeat") }

            NavigationStack {
                InformationView()
            }
            .tabItem { Label("信息", systemImage: "info.circle") }
        }
        .overlay {
            if let pipService = controller.pipService {
                PiPSourceHost(service: pipService)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .allowsHitTesting(false)
            }
        }
        .onAppear { controller.setScenePhase(scenePhase) }
        .onChange(of: scenePhase) { _, phase in controller.setScenePhase(phase) }
        .onChange(of: controller.exportURLs) { _, urls in showingExport = !urls.isEmpty }
        .sheet(isPresented: $showingExport, onDismiss: { controller.exportURLs = [] }) {
            if !controller.exportURLs.isEmpty { ShareSheet(urls: controller.exportURLs) }
        }
    }
}
