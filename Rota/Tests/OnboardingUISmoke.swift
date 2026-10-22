import AppKit
import SwiftUI

/// Renders every welcome-tour step with injected state: no permission prompts,
/// no live input, no network, no Keychain. Checks identifiers, live status,
/// navigation, persistence and the pack import.
@main struct OnboardingUISmoke {
    @MainActor static func main() throws {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.accessory)
        NSApp.accessibilitySetValue(true, forAttribute: NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface"))
        let output = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        let suite = "Rota.OnboardingUISmoke.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(true, forKey: "migration.rota.v1")
        let store = SettingsStore(defaults: defaults)
        store.settings.enabled = false
        store.settings.appExplorer = AppExplorerSettings()
        let hid = NavigatorHIDManager(store: store, inputPreferences: defaults) // Never starts input.
        let sync = SettingsSync(store: store, hid: hid, defaults: defaults, server: "https://fixture.test",
            credentials: SyncCredentials(read: { _ in fatalError("The tour must not touch the Keychain") },
                save: { _, _ in fatalError("No credential writes") }, remove: { _ in fatalError("No credential deletes") }),
            transport: { _ in fatalError("No network") })

        // Injected state. Nothing here asks macOS for anything.
        var trusted = false
        var inputMonitoring: Bool? = nil
        var hudVisible = false
        var accessibilityOpens = 0, inputMonitoringOpens = 0
        var appliedDevices: [GestureDevice] = []
        var importedPacks: [[String]] = []
        let packs = MacroPack.builtInPacks(directory: URL(fileURLWithPath: "Rota/MacroPacks", isDirectory: true))
        let names = Set(packs.map(\.name))
        precondition(OnboardingEnvironment.starterPackNames.isSubset(of: names), "Starter packs ship in the bundle: \(names)")
        let starterIDs = Set(packs.filter { OnboardingEnvironment.starterPackNames.contains($0.name) }.map(\.id))
        var environment = OnboardingEnvironment()
        environment.accessibilityTrusted = { trusted }
        environment.inputMonitoringGranted = { inputMonitoring }
        environment.openAccessibilitySettings = { accessibilityOpens += 1; return accessibilityOpens < 2 }
        environment.openInputMonitoringSettings = { inputMonitoringOpens += 1; return true }
        environment.hudVisible = { hudVisible }
        environment.applyDevice = { appliedDevices.append($0) }
        environment.builtInPacks = packs
        environment.importPacks = { chosen in
            importedPacks.append(chosen.map(\.name))
            return OnboardingEnvironment.importPacks(chosen, into: store)
        }
        environment.appURL = nil
        environment.hudShortcut = OnboardingEnvironment.hudShortcut(store.settings)
        environment.gestureSummary = OnboardingEnvironment.gestureSummary(store.settings)
        environment.pollInterval = 3600 // Tests drive refresh() by hand.
        precondition(environment.hudShortcut == "Option+Space", "Default launcher label: \(environment.hudShortcut)")
        precondition(environment.gestureSummary.count == 3 && environment.gestureSummary[0].gesture == "One-finger tap")

        precondition(OnboardingModel.shouldPresent(defaults: defaults), "A fresh install shows the tour")
        let model = OnboardingModel(defaults: defaults, environment: environment)
        var dismissed = 0
        model.onDismiss = { dismissed += 1 }
        precondition(model.step == .welcome && model.isFirst && !model.isLast)
        precondition(model.selectedPackIDs == starterIDs && starterIDs.count == 3, "Only the starter packs start checked: \(model.selectedPackIDs)")

        func elements(_ object: Any) -> [AnyObject] {
            let element = object as AnyObject
            return [element] + (element.accessibilityChildren?() ?? []).flatMap(elements)
        }
        func views(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(views) }
        func identifiers(_ host: NSView) -> [String] {
            views(host).flatMap(elements).compactMap { $0.accessibilityIdentifier?() }
        }
        func labels(_ host: NSView) -> [String] {
            views(host).flatMap(elements).flatMap { element -> [String] in
                let value = element.perform(NSSelectorFromString("accessibilityValue"))?.takeUnretainedValue() as? String
                return [element.accessibilityLabel?(), value].compactMap { $0 }
            }
        }
        func render(_ name: String, check: (NSView) -> Void) {
            let host = NSHostingView(rootView: OnboardingView(model: model, sync: sync).defaultAppStorage(defaults))
            let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: OnboardingView.width, height: OnboardingView.height),
                styleMask: [.titled], backing: .buffered, defer: false)
            panel.isReleasedWhenClosed = false
            panel.contentView = host
            panel.orderFront(nil)
            RunLoop.main.run(until: Date().addingTimeInterval(0.4))
            host.layoutSubtreeIfNeeded()
            let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds)!
            host.cacheDisplay(in: host.bounds, to: bitmap)
            try! bitmap.representation(using: NSBitmapImageRep.FileType.png, properties: [:])!.write(to: output.appendingPathComponent("onboarding-\(name).png"))
            check(host)
            panel.orderOut(nil); panel.close()
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
            model.stopMonitoring() // The controller does this from windowWillClose.
        }
        func expect(_ host: NSView, step: OnboardingStep) {
            let ids = identifiers(host)
            precondition(ids.contains(step.identifier), "Step content carries \(step.identifier): \(ids)")
            for other in OnboardingStep.allCases where other != step {
                precondition(!ids.contains(other.identifier), "Only the current step is rendered")
            }
            if ProcessInfo.processInfo.environment["DEBUG_ONBOARDING_AX"] == "1" {
                for element in views(host).flatMap(elements) {
                    let value = element.perform(NSSelectorFromString("accessibilityValue"))?.takeUnretainedValue()
                    let line = "AX \(element.accessibilityRole?()?.rawValue ?? "nil") | \(element.accessibilityIdentifier?() ?? "nil") | \(element.accessibilityLabel?() ?? "nil") | \(value.map { String(describing: $0) } ?? "nil")\n"
                    FileHandle.standardError.write(Data(line.utf8))
                }
            }
            for id in ["onboarding-progress", "onboarding-tour-continue", "onboarding-tour-back"] {
                precondition(ids.contains(id), "Chrome has \(id): \(ids)")
            }
            precondition(labels(host).contains(model.progressLabel), "Progress dots announce \(model.progressLabel): \(labels(host))")
        }

        // 1 Welcome
        render("1-welcome") { host in
            expect(host, step: .welcome)
            precondition(identifiers(host).contains("onboarding-tour-skip"), "Skip is offered before the last step")
            precondition(labels(host).contains { $0.contains("Option+Space") }, "The welcome step names the launcher shortcut")
        }
        precondition(!model.isMonitoring, "Polling is stopped between renders")

        // 2 Permissions: live status, no prompts.
        model.next()
        precondition(model.step == .permissions)
        render("2-permissions-missing") { host in
            expect(host, step: .permissions)
            let ids = identifiers(host)
            for id in ["onboarding-accessibility-status", "onboarding-accessibility-open", "onboarding-input-monitoring-status",
                       "onboarding-input-monitoring-open", "onboarding-microphone-status"] {
                precondition(ids.contains(id), "Permissions step has \(id): \(ids)")
            }
            let text = labels(host)
            precondition(text.contains { $0.contains("Not enabled") }, "Accessibility reads as missing: \(text)")
            precondition(text.contains { $0.contains("Not asked yet") }, "Input Monitoring reads as unknown")
            precondition(text.contains { $0.contains("Later") }, "Microphone is deferred")
        }
        model.openAccessibilitySettings(); model.openInputMonitoringSettings()
        precondition(accessibilityOpens == 1 && inputMonitoringOpens == 1 && !model.accessibilityOpenFailed)
        model.openAccessibilitySettings()
        precondition(model.accessibilityOpenFailed, "A failed open shows the manual path")
        trusted = true; inputMonitoring = true
        model.refresh()
        precondition(model.accessibility.trusted && model.inputMonitoring == true)
        render("2-permissions-granted") { host in
            let text = labels(host)
            precondition(text.filter { $0.contains("Enabled") }.count >= 2, "Both permissions read as enabled: \(text)")
            precondition(!text.contains { $0.contains("Not enabled") })
        }

        // 3 Trackpad: the choice applies on Continue and persists.
        model.next()
        precondition(model.step == .trackpad && model.device == .apple)
        render("3-trackpad") { host in
            expect(host, step: .trackpad)
            let ids = identifiers(host)
            precondition(ids.contains("onboarding-device-apple") && ids.contains("onboarding-device-navigator"))
        }
        model.device = .navigator
        model.next()
        precondition(appliedDevices == [.navigator], "Continue applies the device once: \(appliedDevices)")
        precondition(defaults.string(forKey: OnboardingModel.deviceKey) == "navigator")

        // 4 Try it: the HUD opening is detected through the injected probe.
        precondition(model.step == .tryIt && !model.hudOpened)
        render("4-try-it-waiting") { host in
            expect(host, step: .tryIt)
            precondition(identifiers(host).contains("onboarding-hud-status"))
            precondition(labels(host).contains { $0.contains("Waiting for the HUD") })
            precondition(labels(host).contains { $0.contains("Two-finger tap") }, "Gesture summary is listed")
        }
        hudVisible = true
        model.refresh()
        precondition(model.hudOpened)
        render("4-try-it-opened") { host in
            precondition(labels(host).contains { $0.contains("You opened the HUD") }, "Checkmark once the HUD was seen")
        }

        // 5 Where settings live: the Sync pane's chooser, same code path.
        model.next()
        precondition(model.step == .settingsHome && sync.mode == nil)
        render("5-settings-home") { host in
            expect(host, step: .settingsHome)
            let ids = identifiers(host)
            precondition(ids.contains("sync-choose-cloud") && ids.contains("sync-choose-local"), "Reuses SyncModeChooser: \(ids)")
            precondition(labels(host).contains { $0.contains("No choice yet") })
        }
        sync.choose(.local)
        render("5-settings-home-chosen") { host in
            precondition(labels(host).contains { $0.contains("Chosen: Local file") })
        }
        sync.leaveMode()

        // 6 Starter packs: checkboxes, then Finish imports through MacroPackImport.apply.
        model.next()
        precondition(model.step == .starterPacks && model.isLast)
        let gmail = packs.first { $0.name == "Gmail" }!
        render("6-starter-packs") { host in
            expect(host, step: .starterPacks)
            let ids = identifiers(host)
            for pack in packs { precondition(ids.contains("onboarding-pack-" + MacroPack.slug(pack.name)), "Checkbox for \(pack.name): \(ids)") }
            precondition(!ids.contains("onboarding-tour-skip"), "The last step offers Finish, not Skip")
        }
        model.togglePack(gmail.id)
        precondition(!model.selectedPackIDs.contains(gmail.id) && model.selectedPacks.count == 2)
        precondition(store.settings.resolvedHotkeyDictionary.isEmpty, "Nothing is imported before Finish")
        model.next()
        precondition(importedPacks == [["Google Chrome", "Slack"]], "Finish imports only the checked packs: \(importedPacks)")
        let library = store.settings.resolvedHotkeyDictionary
        precondition(library.contains { $0.packName == "Slack" } && library.contains { $0.packName == "Google Chrome" })
        precondition(Set(library.compactMap(\.packName)) == ["Slack", "Google Chrome"], "Unchecked packs stay out: \(Set(library.compactMap(\.packName)))")
        precondition(model.packImport?.failed.isEmpty == true && model.packImport?.imported == ["Google Chrome", "Slack"])
        precondition(model.completed && dismissed == 1 && OnboardingModel.isCompleted(defaults))
        precondition(!OnboardingModel.shouldPresent(defaults: defaults), "Completion persists")
        render("6-starter-packs-imported") { host in
            precondition(identifiers(host).contains("onboarding-pack-result"))
            precondition(labels(host).contains { $0.contains("Imported Google Chrome, Slack") })
        }

        // Back never leaves the range; Skip completes without importing.
        model.back(); precondition(model.step == .settingsHome)
        model.go(to: .welcome); model.back(); precondition(model.step == .welcome)
        defaults.removeObject(forKey: OnboardingModel.completedKey)
        let skipped = OnboardingModel(defaults: defaults, environment: environment)
        var skipDismissed = 0
        skipped.onDismiss = { skipDismissed += 1 }
        skipped.skip()
        precondition(skipped.completed && skipDismissed == 1 && OnboardingModel.isCompleted(defaults))
        precondition(importedPacks.count == 1, "Skip imports nothing")

        // The controller: one non-floating window; closing it counts as done.
        defaults.removeObject(forKey: OnboardingModel.completedKey)
        let controller = OnboardingController.shared
        controller.attach(store: store, hid: hid, sync: sync, defaults: defaults, environment: environment)
        precondition(controller.shouldPresentAtLaunch)
        controller.present()
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        let window = controller.window!
        precondition(window.identifier?.rawValue == "onboarding" && window.level == .normal && !window.styleMask.contains(.utilityWindow))
        precondition(controller.model?.step == .welcome && controller.model?.isMonitoring == true)
        controller.present() // Idempotent: the same window comes forward.
        precondition(controller.window === window)
        window.close()
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        precondition(controller.window == nil && controller.model == nil)
        precondition(OnboardingModel.isCompleted(defaults) && !controller.shouldPresentAtLaunch, "Closing the window never re-shows the tour at launch")
        controller.present() // General → "Show welcome tour…" reopens it after completion.
        precondition(controller.window != nil && controller.model?.step == .welcome)
        controller.window?.close()
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))

        print("Onboarding tour passed: six steps rendered, live permission and HUD status, device choice, sync chooser reuse, pack import, persistence")
    }
}
