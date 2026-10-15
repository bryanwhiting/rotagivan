import AppKit
import SwiftUI

private func usageDuration(_ seconds: Double) -> String {
    let minutes = Int(max(0, seconds) / 60)
    return minutes >= 60 ? "\(minutes / 60)h \(minutes % 60)m" : (minutes > 0 ? "\(minutes)m" : "<1m")
}

struct LocalUsageMenuSection: View {
    @ObservedObject private var activity = LocalUsageTracker.shared
    @Environment(\.openWindow) private var openWindow
    var body: some View {
        Button {
            activity.refresh(); openWindow(id: "activity"); NSApp.activate(ignoringOtherApps: true)
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "chart.bar.xaxis").foregroundStyle(.teal)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Activity today").font(.caption.weight(.semibold))
                    Text(activity.enabled ? activity.status : "Local tracking is off").font(.caption2).foregroundStyle(.secondary)
                }
                Spacer()
                Text(activity.today.total > 0 ? usageDuration(activity.today.total) : "View…").font(.caption.monospacedDigit())
            }.contentShape(Rectangle())
        }.buttonStyle(.plain)
        .onAppear { activity.refresh() }
    }
}

struct LocalUsageView: View {
    @ObservedObject private var activity: LocalUsageTracker
    init(activity: LocalUsageTracker = .shared) { self.activity = activity }
    @State private var showPrivacy = false
    @State private var confirmClear = false
    @State private var section = "Apps"
    @State private var includeUnused = false
    private var commandRows: [UsageActionTotal] {
        if section == "Hotkeys" { return activity.hotkeys }
        return includeUnused ? UsageDatabase.includingUnused(activity.actions, catalogue: activity.catalogue) : activity.actions
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 5) {
                    Text("Your time, on this Mac").font(.system(size: 25, weight: .semibold, design: .rounded))
                    Label("Private local history · never synced or uploaded", systemImage: "desktopcomputer").font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
                Toggle("Screen Time", isOn: Binding(get: { activity.enabled }, set: activity.setEnabled)).toggleStyle(.switch)
                    .accessibilityIdentifier("activity-tracking-toggle")
            }.padding(24)
            Divider()
            if !activity.enabled {
                Label("Opt in to Screen Time settings to see computer usage insights", systemImage: "hand.raised")
                    .font(.callout).foregroundStyle(.secondary).padding(.horizontal, 24).padding(.top, 16)
            }
            HStack(spacing: 12) {
                Button { changeDay(-1) } label: { Image(systemName: "chevron.left") }.help("Previous day")
                DatePicker("Day", selection: $activity.day, in: ...Date(), displayedComponents: .date).labelsHidden()
                Button { changeDay(1) } label: { Image(systemName: "chevron.right") }
                    .disabled(Calendar.current.isDateInToday(activity.day)).help("Next day")
                Spacer()
                VStack(alignment: .trailing, spacing: 3) {
                    if section == "Apps" {
                        Text(activity.report.total > 0 ? usageDuration(activity.report.total) : "0m").font(.title2.weight(.semibold).monospacedDigit())
                        Text("\(activity.report.switches) app switches").font(.caption).foregroundStyle(.secondary)
                    } else {
                        Text("\(commandRows.reduce(0) { $0 + $1.count })").font(.title2.weight(.semibold).monospacedDigit())
                        Text(section == "Actions" ? "Rota action invocations" : "Rota hotkey triggers").font(.caption).foregroundStyle(.secondary)
                    }
                }
            }.padding(.horizontal, 24).padding(.vertical, 16)
            HStack {
                Picker("Usage", selection: $section) {
                    Text("Apps").tag("Apps"); Text("Actions").tag("Actions"); Text("Hotkeys").tag("Hotkeys")
                }.pickerStyle(.segmented).frame(maxWidth: 350)
                Spacer()
                if section == "Actions" { Toggle("Include unused", isOn: $includeUnused).help("Include configured actions with no uses on this day") }
            }.padding(.horizontal, 24).padding(.bottom, 12)
            if let error = activity.error {
                Label(error, systemImage: "exclamationmark.triangle").font(.callout).foregroundStyle(.orange).padding(.horizontal, 24)
            }
            if section != "Apps" {
                VStack(alignment: .leading, spacing: 0) {
                    if commandRows.isEmpty {
                        Text(activity.enabled ? "No \(section.lowercased()) recorded for this day." : "Opt in to Screen Time settings to see computer usage insights")
                            .foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity).padding(24)
                    } else {
                        List(commandRows) { item in
                            HStack(spacing: 12) {
                                Image(systemName: section == "Hotkeys" ? "keyboard" : "bolt.circle").foregroundStyle(item.count == 0 ? Color.secondary : Color.teal)
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(item.name).font(.callout)
                                    if let last = item.lastUsed { Text("Last used " + last.formatted(date: .omitted, time: .shortened)).font(.caption).foregroundStyle(.secondary) }
                                    else { Text("Not used this day").font(.caption).foregroundStyle(.secondary) }
                                }
                                Spacer()
                                Text("\(item.count)").font(.callout.monospacedDigit()).foregroundStyle(item.count == 0 ? Color.secondary : Color.primary)
                            }.padding(.vertical, 6)
                        }.listStyle(.inset)
                    }
                    Text("Only Rota commands and Rota-handled hotkeys. Counts are invocations, not success confirmations. General typing is never recorded.")
                        .font(.caption).foregroundStyle(.secondary).padding(.horizontal, 24).padding(.vertical, 12)
                }
            } else if activity.report.apps.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "chart.bar.xaxis").font(.system(size: 36, weight: .light)).foregroundStyle(.teal)
                    Text(activity.enabled ? "A fresh start" : "See where your day goes").font(.title3.weight(.semibold))
                    Text(activity.enabled ? "Active app time will appear here as you work. No past Screen Time history is imported." : "Opt in to Screen Time settings to see computer usage insights")
                        .foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 360)
                }.frame(maxWidth: .infinity, maxHeight: .infinity).padding(24)
            } else {
                List(activity.report.apps) { app in
                    if app.domains.isEmpty { appRow(app) }
                    else {
                        DisclosureGroup { ForEach(app.domains) { domain in
                            HStack {
                                Image(systemName: "globe").foregroundStyle(.secondary)
                                Text(domain.host).textSelection(.enabled)
                                Spacer()
                                Text(usageDuration(domain.seconds)).monospacedDigit().foregroundStyle(.secondary)
                            }.font(.callout).padding(.vertical, 5).padding(.leading, 30)
                        } } label: { appRow(app) }
                    }
                }.listStyle(.inset).accessibilityIdentifier("activity-app-list")
            }
            Divider()
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Circle().fill(activity.enabled && activity.error == nil ? Color.teal : Color.secondary).frame(width: 6, height: 6)
                    Text(activity.status).font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("Privacy & controls", systemImage: "slider.horizontal.3") { showPrivacy.toggle() }
                }
                if showPrivacy {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Rota Screen Time is optional and local to this Mac. The switch above enables both active-app time and Rota command statistics. Turning it off stops collection and history-based ranking; retained history can still be viewed or deleted.")
                            .font(.caption).foregroundStyle(.secondary)
                        Toggle("Include active Chrome website domains", isOn: Binding(get: { activity.websites }, set: activity.setWebsites))
                        HStack {
                            Text("Optional Automation access. Public tabs only; no page titles, paths, or content. Other browsers are app-only.")
                                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                            Button("Allow Chrome access…") { activity.allowChrome() }
                        }
                        Toggle("Personalize local search using app history", isOn: Binding(get: { activity.personalize }, set: activity.setPersonalize))
                        Text("Uses recent app frequency and app-switch patterns on this Mac. Exact-name matches stay first. Usage history is never sent to voice models.")
                            .font(.caption).foregroundStyle(.secondary)
                        Text("After 15 minutes without input, the idle stretch is removed back to the last input. Sleep and locked-screen time are excluded. Website changes are sampled about every 5 seconds.")
                            .font(.caption).foregroundStyle(.secondary)
                        HStack {
                            Button("Show local database") { NSWorkspace.shared.activateFileViewerSelecting([LocalUsageTracker.storageURL]) }
                            Spacer()
                            Button("Delete all activity…", role: .destructive) { confirmClear = true }
                        }
                        Text("Stored in a private-permission local SQLite file, excluded from backups. It is not separately encrypted by Rota; use FileVault for disk encryption. History stays until you delete it.")
                            .font(.caption2).foregroundStyle(.secondary)
                    }.padding(14).background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 10))
                }
            }.padding(20)
        }
        .frame(minWidth: 620, minHeight: 580)
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear { activity.start(); activity.refresh() }
        .confirmationDialog("Delete all activity on this Mac?", isPresented: $confirmClear, titleVisibility: .visible) {
            Button("Delete all activity", role: .destructive) { activity.clearHistory() }
        } message: { Text("Daily history and search predictions will be removed. Settings, bookmarks, and other Macs are unchanged.") }
    }
    private func changeDay(_ amount: Int) {
        if let date = Calendar.current.date(byAdding: .day, value: amount, to: activity.day) { activity.day = min(Date(), date) }
    }
    private func appRow(_ app: UsageAppTotal) -> some View {
        HStack(spacing: 12) {
            Group {
                if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: app.id) {
                    Image(nsImage: NSWorkspace.shared.icon(forFile: url.path)).resizable()
                } else { Image(systemName: "app.dashed").resizable().foregroundStyle(.secondary) }
            }.frame(width: 28, height: 28)
            VStack(alignment: .leading, spacing: 6) {
                Text(app.name).font(.callout.weight(.medium))
                GeometryReader { geometry in
                    Capsule().fill(Color.teal.opacity(0.16)).overlay(alignment: .leading) {
                        Capsule().fill(Color.teal).frame(width: geometry.size.width * min(1, app.seconds / max(1, activity.report.total)))
                    }
                }.frame(height: 4)
            }
            Spacer(minLength: 16)
            Text(usageDuration(app.seconds)).font(.callout.monospacedDigit()).frame(width: 72, alignment: .trailing)
        }.padding(.vertical, 9)
    }
}
