import M3MCPCore
import SwiftUI

struct ContentView: View {
    @ObservedObject var model: AppModel

    var selectedService: ServiceHealth? {
        model.services.first { $0.name == model.selectedServiceName } ?? model.services.first
    }

    var body: some View {
        NavigationSplitView {
            SidebarView(
                services: model.services,
                selectedServiceName: $model.selectedServiceName
            )
        } detail: {
            DetailView(
                service: selectedService,
                activity: model.activity,
                permissionItems: model.permissionItems,
                permissionMessage: model.permissionMessage,
                serverState: model.serverState,
                authenticationSummary: model.authenticationSummary,
                securityPolicy: model.securityPolicy,
                onPermissions: {
                    Task {
                        await model.requestPermissions()
                    }
                },
                onPermissionRefresh: {
                    Task {
                        await model.refreshPermissions()
                    }
                },
                onOpenPermissionSettings: model.openPermissionSettings,
                onStart: model.startIfNeeded,
                onRestart: model.restart,
                onStop: model.stop
            )
        }
        .task {
            model.startIfNeeded()
            await model.refreshPermissions()
        }
    }
}
