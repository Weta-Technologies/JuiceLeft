import AppKit
import Carbon.HIToolbox
import SwiftUI

/// The steps of `--e2e` (E2E.swift has the stand-ins, the readings and the table): each function a user reaches, the
/// way they reach it, and what must come of it.
extension E2E {
    // MARK: - Launch

    static func launch(_ m: Monitor, _ defaults: UserDefaults) {
        check("Settings migration", "an older blob in the suite, read by Monitor.init",
              m.s.warnAt == 25 && m.s.alertAt == 7 && m.s.tone == "Glass" && m.s.volume == 0 && !m.s.insight && m.s.menuBar == .words
                && !m.s.menuBarWatts && m.s.hotKey == nil && m.s.deviceAlertAt == 15 && m.s.replaceSystemIcon && m.s.smartLowPower, "\(m.s)")
        check("Replace the macOS battery icon: at launch", "Monitor.init, on the fake battery-item preferences",
              mac.prefs["Battery"] as? NSNumber == 24 && defaults.integer(forKey: SystemBattery.originalKey) == -1
                && defaults.double(forKey: SystemBattery.ourPositionKey) == 178 && defaults.bool(forKey: SystemBattery.positionedKey), "prefs \(mac.prefs)")
        check("Welcome notice", "first launch with the swap on", m.welcome && defaults.bool(forKey: "welcomed"))
        check("Notification permission", "asked once at start (the low-battery notification is on by default)",
              asked == 1 && m.notificationsAllowed == true, "asked \(asked), allowed \(String(describing: m.notificationsAllowed))")
        check("Keyboard shortcut at launch", "none recorded: nothing registered", !registered(probe), "a shortcut is registered")
    }

    // MARK: - History: three days of readings, the way the battery source hands them in

    static func history(_ m: Monitor, _ url: URL) {
        // 72–36 h ago: full on the charger. 36–24 h: 100 → 40 % on battery at 5 %/h. 24–12 h: charging 40 → 100 %
        // at 20 %/h (tapering above 80 %), then full. The last 12 h: 100 → 40 % on battery at 5 %/h.
        level = 100
        run(hours: 36, onAC: true, rate: 0, charging: false, full: true)
        run(hours: 12, onAC: false, rate: -5)
        let charged = clock
        run(to: 100, onAC: true, rate: 20, step: 60)
        run(hours: 12 - clock.timeIntervalSince(charged) / 3600, onAC: true, rate: 0, charging: false, full: true)
        run(hours: 12, onAC: false, rate: -5)
        let saved = History.load(from: url)
        check("History: recorded and saved", "a point a minute from the readings; written at each plug change",
              m.history.points.count > 3 * 24 * 60 - 10 && saved.points.count > 2000 && m.history.learner.discharges >= 1,
              "\(m.history.points.count) points, \(saved.points.count) saved, \(m.history.learner.discharges) discharges scored")
        for (hours, want) in [(12, "100% → 40% · about 5%/h on battery"), (24, "40% → 40% · about 5%/h on battery"), (72, "100% → 40% · about 5%/h on battery")] {
            m.defaults.set(hours, forKey: "historyHours")
            let card = HistoryCard(monitor: m)
            let ticks = LevelChart.ticks(now: m.reading!.at, hours: Double(hours))
            check("History at \(hours == 72 ? "3 d" : "\(hours) h")", "the card's range picker (historyHours)",
                  card.subtitle == want && (hours == 72 ? ticks.count >= 2 && ticks.allSatisfy { $0.fraction > 0 && $0.fraction < 1 } : ticks.last?.text == "Now"),
                  "subtitle “\(card.subtitle)”, ticks \(ticks.map(\.text))")
        }
        m.defaults.set(24, forKey: "historyHours")
        check("Battery card", "its summary line", BatteryCard(monitor: m).summary == "Health 96% · Normal · 30 °C", BatteryCard(monitor: m).summary)
        let coach = HealthCoach.timeAtHighCharge(m.history.points, now: m.reading!.at)
        check("Battery: health coach", "the Battery card's coach rows", (coach ?? 0) > 0.55 && (coach ?? 1) < 0.7, "time at 95 %+: \(String(describing: coach))")
    }

    // MARK: - Forecasts on the traces

    static func forecasts(_ m: Monitor) {
        run(hours: 0.25, onAC: false, rate: -5, step: 30)
        let f = m.forecast
        let expected = level / 5 * 60
        check("Forecast: draining", "15 min more of a 5 %/h drain after three days of history",
              f?.kind == .flat && abs(Double(f?.minutes ?? 0) - expected) / expected < 0.15, "\(String(describing: f)) against \(Int(expected)) min")
        let shown = Format.rounded5(f?.minutes ?? 0)
        check("Menu bar: words, draining", "the status item's frame", m.icon.frame.percent == "\(m.reading!.percent)%"
                && m.icon.frame.trailing == Format.words(shown, charging: false), "\(m.icon.frame)")
        let hover = m.hoverLines
        check("Hover card text, draining", "Monitor.hoverLines", hover.title == Format.words(shown, charging: false)
                && hover.detail == "Flat around \(Format.clock(f!.at)) · \(m.reading!.percent)% · Alerts on" && !hover.warning, "\(hover)")
        check("Panel header, draining", "Monitor.headline / detail", m.headline == "Flat around \(Format.clock(f!.at))"
                && m.detail.hasPrefix("\(m.reading!.percent)% · ") && m.detail.contains("left"), "“\(m.headline)” / “\(m.detail)”")
        check("VoiceOver: the item's label", "Monitor.spoken", m.spoken.hasPrefix("JuiceLeft: \(m.reading!.percent) percent, flat around") && m.spoken.hasSuffix("Alerts on."), m.spoken)
    }

    // MARK: - The status item

    static func statusItemGestures(_ m: Monitor, _ item: StatusItemController) {
        settle(0.5)   // the menu bar places the item on the run loop
        item.perform(.panel)
        waitFor { item.panelShown }
        check("Status item: click opens the panel", "StatusItemController.perform(.panel), what a click decides", item.panelShown && m.panelIsOpen,
              "shown \(item.panelShown), open \(m.panelIsOpen), active \(NSApp.isActive), item window \(String(describing: item.hover?.panel))")
        settle(0.7)   // past the item's 0.5 s guard against the same press bouncing back
        item.clicked()
        waitFor { !item.panelShown }
        check("Status item: click again closes it", "StatusItemController.clicked() while open", !item.panelShown && !m.panelIsOpen)
        m.onOpenPanel?()
        waitFor { item.panelShown }
        let openedByKey = item.panelShown && m.panelIsOpen
        if let esc = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                      windowNumber: 0, context: nil, characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53) {
            NSApp.postEvent(esc, atStart: false)
        }
        waitFor { !item.panelShown }
        check("Status item: the shortcut opens the panel, Esc closes it", "Monitor.onOpenPanel (the hot key's action), then an Esc key event through the app's event queue",
              openedByKey && !item.panelShown && !m.panelIsOpen, "opened \(openedByKey), still shown \(item.panelShown), open \(m.panelIsOpen)")
        item.perform(.toggle)
        settle()
        let off = !m.s.armed && !m.icon.frame.armed && Settings.load(m.defaults).armed == false
        item.perform(.toggle)
        settle()
        check("Status item: press and hold toggles monitoring", "StatusItemController.perform(.toggle), twice", off && m.s.armed && m.icon.frame.armed)
        item.hover?.crossed(true)
        settle(HoverCard.delay + 0.3)
        let shown = item.hover?.showing == true && item.hover?.panel?.isVisible == true
        item.hover?.crossed(false)
        settle(HoverCard.fade + 0.2)
        check("Hover card: shows after the delay, goes when the pointer leaves", "HoverCard.crossed(true / false)", shown && item.hover?.showing == false && item.hover?.panel?.isVisible == false)
        item.perform(.panel)
        settle(0.3)
        item.hover?.crossed(true)
        settle(HoverCard.delay + 0.3)
        check("Hover card: never over the open panel", "HoverCard.crossed(true) with the panel open", item.hover?.showing == false)
        item.hover?.crossed(false)
        item.close()
        waitFor { !item.panelShown }
        NSApp.deactivate()   // opening the panel activated the app: the keyboard goes back to whatever had it
    }


    // MARK: - The panel's controls

    /// The panel has re-read the (fake) pmset since the last request.
    static func synced(_ m: Monitor) { waitFor { m.power == mac.power && !m.powerBusy } }

    /// Close the panel and open it again: what re-reads the helper, the modes, the accessories and the model's status.
    static func reopen(_ m: Monitor) { m.panelClosed(); m.panelOpened(); settle(0.3) }

    static func panelBasics(_ m: Monitor) {
        m.toggleArmed()   // the header switch's binding
        let off = !m.s.armed && AlertsCard(monitor: m).subtitle == "Off: nothing flashes or sounds" && m.hoverLines.detail.hasSuffix("Alerts off") && !Settings.load(m.defaults).armed
        m.toggleArmed()
        check("Header: Monitoring switch", "the switch's binding → Monitor.toggleArmed, off and on", off && m.s.armed && AlertsCard(monitor: m).subtitle == "Flash red at 25% · tone at 7%",
              AlertsCard(monitor: m).subtitle)
        m.dismissWelcome(); m.defaults.set(true, forKey: "tapHintSeen")   // the notice's ✕
        check("Welcome notice: dismiss", "the notice's ✕ → dismissWelcome + tapHintSeen", !m.welcome && m.defaults.bool(forKey: "welcomed"))
        mac.helperReady = false
        reopen(m)
        let card = !m.helperReady && !m.helperStale && !m.setupLater
        m.setupLater = true   // "Later"
        check("Setup card: shown without the helper, Later hides it", "helper not ready → card; Later → setupLater", card && m.setupLater)
        mac.installOutcome = .cancelled
        m.setUpHelper()   // "Set up now"
        let cancelled = !m.helperReady && m.note == nil
        mac.installOutcome = .failed("the prompt was dismissed")
        m.setUpHelper()
        let failed = m.note == "The helper didn't install: the prompt was dismissed"
        mac.installOutcome = .done
        m.setUpHelper()
        check("Setup card: Set up now (cancelled, failed, done)", "SetupCard / Set up… → Monitor.setUpHelper on the fake installer",
              cancelled && failed && m.helperReady && m.note == nil && mac.installs == 3, "cancelled \(cancelled) failed \(failed) ready \(m.helperReady) note \(m.note ?? "-") installs \(mac.installs)")
        m.setupLater = false
    }

    static func menuBarStyles(_ m: Monitor) {
        let pct = "\(m.reading!.percent)%"
        m.s.menuBar = .icon   // the segmented picker's binding
        let icon = m.icon.frame.percent == nil && m.icon.frame.trailing == nil && m.menuPreview(for: .icon) == "the battery alone"
        m.s.menuBar = .percent
        let percent = m.icon.frame.percent == pct && m.icon.frame.trailing == nil && m.menuPreview(for: .percent) == "\(pct) · battery"
        m.s.menuBar = .compact
        let compact = m.icon.frame.trailing.map { $0.range(of: #"^\d+:\d\d$"#, options: .regularExpression) != nil } == true
            && m.menuPreview(for: .compact) == "\(pct) · battery · \(m.icon.frame.trailing ?? "")"
        m.s.menuBar = .words
        let words = m.icon.frame.trailing?.hasSuffix("Remaining") == true && m.menuPreview(for: .words) == "\(pct) · battery · \(m.icon.frame.trailing ?? "")"
        check("Menu bar shows: Icon, Percent, Compact, Words", "the picker's binding; the frame drawn and the preview beside it",
              icon && percent && compact && words, "icon \(icon) percent \(percent) compact \(compact) words \(words): \(m.icon.frame)")
        m.s.menuBarWatts = true   // More › Power draw in the menu bar
        let watts = m.icon.frame.trailing?.hasSuffix(" · −4 W") == true && m.menuPreview(for: .words).hasSuffix(" · −4 W") && MoreRows(monitor: m).summary.contains("Power draw")
        m.s.menuBar = .icon
        let iconOnly = m.icon.frame.trailing == nil && !MoreRows(monitor: m).summary.contains("Power draw")
        m.s.menuBar = .words
        m.s.menuBarWatts = false
        check("Menu bar: power draw option", "More › Power draw in the menu bar (and hidden with Icon)", watts && iconOnly && m.icon.frame.trailing?.hasSuffix("Remaining") == true, "\(m.icon.frame)")
    }

    static func powerList(_ m: Monitor) {
        table = [hog.pid: (0, hog.path + "/Contents/MacOS/Example Editor"), player.pid: (0, player.path + "/Contents/MacOS/Sample Player"),
                 90003: (0, "/usr/libexec/exampled")]
        burn = [hog.pid: 1.8, player.pid: 0.3, 90003: 0.9]   // 60 %, 10 % and 30 % of a core over the meter's 3 s
        reopen(m)
        waitFor(8) { m.energy.ranking.apps.count == 2 }
        let r = m.energy.ranking
        check("Using the most power: your apps, by share", "the meter's 3 s sample of the (fake) process table, panel open",
              r.apps.map(\.name) == ["Example Editor", "Sample Player"] && abs((r.apps.first?.share ?? 0) - 0.6) < 0.05 && abs(r.backgroundShare - 0.3) < 0.05
                && EnergyCard(meter: m.energy).subtitle == "Your apps, by share of processor time",
              "\(r.apps.map { "\($0.name) \($0.share)" }) background \(r.backgroundShare)")
        check("Using the most power: System & background", "the rolled-up row and its list", r.background.map(\.name) == ["exampled"], "\(r.background.map(\.name))")
        feed(onAC: false, rate: -5)
        let tips = m.tips.map(\.id)
        check("Tips: what is costing power", "Tips.detect on the live facts, panel open", tips.count == 2 && tips.contains("brightness") && tips.contains("app")
                && m.tips.first { $0.id == "app" }?.text == "Example Editor is working hard: 60% of a core", "\(m.tips.map(\.text))")
        if let dim = m.tips.first(where: { $0.id == "brightness" }) { m.apply(dim) }   // the tip's Dim button
        check("Tip: Dim", "the Dim button → Monitor.apply", hardware.level == Float(Tips.dimTo) && !m.tips.contains { $0.id == "brightness" } && m.tips.contains { $0.id == "keyboard" },
              "level \(hardware.level), tips \(m.tips.map(\.id))")
        if let keys = m.tips.first(where: { $0.id == "keyboard" }) { m.apply(keys) }
        check("Tip: Turn off (keyboard light)", "the Turn off button → Monitor.apply", hardware.keys == KeyboardLight.Level(brightness: 0, auto: false), "\(hardware.keys)")
        if let quit = m.tips.first(where: { $0.id == "app" }) { m.apply(quit) }
        check("Tip: Quit (a made-up app)", "the Quit button → Monitor.apply → EnergyMeter.quit", hog.quits == 1 && m.energy.quitting[hog.path] != nil
                && TipRows.help(.quit(app: "Example Editor")) == "Quit Example Editor — its own save prompts protect unsaved work.", "quits \(hog.quits)")
        burn[hog.pid] = 0   // quitting: idle, but still there
        let before = Feed.requests.count
        waitFor(8) { m.energy.ranking.apps.first { $0.name == "Example Editor" }?.cpuPercent == 0 }
        check("Using the most power: a quitting app stays pinned", "the next samples, with the app idle", m.energy.ranking.apps.contains { $0.name == "Example Editor" } && Feed.requests.count == before)
        m.energy.forceQuit(r.apps[0])   // "Still running" → Force Quit → confirm
        hog.gone = true
        table[hog.pid] = nil
        waitFor(8) { m.energy.quitting.isEmpty && !m.energy.ranking.apps.contains { $0.name == "Example Editor" } }   // the list comes back from the background
        check("Using the most power: Force Quit, then the row goes", "EnergyMeter.forceQuit (the confirmed button), the app gone",
              hog.forced == 1 && m.energy.quitting.isEmpty && !m.energy.ranking.apps.contains { $0.name == "Example Editor" }, "\(m.energy.ranking.apps.map(\.name))")
        feed(onAC: false, rate: -5)
        let usb = m.tips.first
        check("Tip: a hungry USB device (no button)", "Tips.detect with nothing else to fix", m.tips.count == 1 && usb?.text == "Portable SSD is drawing 900 mA — unplug it when you can"
                && usb?.fix == .unplugUSB && TipRows.verb(.unplugUSB).isEmpty, "\(m.tips.map(\.text))")
        hardware.level = 0.85
        hardware.keys = KeyboardLight.Level(brightness: 0.5, auto: true)
    }

    static func saveBattery(_ m: Monitor) {
        feed(onAC: false, rate: -5)
        let gain = m.saveBatteryGain
        let label = gain.flatMap { Tip.gainText($0.minutes, estimated: $0.estimated) }
        m.saveBattery()   // the big button
        let snap = m.saving
        let stored = m.defaults.data(forKey: SaverSnapshot.key).flatMap { try? JSONDecoder().decode(SaverSnapshot.self, from: $0) }
        check("Save Battery", "the Save Battery button → Monitor.saveBattery", (gain?.minutes ?? 0) > 0 && label?.hasPrefix("~+") == true
                && hardware.level == 0.4 && hardware.keys == KeyboardLight.Level(brightness: 0, auto: false) && mac.powerRequests.last == "b 1"
                && stored == snap && snap.map(SaveBatteryRow.describe) == "screen 85% → 40% · keyboard light off · Low Power on" && m.saveBatteryGain == nil,
              "gain \(String(describing: gain)) label \(label ?? "-") level \(hardware.level) keys \(hardware.keys) requests \(mac.powerRequests.suffix(2)) \(snap.map(SaveBatteryRow.describe) ?? "-")")
        feed(onAC: false, rate: -5)
        m.undoSaveBattery()   // Undo
        check("Save Battery: Undo", "the Undo button → Monitor.undoSaveBattery", m.saving == nil && hardware.level == 0.85
                && hardware.keys == KeyboardLight.Level(brightness: 0.5, auto: true) && mac.powerRequests.last == "b 0" && m.defaults.data(forKey: SaverSnapshot.key) == nil,
              "level \(hardware.level) keys \(hardware.keys) requests \(mac.powerRequests.suffix(2))")
        feed(onAC: false, rate: -5)
    }

    static func energyModes(_ m: Monitor) {
        let asked = mac.powerRequests.count
        for (mode, line) in [(PowerMode.Mode.high, "b 2"), (.low, "b 1"), (.automatic, "b 0")] {
            m.setPowerMode(mode)   // the segmented picker's binding
            let busy = m.powerBusy
            waitFor { !m.powerBusy }
            check("Energy mode: \(mode.name), on battery", "the picker's binding → Monitor.setPowerMode, confirmed from the (fake) pmset",
                  busy && mac.powerRequests.last == line && m.activeMode == mode && !m.powerBusy, "busy \(busy) \(mac.powerRequests.suffix(1)) active \(String(describing: m.activeMode))")
            feed(onAC: false, rate: -5)
        }
        m.setPowerMode(.automatic)
        check("Energy mode: choosing the one in use", "the picker's binding with the same mode", mac.powerRequests.count == asked + 3)
        mac.helperReady = false
        reopen(m)
        m.setPowerMode(.low)
        check("Energy mode: without the helper", "the picker's binding with no helper", m.note == "Energy modes need the one-time setup — click Set up." && mac.powerRequests.count == asked + 3,
              m.note ?? "-")
        m.setUpHelper()   // the row's Set up…
        check("Energy mode: Set up…", "the row's Set up… → Monitor.setUpHelper", m.helperReady && m.note == nil)
        SystemBattery.openBatterySettings()   // "Battery Settings…"
        check("Energy mode: Battery Settings…", "the link's action", opened.last?.absoluteString == "x-apple.systempreferences:com.apple.Battery-Settings.extension",
              "\(String(describing: opened.last))")
    }

    static func smartLowPower(_ m: Monitor) {
        run(to: 31, onAC: false, rate: -5)
        let asked = mac.powerRequests.count
        while !m.smartApplied, level > 25 { feed(onAC: false, rate: -5) }
        let engaged = m.smartApplied && mac.powerRequests.last == "b 1" && mac.powerRequests.count == asked + 1 && StretchCard(monitor: m).summary.hasPrefix("Smart Low Power")
        feed(onAC: false, rate: -5)
        synced(m)
        m.setPowerMode(.automatic)   // the user moves it by hand
        synced(m)
        run(hours: 0.1, onAC: false, rate: -5, step: 30)
        check("Smart Low Power: engages at 30 %, stands back when moved by hand", "readings down through 30 % (helper set up), then the picker",
              engaged && !m.smartApplied && mac.powerRequests.suffix(2) == ["b 1", "b 0"] && mac.power.battery == .automatic,
              "engaged \(engaged) applied \(m.smartApplied) \(mac.powerRequests.suffix(3))")
        let lowTip = m.tips.first { $0.id == "lowpower" }
        if let lowTip { m.apply(lowTip) }
        check("Tip: Low Power", "the Low Power button → Monitor.apply", lowTip?.text == "Under 30% with Low Power off" && mac.powerRequests.last == "b 1", "\(m.tips.map(\.text))")
        synced(m)
        m.setPowerMode(.automatic)
        synced(m)
        feed(onAC: true, rate: 20)   // a moment on the charger clears the hand-moved flag
        feed(onAC: false, rate: -5)
        synced(m)
        let again = m.smartApplied && mac.powerRequests.last == "b 1"
        feed(onAC: true, rate: 20)
        synced(m)
        check("Smart Low Power: back to the old mode on the charger", "unplugged under 30 %, then the charger", again && !m.smartApplied && mac.powerRequests.last == "b 0",
              "\(mac.powerRequests.suffix(3))")
        feed(onAC: false, rate: -5)
        m.s.smartLowPower = false   // the switch; the drain below stays on Automatic
        feed(onAC: false, rate: -5)
    }

    static func alerts(_ m: Monitor) {
        m.s.warnAt = 20   // the Flash red at slider
        m.s.alertAt = 30   // the Play tone at slider can't pass it
        let clamped = m.s.alertAt == 20
        m.s.alertAt = 10
        m.s.tone = "Ping"
        m.s.volume = 0.6
        m.s.repeatMinutes = 2
        m.testTone()   // Test
        check("Low-battery alerts: levels, tone, Test, volume, repeat", "the sliders', picker's and Test button's bindings",
              clamped && played.last?.name == "Ping" && played.last?.volume == 0.6 && AlertsCard(monitor: m).subtitle == "Flash red at 20% · tone at 10%"
                && Settings.load(m.defaults) == m.s, "\(played.last.map { "\($0)" } ?? "-") “\(AlertsCard(monitor: m).subtitle)”")
        allowNotifications = false
        m.s.notify = false
        m.s.notify = true   // off and on: macOS is asked again
        settle()
        let denied = m.notificationsAllowed == false && AlertsCard(monitor: m).notificationNote == "Turned off for JuiceLeft in System Settings › Notifications"
        allowNotifications = true
        m.s.notify = false
        m.s.notify = true
        settle()
        check("Low-battery alerts: Notification switch", "the switch; permission asked when it goes on", denied && m.notificationsAllowed == true && AlertsCard(monitor: m).notificationNote == "With the time to flat",
              "denied \(denied)")
        let tones = played.count
        run(to: 20.8, onAC: false, rate: -20)
        let posts = posted.count
        while m.phase != .warning, level > 15 { feed(onAC: false, rate: -20) }
        waitFor(1) { m.icon.frame.red > 0 }
        let warned = posted.dropFirst(posts)
        check("Warning at 20 %: flash + notification", "readings down through the flash level",
              m.phase == .warning && m.icon.frame.red > 0 && warned.count == 1 && warned.first?.id == "warning" && warned.first?.title == "Battery at 20%"
                && warned.first?.body == m.forecastLine && m.hoverLines.warning && m.hoverLines.detail.hasSuffix("At or below 20%: flashing")
                && AlertsCard(monitor: m).subtitle == "Flashing: at or below 20%" && played.count == tones,
              "\(m.phase) \(warned.map { "\($0.id) “\($0.title)” \($0.body)" })")
        m.snooze()   // Snooze
        let quiet = m.phase == .clear && m.snoozedUntil != nil && AlertsCard(monitor: m).subtitle == "Quiet until \(Format.clock(m.snoozedUntil!))"
        m.resume()   // Resume
        check("Alerts: Snooze and Resume", "the card's Snooze, then Resume", quiet && m.phase == .warning && m.snoozedUntil == nil, "quiet \(quiet)")
        run(to: 10.8, onAC: false, rate: -20)
        let before = posted.count
        while m.phase != .alert, level > 5 { feed(onAC: false, rate: -20) }
        let alerted = posted.dropFirst(before)
        check("Alert at 10 %: tone + notification", "readings down through the tone level",
              m.phase == .alert && played.count == tones + 1 && played.last?.name == "Ping" && alerted.count == 1 && alerted.first?.id == "alert"
                && alerted.first?.title == "Battery low: 10%" && alerted.first?.body == "Plug in soon. " + m.forecastLine,
              "\(m.phase) tones \(played.count - tones) \(alerted.map { "\($0.id) “\($0.title)”" })")
        run(hours: 2.2 / 60, onAC: false, rate: -2, step: 30)
        check("Alert: the tone repeats", "two more minutes at the tone level, repeat every 2 min", played.count == tones + 2, "\(played.count - tones) tones")
    }

    static func devices(_ m: Monitor) {
        accessories = [.init(id: "trackpad", name: "Trackpad", percent: 12, kind: .trackpad), .init(id: "mouse", name: "Mouse", percent: 47, kind: .mouse),
                       .init(id: "keyboard", name: "Keyboard", percent: 88, kind: .keyboard)]
        m.refreshDevices()   // what the open panel does every minute
        waitFor { m.devices.count == 3 }
        check("Your devices", "the panel's accessory read (fake accessories)", m.devices.map(\.name) == ["Trackpad", "Mouse", "Keyboard"] && DevicesCard(monitor: m).subtitle == "Trackpad 12% · 2 more",
              DevicesCard(monitor: m).subtitle)
        let before = posted.count
        m.s.deviceAlert = true   // Tell me when one gets low
        waitFor { posted.count > before }
        m.refreshDevices()
        settle(0.5)
        let first = posted.dropFirst(before)
        check("Your devices: low alert", "the switch on; the read it starts, then another", first.count == 1 && first.first?.id == "device-trackpad"
                && first.first?.title == "Trackpad battery low: 12%" && first.first?.body == "Charge it or change its battery soon.", "\(first.map { "\($0.id) “\($0.title)”" })")
        m.s.deviceAlertAt = 50   // the Low at slider
        m.refreshDevices()
        waitFor { posted.count > before + 1 }
        accessories[0].percent = 60; m.refreshDevices(); settle(0.5)
        accessories[0].percent = 10; m.refreshDevices(); waitFor { posted.count > before + 2 }
        check("Your devices: level slider, once per charge", "Low at 50 %; the trackpad charged and run down again",
              posted.dropFirst(before).map(\.id) == ["device-trackpad", "device-mouse", "device-trackpad"], "\(posted.dropFirst(before).map(\.title))")
        m.s.deviceAlert = false
        m.s.deviceAlertAt = 15
    }

    static func stretch(_ m: Monitor) {
        m.s.brightnessCap = true   // Keep the screen at or below
        m.s.brightnessCapLevel = 0.5   // the Cap slider
        feed(onAC: false, rate: -2)
        let capped = hardware.level == 0.5 && StretchCard(monitor: m).summary.contains("Screen ≤ 50%")
        m.s.brightnessCapLevel = 0.95
        let clamp = m.s.brightnessCapLevel == 0.8
        m.s.brightnessCapLevel = 0.3
        feed(onAC: false, rate: -2)
        let lower = hardware.level == Float(0.3)
        feed(onAC: true, rate: 20)
        check("Screen cap", "the switch and the Cap slider; readings on battery, then the charger", capped && clamp && lower && hardware.level == 0.85,
              "capped \(capped) clamp \(clamp) lower \(lower) level \(hardware.level)")
        m.s.brightnessCap = false
        m.setChargeLimit(85)   // the Charge limit picker
        let limited = mac.limitSets.last == 85 && m.chargeLimit?.enabled == true && m.chargeLimit?.limit == 85 && StretchCard(monitor: m).summary.contains("Charge to 85%")
        m.setChargeLimit(100)   // "Off"
        let offed = mac.limitSets.last == 100 && m.chargeLimit?.enabled == false
        m.setChargeLimit(ChargeLimit.recommended)   // the Battery card's Set 80%
        waitFor { m.chargeLimit?.limit == 80 }
        check("Charge limit: 85 %, Off, and the Battery card's Set 80%", "the picker's binding and the Set 80% button → Monitor.setChargeLimit",
              limited && offed && mac.limitSets.suffix(3) == [85, 100, 80] && m.chargeLimit?.enabled == true && m.chargeTarget == 80, "\(mac.limitSets)")
        m.fullForTravel()   // Full for travel
        let travelling = mac.topUps == 1 && m.travelFull != nil && m.chargeTarget == 100 && (m.defaults.dictionary(forKey: "travelFull")?["previous"] as? Int) == 80
            && StretchCard(monitor: m).summary.hasSuffix("Full for travel")
        m.cancelFullForTravel()   // Cancel
        check("Full for travel, and Cancel", "the button → fullForTravel; Cancel → the limit back", travelling && m.travelFull == nil && mac.limitSets.last == 80
                && m.defaults.object(forKey: "travelFull") == nil, "travelling \(travelling) \(mac.limitSets)")
        let before = posted.count
        feed(onAC: false, rate: -2, celsius: 41)
        let hot = m.heatNote == "Battery at 41 °C. Turn on Low Power Mode, close what is working hard, and give it some air." && BatteryCard(monitor: m).summary.hasSuffix("41 °C")
        feed(onAC: false, rate: -2, celsius: 38)
        check("Heat guard", "a reading at 41 °C on battery, then 38 °C", hot && m.heatNote == nil && posted.dropFirst(before).filter { $0.id == "heat" }.map(\.title) == ["Battery running hot"]
                && posted.last { $0.id == "heat" }?.body.hasPrefix("Battery at 41 °C.") == true, "\(m.heatNote ?? "-") \(posted.dropFirst(before).map(\.title))")
        feed(onAC: false, rate: -2, celsius: 41)
        m.heatNote = nil   // the nudge's ✕
        let dismissed = m.heatNote == nil
        feed(onAC: false, rate: -2, celsius: 30)
        m.s.heatGuard = false
        feed(onAC: false, rate: -2, celsius: 42)
        check("Heat guard: dismiss, and the switch off", "the nudge's ✕; the switch", dismissed && m.heatNote == nil && posted.filter { $0.id == "heat" }.count == 2)
        m.s.heatGuard = true
        feed(onAC: false, rate: -2, celsius: 30)
    }


    static func charging(_ m: Monitor) {
        m.s.plugNotices = true; m.s.unplugReminder = true; m.s.fullNotice = true   // Charging care's three switches
        run(to: 9, onAC: false, rate: -20)
        m.saveBattery()
        let before = posted.count, lines = mac.lightLines.count
        feed(onAC: true, rate: 30)
        let plugged = posted.dropFirst(before)
        check("Charger in: notification, Save Battery undone, alerts clear", "a reading on the charger (MagSafe, 70 W)",
              plugged.map(\.title) == ["Charger connected"] && plugged.first?.body == "70W USB-C Power Adapter · 70 W" && m.saving == nil && m.phase == .clear,
              "\(plugged.map { "“\($0.title)” \($0.body)" }) saving \(m.saving != nil)")
        let fast = mac.lightLines.dropFirst(lines).last == "7"
        m.s.lightFastWhenLow = false   // Fast blink when charging from 10 % or below
        let slowInstead = mac.lightLines.last == "6"
        m.s.lightFastWhenLow = true
        check("Charging light: fast blink when charging from the tone level, and its switch", "the first reading on MagSafe at ≤ 10 %; the switch off and on",
              fast && slowInstead && mac.lightLines.last == "7", "\(mac.lightLines.dropFirst(lines))")
        run(to: 12, onAC: true, rate: 30)
        check("Charging light: steady orange after the blink", "readings past the tone level, 30 s and more after plugging in",
              mac.lightLines.last == "4" && LightRows(monitor: m, light: m.light).status == "MagSafe · now orange", "\(mac.lightLines.suffix(2))")
        m.s.lightBehaviour = .blink   // While charging: Blink
        let blink = mac.lightLines.last == "6"
        m.s.lightBehaviour = .apple   // Apple's default: handed back
        let apple = mac.lightLines.last == "4 0" && LightRows(monitor: m, light: m.light).status == "MagSafe · macOS's own colours"
        m.s.lightBehaviour = .blinkThenSteady
        check("Charging light: While charging picker", "Blink, Apple's default, Blink then steady", blink && apple && mac.lightLines.last == "4", "\(mac.lightLines.suffix(4))")
        run(hours: 0.25, onAC: true, rate: 30, step: 30)
        let f = m.forecast, expected = (80 - level) / 30 * 60   // a straight line below 80 %
        let forecastAt = clock
        check("Forecast: charging to the 80 % limit", "readings at 30 %/h with the limit on",
              f?.kind == .full && f?.target == 80 && abs(Double(f?.minutes ?? 0) - expected) / expected < 0.1 && m.icon.frame.trailing?.hasSuffix("Until 80%") == true
                && m.headline.hasPrefix("80% around ") && m.detail.contains("to 80%".nonBreaking) && m.detail.contains("70 W charger".nonBreaking),
              "\(String(describing: f)) against \(Int(expected)) · \(m.icon.frame.trailing ?? "-") · “\(m.headline)” “\(m.detail)”")
        let hover = m.hoverLines
        check("Hover card text, charging", "Monitor.hoverLines", hover.title == m.icon.frame.trailing && hover.detail.hasPrefix("80% around ")
                && hover.detail.hasSuffix(" · \(m.reading!.percent)% · 70 W charger · Alerts on"), "\(hover)")
        m.s.menuBar = .compact
        let compact = m.icon.frame.trailing.map { $0.range(of: #"^(\d+:\d\d|\d+m)$"#, options: .regularExpression) != nil } == true
        m.s.menuBar = .words
        check("Menu bar: compact while charging is the time alone", "the picker at Compact", compact)
        m.setPowerMode(.high)   // on the charger the picker sets the adapter's mode
        synced(m)
        let adapter = mac.powerRequests.last == "c 2" && m.activeMode == .high
        m.setPowerMode(.automatic)
        synced(m)
        check("Energy mode: on the charger", "the picker's binding while charging", adapter && mac.powerRequests.last == "c 0", "\(mac.powerRequests.suffix(2))")
        let unplugs = posted.filter { $0.id == "unplug" }.count
        run(to: 80, onAC: true, rate: 30)
        let reminder = posted.filter { $0.id == "unplug" }
        let took = clock.timeIntervalSince(forecastAt) / 60
        check("Forecast: charging to the limit, against the trace", "the time the readings really took to reach 80 %",
              abs(Double(f?.minutes ?? 0) - took) <= max(3, took * 0.05), "forecast \(f?.minutes ?? -1) min, took \(Int(took))")
        check("Remind me to unplug at 80 %", "readings up to 80 % while charging", reminder.count == unplugs + 1 && reminder.last?.title == "Battery at 80%"
                && reminder.last?.body == "Unplugging now is kinder to the battery than sitting at 100%.", "\(reminder.map(\.title))")
        feed(onAC: true, rate: 0, charging: false)
        feed(onAC: true, rate: 0, charging: false)
        let full = posted.filter { $0.id == "full" }
        check("Held at the limit: header, hover card, menu bar, notice, light", "readings at 80 % on the charger, not charging",
              m.headline == "Held at 80%" && m.hoverLines.title == "Held at 80%" && m.icon.frame.trailing == nil && m.forecast == nil
                && full.map(\.title) == ["Held at 80%"] && full.last?.body == "You can unplug." && mac.lightLines.last == "3"
                && ChargingCard(monitor: m).summary == "Unplug at 80% · Full notice · Plug in/out · MagSafe light",
              "“\(m.headline)” “\(m.hoverLines.title)” \(m.icon.frame.trailing ?? "-") \(full.map(\.title)) \(mac.lightLines.suffix(1)) “\(ChargingCard(monitor: m).summary)”")
        render("panel-held-at-80")
        m.s.lightGreenAtLimit = false
        let noGreen = mac.lightLines.last == "3 0"
        m.s.lightGreenAtLimit = true
        check("Charging light: green at the limit, and off", "the switch", noGreen && mac.lightLines.last == "3", "\(mac.lightLines.suffix(2))")
        mac.lightReady = false
        m.s.light = false   // the Charging light switch: hands back, but the helper can't take it
        let needs = m.light.needsSetup && LightRows(monitor: m, light: m.light).status == "Needs a one-time setup"
        m.setUpHelper()   // the light's Set up…
        let handedBack = mac.lightLines.last == "3 0" && !m.light.needsSetup
        m.s.light = true
        check("Charging light: switch, and Set up… when the helper is missing", "the switch off (hand back), Set up…, on again",
              needs && handedBack && mac.lightLines.last == "3", "needs \(needs) handed back \(handedBack) \(mac.lightLines.suffix(3))")
        m.setChargeLimit(100)   // Off: on to full, through the taper
        run(hours: 20.0 / 60, onAC: true, rate: 30, step: 30)   // the trend's 20 minutes hold only this charge
        let t = m.forecast, taperFrom = clock, taperLevel = level
        run(to: 100, onAC: true, rate: 30)
        let tookToFull = clock.timeIntervalSince(taperFrom) / 60
        check("Forecast: the taper above 80 %, against the trace", "readings from \(Int(taperLevel)) % with no limit, the charger tapering; the time they took to reach 100 %",
              t?.target == 100 && abs(Double(t?.minutes ?? 0) - tookToFull) <= max(3, tookToFull * 0.1), "\(String(describing: t)), took \(Int(tookToFull)) min")
        m.setChargeLimit(80)
        m.fullForTravel()
        let before2 = posted.count, lines2 = mac.lightLines.count
        feed(onAC: false, rate: -8)
        let out = posted.dropFirst(before2)
        check("Charger out: notification, light handed back, the trip's limit back", "a reading on battery",
              out.map(\.title) == ["On battery: \(m.reading!.percent)%"] && out.first?.body == m.forecastLine && mac.lightLines.dropFirst(lines2) == ["0"]
                && m.travelFull == nil && mac.limitSets.last == 80, "\(out.map { "“\($0.title)” \($0.body)" }) \(mac.lightLines.dropFirst(lines2)) \(mac.limitSets.suffix(2))")
        m.setChargeLimit(100)
        let before3 = posted.count, lines3 = mac.lightLines.count
        feed(onAC: true, rate: 25, adapterWatts: 20, magSafe: false)
        let slow = posted.dropFirst(before3).first { $0.id == "plug" }
        check("A slow USB-C charger", "a reading on a 20 W charger", slow?.body == "20W USB-C Power Adapter · 20 W · Charging slowly — 20 W charger"
                && ChargingCard(monitor: m).summary == "Charging slowly — 20 W charger" && LightRows(monitor: m, light: m.light).status == "Charging through USB-C: no light to drive",
              "\(slow.map { $0.body } ?? "-") “\(ChargingCard(monitor: m).summary)”")
        run(to: 100, onAC: true, rate: 25)
        feed(onAC: true, rate: 0, charging: false, full: true)
        feed(onAC: true, rate: 0, charging: false, full: true)
        check("Fully charged: notice, header, hover card, menu bar", "readings to 100 % and full",
              posted.filter { $0.id == "full" }.last?.title == "Fully charged" && m.headline == "Fully charged" && m.hoverLines.title == "Fully Charged"
                && m.icon.frame.trailing == nil && mac.lightLines.count == lines3, "“\(m.headline)” \(posted.filter { $0.id == "full" }.map(\.title))")
        m.s.plugNotices = false; m.s.unplugReminder = false; m.s.fullNotice = false
        feed(onAC: false, rate: -8)
    }

    static func more(_ m: Monitor, _ item: StatusItemController) {
        m.setHotKey(probe)   // the recorder's binding
        let set = m.s.hotKey == probe && registered(probe) && MoreRows(monitor: m).summary.hasPrefix("Shortcut ⌃⌥⇧⌘J") && Settings.load(m.defaults).hotKey == probe
        var event: EventRef?
        CreateEvent(nil, OSType(kEventClassKeyboard), UInt32(kEventHotKeyPressed), 0, EventAttributes(kEventAttributeNone), &event)
        if let event { SendEventToEventTarget(event, GetApplicationEventTarget()); ReleaseEvent(event) }   // the key pressed, as Carbon delivers it
        waitFor { item.panelShown }
        let pressed = item.panelShown
        item.close()
        waitFor { !item.panelShown }
        NSApp.deactivate()
        check("Keyboard shortcut: record, and pressing it opens the panel", "the recorder's binding → Monitor.setHotKey; the Carbon hot-key event",
              set && pressed, "set \(set) pressed \(pressed)")
        let taken = HotKey.Spec(keyCode: 40, key: "K", modifiers: probe.modifiers)
        var held: EventHotKeyRef?
        RegisterEventHotKey(UInt32(taken.keyCode), taken.carbonModifiers, EventHotKeyID(signature: 0x4532_4532, id: 1), GetApplicationEventTarget(), 0, &held)
        m.setHotKey(taken)
        if let held { UnregisterEventHotKey(held) }
        check("Keyboard shortcut: one that is taken", "the recorder's binding with a combination already registered",
              m.note == "⌃⌥⇧⌘K is already taken by another app or by macOS — try another shortcut." && m.s.hotKey == probe && registered(probe), m.note ?? "-")
        m.note = nil
        m.setHotKey(nil)   // Delete in the recorder
        check("Keyboard shortcut: remove", "the recorder's binding with nil", m.s.hotKey == nil && !registered(probe) && Settings.load(m.defaults).hotKey == nil)
        m.s.replaceSystemIcon = false   // the switch
        let kept = mac.prefs["Battery"] == nil && m.defaults.object(forKey: SystemBattery.originalKey) == nil && MoreRows(monitor: m).summary.contains("Apple's icon kept")
        m.s.replaceSystemIcon = true
        check("Replace the macOS battery icon: switch off and on", "the switch's binding, on the fake battery-item preferences",
              kept && mac.prefs["Battery"] as? NSNumber == 24 && m.defaults.bool(forKey: SystemBattery.positionedKey), "kept \(kept) prefs \(mac.prefs)")
        aiStatus = .available
        reopen(m)
        m.s.insight = true   // Apple Intelligence wording
        waitFor { m.insight.fromAI }
        let phrased = m.aiStatus == .available && m.insight.fromAI && m.insight.text == "Your Mac is at \(m.reading!.percent)% and doing fine."
        m.s.insight = false
        settle()
        check("Apple Intelligence wording: on and off", "the switch (model stood in for)", phrased && !m.insight.fromAI && m.insight.text == Insight.template(m.facts),
              "phrased \(phrased), now “\(m.insight.text)” fromAI \(m.insight.fromAI)")
        aiStatus = .notEnabled
        reopen(m)
        let offered = AppleIntelligence.offersNudge(status: m.aiStatus, dismissed: m.aiNudgeDismissed)
        AppleIntelligence.openSettings()   // Open Settings
        let settings = opened.last?.absoluteString == "x-apple.systempreferences:com.apple.Siri-Settings.extension"
        m.dismissAINudge()   // Not now
        check("Apple Intelligence nudge: Open Settings, Not now", "the nudge's two buttons", offered && settings && !AppleIntelligence.offersNudge(status: m.aiStatus, dismissed: m.aiNudgeDismissed)
                && m.defaults.bool(forKey: "aiNudgeDismissed"), "offered \(offered) settings \(settings)")
        aiStatus = .available
        reopen(m)
        let installs = mac.installs
        m.setUpHelper()   // Reinstall helper…
        check("Reinstall helper…", "the link → Monitor.setUpHelper on the fake installer", mac.installs == installs + 1 && m.helperReady && m.note == nil)
    }

    static func links(_ m: Monitor, _ delegate: AppDelegate) {
        let open = { (text: String) in delegate.application(NSApp, open: [URL(string: text)!]) }
        feed(onAC: false, rate: -8)
        open("juiceleft://savebattery?on=1")
        let saving = m.saving != nil
        open("juiceleft://savebattery?on=0")
        check("juiceleft://savebattery", "the app's URL handler, on=1 then on=0", saving && m.saving == nil)
        synced(m)
        open("juiceleft://mode?set=high")
        synced(m)
        let high = mac.powerRequests.last == "b 2"
        open("juiceleft://mode?set=auto")
        synced(m)
        check("juiceleft://mode", "set=high, then set=auto", high && mac.powerRequests.last == "b 0", "\(mac.powerRequests.suffix(2))")
        m.setChargeLimit(80)
        open("juiceleft://topup")
        check("juiceleft://topup", "with the 80 % limit on", m.travelFull != nil && mac.topUps == 3, "top-ups \(mac.topUps)")
        m.cancelFullForTravel()
        open("juiceleft://monitoring?on=0")
        let off = !m.s.armed
        open("juiceleft://monitoring?on=1")
        check("juiceleft://monitoring", "on=0, then on=1", off && m.s.armed)
        open("juiceleft://snooze")
        check("juiceleft://snooze", "the command", m.snoozedUntil != nil)
        m.resume()
        let settings = m.s, requests = mac.powerRequests.count, topUps = mac.topUps, limits = mac.limitSets.count
        for bad in ["juiceleft://savebattery?on=1&and=delete", "juiceleft://savebattery?on=maybe", "juiceleft://savebattery", "juiceleft://mode?set=turbo",
                    "juiceleft://mode?set=low&set=high", "juiceleft://mode", "juiceleft://topup?x=1", "juiceleft://monitoring?on=", "juiceleft://monitoring?off=1",
                    "juiceleft://snooze?for=999", "juiceleft://wipe?all=1", "juiceleft://?on=1", "https://example.invalid/mode?set=low", "file:///etc/passwd",
                    "juiceleft://savebattery?on=%31%26x", "juiceleft://" + String(repeating: "a", count: 5000) + "?on=1"] {
            open(bad)
        }
        check("juiceleft:// hostile input", "16 malformed, unknown or foreign links through the handler",
              m.s == settings && m.saving == nil && m.snoozedUntil == nil && mac.powerRequests.count == requests && mac.topUps == topUps && mac.limitSets.count == limits)
    }

    static func notch(_ m: Monitor, _ item: StatusItemController) {
        let gap = CGRect(x: 663, y: 949, width: 185, height: 33)
        let neighbour = { (x: CGFloat) in CGRect(x: x, y: 949, width: 36, height: 33) }
        let words = { m.icon.frame.trailing?.hasSuffix("Remaining") == true }
        let compact = { m.icon.frame.trailing?.range(of: #"^\d+:\d\d$"#, options: .regularExpression) != nil }
        item.fakeRoom = (true, [neighbour(900)], nil)
        item.checkRoom()
        let noNotch = !m.squeezed && words()
        item.fakeRoom = (true, [neighbour(766)], gap)
        item.checkRoom()
        let squeezed = m.squeezed && compact()
        let extra = m.itemWidths.words - m.itemWidths.compact
        item.fakeRoom = (true, [neighbour(gap.maxX + StatusItemController.notchMargin + extra - 10)], gap)
        item.checkRoom()
        let stays = m.squeezed && compact()
        item.fakeRoom = (true, [neighbour(gap.maxX + StatusItemController.notchMargin + extra + 10)], gap)
        item.checkRoom()
        check("Notch rule on synthetic layouts", "StatusItemController.checkRoom with a made-up bar: no notch, a neighbour in the gap, just short, clear",
              noNotch && squeezed && stays && !m.squeezed && words(), "no notch \(noNotch) squeezed \(squeezed) stays \(stays) back \(!m.squeezed)")
        m.s.menuBar = .compact
        item.fakeRoom = (true, [neighbour(766)], gap)
        item.checkRoom()
        let ignored = !m.squeezed
        m.s.menuBar = .words
        item.fakeRoom = (false, [], nil)
        item.checkRoom()
        let offScreen = m.squeezed && compact()
        m.setSqueezed(false)   // what the retry does five minutes on
        item.fakeRoom = (true, [], nil)
        check("Menu bar: squeezed out, and the Compact style", "checkRoom with the item off screen; the notch rule with Compact chosen",
              ignored && offScreen && words(), "ignored \(ignored) off screen \(offScreen)")
    }

    static func foot(_ m: Monitor) {
        m.setLoginItem(true)   // Launch at login
        let on = loginOn && LoginItem.isOn && m.note == nil
        loginRefusal = "Operation not permitted"
        m.setLoginItem(false)
        let refused = m.note == "Operation not permitted" && LoginItem.isOn
        loginRefusal = nil
        m.note = nil
        m.setLoginItem(false)
        check("Launch at login", "the checkbox's binding → Monitor.setLoginItem (on, refused, off)", on && refused && !LoginItem.isOn)
        let updater = Updater.shared
        let feed = { (tag: String) in
            Data(#"{"tag_name":"\#(tag)","draft":false,"prerelease":false,"html_url":"https://github.com/Weta-Technologies/JuiceLeft/releases/tag/\#(tag)","body":"Test notes","assets":[{"name":"JuiceLeft.app.zip","browser_download_url":"https://example.invalid/JuiceLeft.app.zip"},{"name":"JuiceLeft.app.zip.sig","browser_download_url":"https://example.invalid/JuiceLeft.app.zip.sig"}]}"#.utf8)
        }
        let checking = { if case .checking = updater.state { return true }; return false }
        Feed.status = 200; Feed.body = feed("v9.9.9")
        updater.check(manual: true)   // Check Now
        waitFor(5) { !checking() }
        let offered = updater.available?.version.description == "9.9.9"
        updater.later()   // Later
        let later = updater.available == nil
        updater.check(manual: true)
        waitFor(5) { !checking() }
        updater.skip()   // Skip
        updater.check(manual: false)   // the daily check honours the skip
        waitFor(5) { !checking() }
        let skipped = updater.state == .upToDate
        Feed.body = feed("v1.0.0")
        updater.check(manual: true)
        waitFor(5) { !checking() }
        let upToDate = updater.state == .upToDate
        Feed.status = 500
        updater.check(manual: true)
        waitFor(5) { !checking() }
        let failed = updater.state == .failed(nil, "Couldn't check for updates: GitHub answered 500")
        check("Check Now (a stubbed feed, never a download)", "Updater.check(manual:), as the button; Later, Skip, up to date, a failure",
              offered && later && skipped && upToDate && failed && Feed.requests.count == 5 && Feed.requests.allSatisfy { $0.path.hasSuffix("/releases/latest") },
              "offered \(offered) later \(later) skipped \(skipped) upToDate \(upToDate) failed \(failed) requests \(Feed.requests.map(\.path))")
        updater.automatic = false   // Check for updates automatically
        let auto = UserDefaults.standard.object(forKey: "updates.automatic") as? Bool == false
        updater.automatic = true
        check("Check for updates automatically", "the checkbox's binding", auto && UserDefaults.standard.bool(forKey: "updates.automatic"))
        NSApp.terminate(nil)   // Quit's action
        check("Quit", "NSApp.terminate, as the Quit button (intercepted)", quitAsks == 1)
    }

    static func ending(_ m: Monitor, _ defaults: UserDefaults) {
        skip("Real clicks, holds and hovers on the menu bar", "never synthesised on the real menu bar; the item's own handlers were called instead")
        skip("Pressing controls through accessibility", "SwiftUI shows an off-screen panel's buttons and switches to no accessibility client (only the two segmented pickers); each control's binding or action was driven instead")
        skip("Footer links (Licence, Privacy, GitHub), What's new…", "SwiftUI links with no action to call; the panel's openURL is stood in for, but nothing presses them")
        skip("The process-monitor button (Using the most power)", "an inline action that would launch a real app")
        skip("System & background: the disclosure itself", "view state inside the card; the rows it shows were checked from the ranking")
        skip("Charging light with the lid closed, and 2 s after it opens", "the lid only changes through an IOKit notification; the rule is covered by --selftest")
        skip("Update Now (download, verify, swap, relaunch)", "test-update.sh does it against a local server; here the feed never offers a download")
        skip("The real helper, pmset, charge limit, MagSafe light, battery item, login item, notifications, screen and keyboard", "the safety rules: FakeMac, FakeHardware and the stand-ins above took every call")
        skip("The on-device language model", "stood in for; its real wording varies")
        skip("Timers left to run: the 5-minute squeeze retry, the 10-minute accessory poll, the 60 s mode refresh", "not waited for; what each one calls was exercised directly")
        skip("A click elsewhere closing the panel; the haptic tap on hold", "a synthesised click outside the app, and hardware feedback")
        check("Settings persist", "Settings.load from the suite after every change above", Settings.load(defaults) == m.s, "\(Settings.load(defaults)) vs \(m.s)")
        let ids = Set(posted.map(\.id))
        check("Every notification, stubbed", "the payloads recorded above", ids == ["warning", "alert", "heat", "device-trackpad", "device-mouse", "plug", "unplug", "full"],
              "\(ids.sorted())")
        let lines = mac.lightLines.count
        NotificationCenter.default.post(name: NSApplication.willTerminateNotification, object: NSApp)   // what a real quit sends
        check("On quit: Apple's icon back, history saved", "the will-terminate notification",
              mac.prefs["Battery"] == nil && History.load(from: out.appendingPathComponent("history.json")) == m.history && mac.lightLines.count == lines,
              "prefs \(mac.prefs)")
    }
}
