import SwiftUI
import ServiceManagement
import GarloCore

struct SettingsView: View {
    @Environment(AppStore.self) private var store
    @State private var launchAtLogin = false
    @State private var confirmClear = false

    var body: some View {
        @Bindable var store = store
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                group("Notifications", footer: "Only confirmed findings of severity slow or stalled ever notify. Suspected findings wait in the popover.") {
                    toggleRow("Storage transfers", hint: "Confirmed slow or stalled findings on a copy you are waiting for", $store.settings.notifyStorage)
                    toggleRow("Network", hint: "Link saturated, Wi-Fi limited, bufferbloat, packet loss", $store.settings.notifyNetwork)
                    toggleRow("CPU and thermal", hint: "Starved foreground app, throttling, low power mode", $store.settings.notifyCPU)
                    toggleRow("Memory", hint: "Pressure and swapping, with the largest consumer", $store.settings.notifyMemory)
                }
                group("Vestitel") {
                    toggleRow("Send red alerts to Vestitel", hint: "Only stalled findings and hardware that looks like it is failing land in your inbox", $store.settings.sendToVestitel)
                    toggleRow("Redact file paths", hint: "Keep volume names, drop paths, in events and exports", $store.settings.redactPaths)
                }
                group("Privileged helper") {
                    row("Not available yet", hint: "Adds per-file I/O attribution, root process file lists and SMART. Garlo diagnoses without it; the helper (M4) adds precision.") {
                        Button("Install") {}.disabled(true)
                    }
                }
                group("History") {
                    row("Keep history for", hint: "Findings and 1-minute rollups; the last 60 s stay at full resolution") {
                        Picker("", selection: $store.settings.historyDays) {
                            Text("7 days").tag(7)
                            Text("30 days").tag(30)
                            Text("90 days").tag(90)
                        }
                        .labelsHidden()
                        .frame(width: 110)
                    }
                    row("Latency anchor", hint: "The one host Garlo probes for round-trip time. Nothing else leaves this Mac.") {
                        TextField("host", text: $store.settings.latencyAnchor)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(size: 12, design: .monospaced))
                            .frame(width: 160)
                    }
                    row("Throughput test", hint: store.lastThroughput.map { r in r.error.map { "Failed: \($0)" } ?? "\(Units.rate(r.bytesPerSec)) at \(Units.clock(r.at))" } ?? "Opt-in 5 s download against this URL. Never runs on its own.") {
                        HStack(spacing: 6) {
                            TextField("URL", text: $store.settings.throughputURL)
                                .textFieldStyle(.roundedBorder)
                                .font(.system(size: 11, design: .monospaced))
                                .frame(width: 160)
                            if store.throughputRunning {
                                ProgressView().controlSize(.small)
                            } else {
                                Button("Run") { store.runThroughputTest() }
                            }
                        }
                    }
                    row("Clear history", hint: "Findings, rollups and learned baselines") {
                        if confirmClear {
                            HStack(spacing: 6) {
                                Button("Clear") { store.clearHistory(); confirmClear = false }
                                Button("Cancel") { confirmClear = false }
                            }
                        } else {
                            Button("Clear…") { confirmClear = true }.disabled(store.history.isEmpty)
                        }
                    }
                }
                group("Garlo itself") {
                    row("Overhead now", hint: "Measured by Garlo's own samplers, judged by the same rules") {
                        let o = store.engine.overhead
                        Text("\(String(format: "%.1f", o.cpuFraction * 100))% CPU · \(Units.bytes(Double(o.memoryBytes)))")
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundStyle(o.cpuFraction < 0.01 && o.memoryBytes < 60_000_000 ? Color.ok : Color.warn)
                    }
                    row("Last sample took", hint: "Budget: under 20 ms per second") {
                        Text(String(format: "%.1f ms", store.engine.lastSampleCost * 1000))
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                    row("Launch at login", hint: nil) {
                        Toggle("", isOn: $launchAtLogin)
                            .toggleStyle(.switch)
                            .labelsHidden()
                            .onChange(of: launchAtLogin) { _, on in
                                do { on ? try SMAppService.mainApp.register() : try SMAppService.mainApp.unregister() }
                                catch { launchAtLogin = SMAppService.mainApp.status == .enabled }
                            }
                    }
                    toggleRow("Check for updates daily", hint: "Version \(store.currentAppVersion ?? "dev") · from GitHub releases; only builds signed with Garlo's release key are installed", $store.settings.autoUpdateEnabled)
                    row("Updates", hint: store.updateStatus.isEmpty ? (store.lastUpdateCheck.map { "Last checked \(Units.clock($0))" } ?? "Not checked yet") : store.updateStatus) {
                        if store.stagedUpdatePath != nil {
                            Button("Install Now") { store.installStagedUpdateIfIdle(force: true) }
                        } else {
                            Button("Check Now") { store.startUpdateCheck(manual: true) }
                                .disabled(store.updaterTask != nil || !store.updaterAvailable)
                        }
                    }
                }
            }
            .padding(16)
        }
        .frame(width: 520, height: 720)
        .background(Color.codeBackground)
        .onAppear { launchAtLogin = SMAppService.mainApp.status == .enabled }
    }

    // MARK: Pieces

    @ViewBuilder
    private func group<Content: View>(_ title: String, footer: String? = nil, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            SectionLabel(title)
            VStack(spacing: 0) {
                content()
            }
            .background(Color.surface, in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.hairline, lineWidth: 0.5))
            if let footer {
                Text(footer).font(.system(size: 11)).foregroundStyle(.secondary).padding(.horizontal, 2)
            }
        }
    }

    private func toggleRow(_ label: String, hint: String?, _ binding: Binding<Bool>) -> some View {
        row(label, hint: hint) {
            Toggle("", isOn: binding).toggleStyle(.switch).labelsHidden()
        }
        .contentShape(Rectangle())
        .onTapGesture { binding.wrappedValue.toggle() }
    }

    private func row<Trailing: View>(_ label: String, hint: String?, @ViewBuilder trailing: () -> Trailing) -> some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(label).font(.system(size: 13))
                if let hint {
                    Text(hint).font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer()
            trailing()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .frame(minHeight: 44)
        .overlay(alignment: .bottom) { Divider().padding(.leading, 12) }
    }
}
