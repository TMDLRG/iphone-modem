import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var controller: TetherController

    var body: some View {
        NavigationView {
            List {
                Section {
                    HStack(spacing: 12) {
                        Circle()
                            .fill(statusColor)
                            .frame(width: 12, height: 12)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(controller.isRunning ? "Tethering on" : "Tethering off")
                                .font(.headline)
                            Text(controller.serverStatus)
                                .font(.subheadline)
                                .foregroundColor(.secondary)
                        }
                    }
                    .padding(.vertical, 4)

                    Button(controller.isRunning ? "Stop tethering" : "Start tethering") {
                        if controller.isRunning {
                            controller.stop()
                        } else {
                            controller.start()
                        }
                    }
                }

                Section(header: Text("Cellular")) {
                    Label(
                        controller.cellularDetail,
                        systemImage: controller.cellularAvailable
                            ? "antenna.radiowaves.left.and.right"
                            : "antenna.radiowaves.left.and.right.slash"
                    )
                    .foregroundColor(controller.cellularAvailable ? .primary : .red)
                }

                Section(header: Text("Traffic")) {
                    row("Open connections", "\(controller.stats.activeSessions)")
                    row("Requests", "\(controller.stats.totalRequests)")
                    row("Uploaded", bytes(controller.stats.bytesUp))
                    row("Downloaded", bytes(controller.stats.bytesDown))
                }

                Section(
                    header: Text("Options"),
                    footer: Text("Plays silent audio so iOS keeps Modem running while the screen is locked or you use other apps. If you turn this off, the screen stays on while tethering.")
                ) {
                    Toggle("Keep running when locked", isOn: $controller.keepRunningInBackground)
                }

                Section(header: Text("On the PC")) {
                    Text("1. Plug this iPhone into the PC with a USB cable. Unlock it and tap Trust if asked.")
                    Text("2. On the PC, double-click \"Start Modem.cmd\" in the Modem folder.")
                    Text("3. Leave this app running. All PC traffic goes out over cellular data only.")
                }
                .font(.footnote)

                Section(header: Text("Recent events")) {
                    if controller.events.isEmpty {
                        Text("Nothing yet")
                            .foregroundColor(.secondary)
                    }
                    ForEach(Array(controller.events.enumerated()), id: \.offset) { item in
                        Text(item.element)
                            .font(.system(.caption, design: .monospaced))
                    }
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("Modem")
        }
        .navigationViewStyle(.stack)
        .onAppear {
            controller.autoStart()
        }
    }

    private var statusColor: Color {
        if !controller.isRunning { return .gray }
        if controller.serverHealthy && controller.cellularAvailable { return .green }
        return .orange
    }

    private func row(_ title: String, _ value: String) -> some View {
        HStack {
            Text(title)
            Spacer()
            Text(value)
                .foregroundColor(.secondary)
                .monospacedDigit()
        }
    }

    private func bytes(_ count: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(clamping: count), countStyle: .file)
    }
}
