import Combine
import FamilyControls
import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var model: AppModel
    @StateObject private var location = LocationPermission()
    @StateObject private var signal = BeaconSignal()
    @ObservedObject private var broadcaster = BeaconBroadcaster.shared
    @ObservedObject private var hub = HubMonitor.shared
    @ObservedObject private var blueCharm = BlueCharm.shared
    @Environment(\.scenePhase) private var scenePhase

    @State private var showingPicker = false
    @State private var pickerSelection = FamilyActivitySelection()
    @State private var editingBeacon = false
    /// Opens on Setup until a bedroom beacon is set; the main screen is one Back away.
    @State private var path: [Screen] = Shared.beacon == nil ? [.setup] : []

    /// Keeps the status card current if bedtime starts while the app is open.
    private let ticker = Timer.publish(every: 30, on: .main, in: .common).autoconnect()

    /// The spare-device stand-in is watched over Bluetooth, so it needs a boundary instead of location.
    private var usesStandIn: Bool { model.beacon?.isStandIn == true }

    private var setupDone: Bool { setupStepsLeft == 0 }

    /// Unfinished rows of the setup checklist.
    private var setupStepsLeft: Int {
        var left = 0
        if !model.screenTimeApproved { left += 1 }
        if model.selection.isEmptySelection { left += 1 }
        if model.beacon == nil { left += 1 }
        if usesStandIn {
            if hub.boundary == nil || hub.link == .notAllowed { left += 1 }
        } else if !location.isReady {
            left += 1
        }
        return left
    }

    var body: some View {
        NavigationStack(path: $path) {
            mainScreen
                .navigationDestination(for: Screen.self) { screen in
                    switch screen {
                    case .setup: setupScreen
                    case .beaconDetails: beaconDetailsScreen
                    }
                }
        }
        .familyActivityPicker(isPresented: $showingPicker, selection: $pickerSelection)
        .onChange(of: showingPicker) { _, isShowing in
            if !isShowing { model.saveSelection(pickerSelection) }
        }
        .sheet(isPresented: $editingBeacon) {
            BeaconEditor(
                current: model.beacon,
                onSave: { model.saveBeacon($0) },
                onSetUpBlueCharm: { model.saveBlueCharm($0) }
            )
        }
        .task {
            signal.watch(model.beacon)
            blueCharm.watchSignal(of: model.blueCharm)
            hub.setForeground(true)
            broadcaster.restore()
            await model.refreshEverything()
        }
        .onChange(of: model.beacon) { _, beacon in signal.watch(beacon) }
        .onChange(of: model.blueCharm?.peripheralID) { _, _ in
            if scenePhase != .background { blueCharm.watchSignal(of: model.blueCharm) }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .background {
                signal.stop()
                blueCharm.watchSignal(of: nil)
                hub.setForeground(false)
                broadcaster.suspend()
            }
            guard phase == .active else { return }
            location.refresh()
            signal.watch(model.beacon)
            blueCharm.watchSignal(of: model.blueCharm)
            hub.setForeground(true)
            broadcaster.resume()
            Task { await model.refreshEverything() }
        }
        .onReceive(ticker) { _ in model.reload() }
    }

    // MARK: - Screens

    /// The one main screen: what gets blocked and when.
    private var mainScreen: some View {
        Form {
            Section {
                // Until setup is done the card itself says what's left and opens Setup.
                Button {
                    if !setupDone { path.append(.setup) }
                } label: {
                    StatusCard(
                        setupDone: setupDone,
                        setupStepsLeft: setupStepsLeft,
                        isBlocking: model.isBlocking,
                        inRoom: model.inRoom,
                        anyTime: !model.schedule.limitToHours,
                        tonight: model.schedule.currentNight(),
                        testEndsAt: model.testEndsAt
                    )
                }
                .buttonStyle(.plain)
                .allowsHitTesting(!setupDone)
            }
            .listRowInsets(EdgeInsets())
            .listRowBackground(Color.clear)

            if broadcaster.isOn { broadcastingSection }
            appsSection
            hoursSection
            if model.screenTimeApproved && !model.selection.isEmptySelection { tryItSection }
        }
        .navigationTitle("Goodnight Phone")
        .brandForm()
        .readableWidth()
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                NavigationLink(value: Screen.setup) {
                    Image(systemName: "gearshape")
                }
                .accessibilityLabel("Setup")
            }
        }
    }

    /// Permissions, the bedroom beacon, and the rarely needed rest (Activity, privacy).
    private var setupScreen: some View {
        Form {
            if !setupDone { setupSection }
            bedroomCardSection
            bedroomLinksSection
            moreSection
        }
        .navigationTitle("Setup")
        .brandForm()
        .readableWidth()
    }

    // MARK: - Sections

    private var setupSection: some View {
        Section {
            SetupRow(
                title: "Screen Time access",
                detail: model.screenTimeApproved ? "Allowed" : "Lets Goodnight Phone block apps",
                done: model.screenTimeApproved,
                button: "Continue"
            ) { Task { await model.requestScreenTime() } }

            if !usesStandIn {
                SetupRow(
                    title: "Location: Always + Precise",
                    detail: location.label,
                    done: location.isReady,
                    button: location.status == .notDetermined ? "Continue" : "Fix"
                ) { location.request() }
            }

            SetupRow(
                title: "Apps to block",
                detail: model.selection.summary,
                done: !model.selection.isEmptySelection,
                button: "Choose",
                enabled: model.screenTimeApproved
            ) { openPicker() }

        } header: {
            BrandHeader("Checklist")
        } footer: {
            Text(usesStandIn
                 ? "Your phone stays connected to the spare device. During bedtime hours it checks the signal every 2 seconds, even when Goodnight Phone is closed. Nothing is blocked until the boundary is set."
                 : "“Always” location lets iOS wake Goodnight Phone when you walk into the bedroom, even when the app is closed. Beacon detection needs Precise Location.")
        }
        .brandRow()
    }

    private var appsSection: some View {
        Section {
            if model.selection.isEmptySelection {
                Text("No apps selected").foregroundStyle(.secondary)
            }
            let selection = model.selection
            if selection.categoryTokens.isEmpty {
                ForEach(Array(selection.applicationTokens), id: \.self) { Label($0) }
                ForEach(Array(selection.webDomainTokens), id: \.self) { Label($0) }
            } else {
                // A ticked category also adds each of its apps and sites by name (so iOS can't
                // skip one), and the picker doesn't say which were picked one by one. So list
                // the categories and give one total that includes them.
                ForEach(Array(selection.categoryTokens), id: \.self) { Label($0) }
                Text(selection.coverage)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            Button("Choose apps…") { openPicker() }
                .disabled(!model.screenTimeApproved || model.isLocked)
        } header: {
            BrandHeader("The goodnight list")
        } footer: {
            appsFooter
        }
        .brandRow()
    }

    private var tryItSection: some View {
        Section {
            if model.testEndsAt != nil {
                Button("Stop test", role: .destructive) { model.stopTestBlock() }
            } else {
                Button("Block these apps for 2 minutes") { model.startTestBlock() }
                    .disabled(model.isBlocking)
            }
        } header: {
            BrandHeader("Try it now")
        } footer: {
            if let end = model.testEndsAt {
                Text("Test running. Open a blocked app to see the screen. It ends at \(end.formatted(date: .omitted, time: .shortened)), or tap Stop test.")
            } else {
                Text("See what blocking looks like without a beacon. You can stop the test early; that never lifts a real bedtime block.")
            }
        }
        .brandRow()
    }

    private var hoursSection: some View {
        Section {
            Toggle("Only during bedtime hours", isOn: scheduleBinding(\.limitToHours))
            if model.schedule.limitToHours {
                NightToggles()
                DatePicker("Starts", selection: timeBinding(\.startMinutes), displayedComponents: .hourAndMinute)
                DatePicker("Ends", selection: timeBinding(\.endMinutes), displayedComponents: .hourAndMinute)
                NavigationLink { NightsView() } label: {
                    LabeledContent("Hours by night", value: model.schedule.nightsSummary)
                }
            }
        } header: {
            BrandHeader("When")
        } footer: {
            Text(model.schedule.limitToHours
                 ? "Tap a day to take that night off. A night runs from its start into the next morning, so Friday is Friday evening to Saturday morning. Blocking starts at bedtime even if you're already in bed."
                 : "Apps are blocked any time you're in the bedroom.")
        }
        .brandRow()
        .disabled(model.isLocked)
    }

    /// The bedroom beacon at a glance: what's missing during setup, then in or out of the room,
    /// with the hub's signal drawn against the doorway. The numbers live in Beacon details.
    private var bedroomCardSection: some View {
        Section {
            BedroomCard(
                beacon: model.beacon,
                inRoom: model.inRoom,
                isBlocking: model.isBlocking,
                isLocked: model.isLocked,
                linkLabel: hub.linkLabel,
                isListening: hub.isListening,
                isCalibrating: hub.isCalibrating,
                rssi: hub.rssi,
                boundary: hub.boundary,
                addBeacon: { editingBeacon = true },
                markDoorway: { hub.calibrate() }
            )
        } header: {
            BrandHeader("Bedroom beacon")
        }
        .listRowInsets(EdgeInsets())
        .listRowBackground(Color.clear)
    }

    private var bedroomLinksSection: some View {
        Section {
            // Read-only, so it stays open while apps are blocked.
            NavigationLink { BeaconPlacementGuide() } label: {
                Label("Where to put the beacon", systemImage: "lightbulb")
            }
            if model.beacon == nil {
                Link(destination: AppLinks.chooseHub) {
                    Label("Get a hub kit (about $36)", systemImage: "cart")
                }
            } else if usesStandIn && hub.boundary == nil {
                Button("Use a different beacon…") { editingBeacon = true }
                    .disabled(model.isLocked)
            } else {
                NavigationLink(value: Screen.beaconDetails) {
                    Label("Beacon details", systemImage: "slider.horizontal.3")
                }
            }
        } footer: {
            if model.beacon == nil {
                Text("Have a spare iPad or iPhone? It can be your hub for free: tap Add a beacon, then Spare iPad or iPhone.")
            } else if usesStandIn && hub.boundary == nil {
                Text("Stand right in the bedroom doorway, not by the bed. It takes a few seconds, and you can redo it later in Beacon details.")
            } else if model.isLocked {
                Text("Locked while you're in the bedroom. Leave the room to make changes.")
            }
        }
        .brandRow()
    }

    /// Everything technical about the beacon: connection, signal, the doorway mark, range.
    private var beaconDetailsScreen: some View {
        Form {
            Section {
                if let beacon = model.beacon {
                    LabeledContent("Beacon", value: beacon.displayName)
                    if beacon.isStandIn {
                        LabeledContent("Connection", value: hub.linkLabel)
                        LabeledContent("Signal") {
                            HStack(spacing: 6) {
                                Text(hub.rssi.map { "\($0) dBm" } ?? "—")
                                Image(systemName: "cellularbars", variableValue: hub.strength)
                            }
                        }
                        LabeledContent("Doorway mark", value: hub.boundary.map { "\($0) dBm" } ?? "Not set")
                    } else if let pairing = model.blueCharm {
                        // A Blue Charm's signal comes straight from its Bluetooth advertising.
                        LabeledContent("Signal") {
                            HStack(spacing: 6) {
                                Text(blueCharm.signalRSSI.map { "\($0) dBm" } ?? "Not detected")
                                Image(systemName: "cellularbars", variableValue: BeaconSignal.strength(rssi: blueCharm.signalRSSI))
                            }
                        }
                        BlueCharmRange(pairing: pairing)
                    } else {
                        LabeledContent("Signal") {
                            HStack(spacing: 6) {
                                Text(signal.label)
                                Image(systemName: "cellularbars", variableValue: signal.strength)
                            }
                        }
                    }
                }
            } header: {
                BrandHeader("Bedroom beacon")
            } footer: {
                Text(usesStandIn
                     ? "Stronger than the doorway mark counts as in the bedroom. During bedtime hours, walking in registers within about 10 seconds and leaving within about 15, even with the app closed."
                     : model.blueCharm != nil
                     ? "Signal is live while the app is open. iOS takes about 30 seconds to register that you've left. If it still says “In the bedroom” after you step out of the room, tap Shorter; if it says “Outside” by the bed, tap Longer. For 15 minutes after setup these work even while apps are blocked."
                     : "Signal is live while the app is open. iOS takes about 30 seconds to register that you've left. If it still says “In the bedroom” after you step out of the room, turn the beacon's transmit power down.")
            }
            .brandRow()

            Section {
                if usesStandIn {
                    Button(hub.isCalibrating ? "Measuring…" : "Mark doorway again") { hub.calibrate() }
                        .disabled(model.isLocked || !hub.isListening || hub.isCalibrating)
                }
                Button("Change beacon…") { editingBeacon = true }
                    .disabled(model.isLocked)
            } footer: {
                if usesStandIn {
                    Text("To mark the doorway again, stand right in the bedroom doorway, not by the bed.")
                }
            }
            .brandRow()
        }
        .navigationTitle("Beacon details")
        .navigationBarTitleDisplayMode(.inline)
        .brandForm()
        .readableWidth()
    }

    /// Shown at the top while this device is the stand-in beacon. Its settings link stays put
    /// in More on the Setup screen (moving a NavigationLink would pop its screen).
    private var broadcastingSection: some View {
        Section {
            LabeledContent {
                Text(broadcaster.label)
            } label: {
                Label("Stand-in beacon", systemImage: "dot.radiowaves.left.and.right")
            }
        } footer: {
            Text("This device is standing in for the bedroom beacon. Keep Goodnight Phone open, plugged in, by the bed.")
        }
        .brandRow()
    }

    private var moreSection: some View {
        Section {
            NavigationLink { ActivityView() } label: {
                Label("Activity", systemImage: "clock.arrow.circlepath")
            }
            // Only for a spare device that stays by the bed, so it lives down here.
            NavigationLink { StandInBeaconView() } label: {
                LabeledContent {
                    Text(broadcaster.label)
                } label: {
                    Label("Use this device as a bedroom hub", systemImage: "dot.radiowaves.left.and.right")
                }
            }
            Link(destination: AppLinks.privacyPolicy) {
                Label("Privacy policy", systemImage: "hand.raised")
            }
        } header: {
            BrandHeader("More")
        } footer: {
            Text("Everything Goodnight Phone stores stays on this iPhone. In an emergency, turn Goodnight Phone off in Settings → Screen Time → Apps with Screen Time Access to lift every block.")
        }
        .brandRow()
    }

    @ViewBuilder private var appsFooter: some View {
        if model.isLocked {
            Text("Locked while you're in the bedroom. Leave the room to make changes.")
        } else if model.selection.exceedsShieldLimit {
            Text("That's more apps or sites than Goodnight Phone can block (\(Blocker.tokensPerStore * Blocker.maxStores) each). Pick whole categories to cover more.")
                .foregroundStyle(.orange)
        }
    }

    // MARK: - Helpers

    private func openPicker() {
        // includeEntireCategory: ticking a category also adds each of its apps by name.
        // iOS's category block skipped Instagram on a real phone while blocking it by name
        // worked, so Blocker shields both (split across stores past 50 apps).
        if model.selection.includeEntireCategory {
            pickerSelection = model.selection
        } else {
            var selection = FamilyActivitySelection(includeEntireCategory: true)
            selection.applicationTokens = model.selection.applicationTokens
            selection.categoryTokens = model.selection.categoryTokens
            selection.webDomainTokens = model.selection.webDomainTokens
            pickerSelection = selection
        }
        showingPicker = true
    }

    private func scheduleBinding(_ keyPath: WritableKeyPath<BedtimeSchedule, Bool>) -> Binding<Bool> {
        Binding(
            get: { model.schedule[keyPath: keyPath] },
            set: { newValue in
                var schedule = model.schedule
                schedule[keyPath: keyPath] = newValue
                model.saveSchedule(schedule)
            }
        )
    }

    private func timeBinding(_ keyPath: WritableKeyPath<BedtimeSchedule, Int>) -> Binding<Date> {
        Binding(
            get: { BedtimeSchedule.date(fromMinutes: model.schedule[keyPath: keyPath]) },
            set: { newValue in
                var schedule = model.schedule
                schedule[keyPath: keyPath] = BedtimeSchedule.minutes(from: newValue)
                model.saveSchedule(schedule)
            }
        )
    }
}

/// Screens pushed from the main screen.
private enum Screen: Hashable {
    case setup
    case beaconDetails
}

// MARK: - Activity

/// What Goodnight Phone did and when (blocks, room changes). Moved off the main screen.
private struct ActivityView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        Form {
            Section {
                if model.log.isEmpty {
                    Text("Nothing yet").foregroundStyle(.secondary)
                }
                ForEach(model.log.prefix(50)) { entry in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(entry.message)
                        Text(entry.date, format: .dateTime.weekday(.abbreviated).hour().minute())
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .brandRow()
        }
        .navigationTitle("Activity")
        .navigationBarTitleDisplayMode(.inline)
        .brandForm()
        .readableWidth()
    }
}

// MARK: - Status card

private struct StatusCard: View {
    let setupDone: Bool
    let setupStepsLeft: Int
    let isBlocking: Bool
    let inRoom: Bool
    let anyTime: Bool
    /// Tonight's hours (or last night's, until they end); nil on a night off.
    let tonight: String?
    let testEndsAt: Date?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 30, weight: .semibold))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(iconColor)
                .padding(.bottom, 4)
            Text(title)
                .font(Brand.heading(28))
            Text(subtitle)
                .font(.system(.subheadline, design: .rounded).weight(.semibold))
                .opacity(0.9)
        }
        .foregroundStyle(textColor)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(20)
        .background(fill, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).strokeBorder(Brand.fixedInk, lineWidth: 2.5))
        // A solid offset shadow, like ink on a printed page.
        .background(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(Brand.fixedInk)
                .offset(x: 4, y: 4)
        )
        .padding(.trailing, 4)
        .padding(.bottom, 4)
        .animation(.easeInOut, value: isBlocking)
    }

    private var icon: String {
        if isBlocking { return "moon.zzz.fill" }
        if !setupDone { return "wrench.and.screwdriver.fill" }
        if inRoom { return "bed.double.fill" }
        return "sun.max.fill"
    }

    private var title: String {
        if isBlocking { return "Apps asleep" }
        if !setupDone { return "Finish setup" }
        if inRoom { return "In the bedroom" }
        return "Not in the bedroom"
    }

    private var subtitle: String {
        if isBlocking, let testEndsAt {
            return "Test block. They wake up at \(testEndsAt.formatted(date: .omitted, time: .shortened))."
        }
        if isBlocking { return "They wake up when you leave the room." }
        if !setupDone {
            let steps = setupStepsLeft == 1 ? "1 step left" : "\(setupStepsLeft) steps left"
            return "\(steps), then it runs on its own. Tap to continue."
        }
        if anyTime { return "Apps block whenever you walk in." }
        guard let tonight else {
            return inRoom ? "Tonight's a night off, so nothing's blocked." : "Tonight's a night off, so nothing will block."
        }
        if inRoom { return "Outside bedtime hours (\(tonight)), so nothing's blocked." }
        return "Apps block when you walk in, \(tonight)."
    }

    /// Night window when apps are asleep, nursery green in the bedroom, moon yellow outside it.
    private var fill: Color {
        if isBlocking { return Brand.night }
        if !setupDone { return Brand.cream }
        if inRoom { return Color(red: 0x2F / 255, green: 0x6B / 255, blue: 0x45 / 255) }
        return Color(red: 0xF2 / 255, green: 0xC8 / 255, blue: 0x49 / 255)
    }

    private var textColor: Color {
        isBlocking || (setupDone && inRoom) ? Brand.cream : Brand.fixedInk
    }

    private var iconColor: Color {
        if isBlocking { return Color(red: 0xF2 / 255, green: 0xC8 / 255, blue: 0x49 / 255) }
        if setupDone && !inRoom { return Color(red: 0xC2 / 255, green: 0x3B / 255, blue: 0x2E / 255) }
        return textColor
    }
}

// MARK: - Bedroom card

/// The Setup screen's night-window card. During setup it asks for the one thing missing (a
/// beacon, then the doorway mark); afterwards it says in or out of the bedroom, and for a hub
/// or spare device draws you and the doorway on a line from far away to the bed.
private struct BedroomCard: View {
    let beacon: BeaconConfig?
    let inRoom: Bool
    let isBlocking: Bool
    let isLocked: Bool
    let linkLabel: String
    let isListening: Bool
    let isCalibrating: Bool
    let rssi: Int?
    let boundary: Int?
    let addBeacon: () -> Void
    let markDoorway: () -> Void

    private var isStandIn: Bool { beacon?.isStandIn == true }
    private var needsDoorway: Bool { isStandIn && boundary == nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if beacon == nil || needsDoorway { stepDots }
            HStack(alignment: .top) {
                Text(title)
                    .font(Brand.heading(25))
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 12)
                Image(systemName: "moon.fill")
                    .font(.system(size: 26))
                    .foregroundStyle(Brand.yellow)
            }
            subtitleView
            if isStandIn {
                DoorwayMeter(rssi: rssi, boundary: boundary)
                    .padding(.top, 14)
            }
            if beacon == nil {
                Button("Add a beacon", action: addBeacon)
                    .buttonStyle(MoonButtonStyle())
                    .padding(.top, 12)
            } else if needsDoorway {
                Button(isCalibrating ? "Measuring…" : "Mark doorway here", action: markDoorway)
                    .buttonStyle(MoonButtonStyle())
                    .disabled(isLocked || !isListening || isCalibrating)
                    .padding(.top, 12)
            }
        }
        .foregroundStyle(Brand.cream)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(20)
        .background(Brand.night, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).strokeBorder(Brand.fixedInk, lineWidth: 2.5))
        // A solid offset shadow, like ink on a printed page (matches the main screen's card).
        .background(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(Brand.fixedInk)
                .offset(x: 4, y: 4)
        )
        .padding(.trailing, 4)
        .padding(.bottom, 4)
        .animation(.easeInOut, value: inRoom)
        .animation(.easeInOut, value: boundary)
    }

    /// Two short bars: beacon, then doorway.
    private var stepDots: some View {
        HStack(spacing: 6) {
            Capsule().fill(Brand.yellow).frame(width: 22, height: 4)
            Capsule().fill(beacon == nil ? Brand.cream.opacity(0.25) : Brand.yellow).frame(width: 22, height: 4)
        }
        .padding(.bottom, 4)
        .accessibilityElement()
        .accessibilityLabel(beacon == nil ? "Step 1 of 2" : "Step 2 of 2")
    }

    private var title: String {
        if beacon == nil { return "Add your bedroom beacon" }
        if needsDoorway { return "Walk to your doorway" }
        return inRoom ? "In the bedroom" : "Outside the bedroom"
    }

    @ViewBuilder private var subtitleView: some View {
        let font = Font.system(.subheadline, design: .rounded).weight(.semibold)
        if beacon == nil {
            Text("A small Bluetooth hub or beacon by your bed tells your phone when you're in the bedroom.")
                .font(font).opacity(0.85)
                .fixedSize(horizontal: false, vertical: true)
        } else if needsDoorway {
            Text(isListening ? "Bedroom hub found. Watch the dot move as you walk." : linkLabel)
                .font(font).opacity(0.85)
        } else if isBlocking {
            Text("Apps asleep until you leave the room.")
                .font(font).opacity(0.85)
        } else if isStandIn {
            HStack(spacing: 6) {
                Circle()
                    .fill(isListening ? Color(red: 0x7F / 255, green: 0xCF / 255, blue: 0x95 / 255) : Brand.yellow)
                    .frame(width: 8, height: 8)
                Text(isListening ? "Bedroom hub is working" : linkLabel)
            }
            .font(font).opacity(0.85)
        } else if let beacon {
            Text(beacon.displayName)
                .font(font).opacity(0.85)
        }
    }
}

/// A line from far away to the bed, with the doorway mark (once set) and a dot for where the
/// hub's signal puts you. Display only; the in/out decision is RoomPresenceStateMachine's.
private struct DoorwayMeter: View {
    let rssi: Int?
    let boundary: Int?

    /// Signal range drawn end to end, in dBm.
    private static let far = -100.0
    private static let near = -45.0

    private static func position(_ dBm: Int) -> Double {
        min(max((Double(dBm) - far) / (near - far), 0.03), 0.97)
    }

    private let green = Color(red: 0x5B / 255, green: 0x8C / 255, blue: 0x69 / 255)
    private let track = Color(red: 0x3A / 255, green: 0x4A / 255, blue: 0x68 / 255)

    var body: some View {
        VStack(spacing: 4) {
            GeometryReader { geo in
                let width = geo.size.width
                ZStack(alignment: .leading) {
                    Capsule().fill(track).frame(height: 10)
                    if let boundary {
                        let x = width * Self.position(boundary)
                        Capsule().fill(green)
                            .frame(width: width - x, height: 10)
                            .offset(x: x)
                        Rectangle().fill(Brand.yellow)
                            .frame(width: 2, height: 36)
                            .offset(x: x - 1)
                        Text("doorway")
                            .font(.system(size: 11, weight: .semibold, design: .rounded))
                            .foregroundStyle(Brand.yellow)
                            .fixedSize()
                            .position(x: x, y: 44)
                    }
                    if let rssi {
                        Circle()
                            .fill(Brand.cream)
                            .overlay(Circle().strokeBorder(Brand.yellow, lineWidth: 3))
                            .frame(width: 22, height: 22)
                            .offset(x: width * Self.position(rssi) - 11)
                            .animation(.easeInOut(duration: 0.6), value: rssi)
                    }
                }
                .frame(height: 36)
            }
            .frame(height: boundary == nil ? 36 : 52)
            HStack {
                Text("Farther away")
                Spacer()
                Text("By the bed")
            }
            .font(.system(size: 11, design: .rounded))
            .opacity(0.7)
        }
        .accessibilityElement()
        .accessibilityLabel(accessibilityText)
    }

    private var accessibilityText: String {
        guard let rssi else { return "No signal from the bedroom hub" }
        guard let boundary else { return "Signal \(rssi) dBm" }
        return rssi >= boundary ? "Past the doorway mark" : "Short of the doorway mark"
    }
}

/// Moon-yellow button on the night card.
private struct MoonButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(.headline, design: .rounded).weight(.bold))
            .foregroundStyle(Brand.night)
            .frame(maxWidth: .infinity, minHeight: 48)
            .background(Brand.yellow, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .opacity(isEnabled ? (configuration.isPressed ? 0.8 : 1) : 0.45)
    }
}

// MARK: - Setup row

private struct SetupRow: View {
    let title: String
    let detail: String
    let done: Bool
    let button: String
    var enabled: Bool = true
    let action: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: done ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(done ? Color.green : Color.secondary)
                .font(.title3)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if !done {
                Button(button, action: action)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .disabled(!enabled)
            }
        }
    }
}

// MARK: - Beacon editor

private struct BeaconEditor: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var blueCharm = BlueCharm.shared
    private let current: BeaconConfig?
    @State private var saved: [BeaconConfig]
    private let onSave: (BeaconConfig?) -> Void
    private let onSetUpBlueCharm: (BlueCharmPairing) -> Void

    init(
        current: BeaconConfig?,
        onSave: @escaping (BeaconConfig?) -> Void,
        onSetUpBlueCharm: @escaping (BlueCharmPairing) -> Void
    ) {
        self.current = current
        var saved = Shared.savedBeacons
        if let current, !saved.contains(current) { saved.insert(current, at: 0) }
        _saved = State(initialValue: saved)
        self.onSave = onSave
        self.onSetUpBlueCharm = onSetUpBlueCharm
    }

    private func pick(_ beacon: BeaconConfig?) {
        onSave(beacon)
        dismiss()
    }

    var body: some View {
        NavigationStack {
            Form {
                if !saved.isEmpty {
                    Section {
                        ForEach(saved, id: \.self) { beacon in
                            Button { pick(beacon) } label: {
                                HStack {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(beacon.displayName).foregroundStyle(Color.primary)
                                        Text(detail(for: beacon)).font(.caption).foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    if beacon == current {
                                        Image(systemName: "checkmark").foregroundStyle(Color.accentColor)
                                    }
                                }
                            }
                            // The current beacon stays listed; switch away first to remove it.
                            .deleteDisabled(beacon == current)
                        }
                        .onDelete { offsets in
                            saved.remove(atOffsets: offsets)
                            Shared.savedBeacons = saved
                        }
                    } header: {
                        BrandHeader("Your beacons")
                    } footer: {
                        Text("Tap one to switch to it.")
                    }
                    .brandRow()
                }

                // Named by the device itself, since a new user won't know our terms
                // ("bedroom hub") for each device. Each row opens that device's own setup steps.
                Section {
                    NavigationLink {
                        HubSetupView(isCurrent: current?.isStandIn == true) { pick(BeaconConfig.standIn) }
                    } label: {
                        DeviceRow(
                            "Seeed XIAO board",
                            detail: "A thumbnail-sized board. The most precise.",
                            systemImage: "cpu"
                        )
                    }

                    // Blue Charm is no longer recommended: only someone who already set one up
                    // here sees it, so they can set it up again (say, after a reset).
                    if Shared.blueCharm != nil {
                        NavigationLink {
                            BlueCharmSetupView { pairing in
                                onSetUpBlueCharm(pairing)
                                dismiss()
                            }
                        } label: {
                            DeviceRow(
                                "Blue Charm beacon",
                                detail: "The one you set up before.",
                                systemImage: "antenna.radiowaves.left.and.right"
                            )
                        }
                    }

                    NavigationLink {
                        SpareDeviceSetupView(isCurrent: current?.isStandIn == true) { pick(BeaconConfig.standIn) }
                    } label: {
                        DeviceRow(
                            "Spare iPad or iPhone",
                            detail: "Running Goodnight Phone, left on by the bed.",
                            systemImage: "ipad.and.iphone"
                        )
                    }

                    NavigationLink {
                        OtherBeaconForm(current: current?.isStandIn == false ? current : nil) { pick($0) }
                    } label: {
                        DeviceRow("Another iBeacon", detail: "Type in its UUID.", systemImage: "number")
                    }

                    NavigationLink { NoBeaconView() } label: {
                        DeviceRow(
                            "I don't have one yet",
                            detail: "See which one we recommend.",
                            systemImage: "cart"
                        )
                    }
                } header: {
                    BrandHeader("Which beacon do you have?")
                }
                .brandRow()

                Section {
                    NavigationLink { BeaconPlacementGuide() } label: {
                        Label("Where to put it", systemImage: "lightbulb")
                    }
                }
                .brandRow()

                if current != nil {
                    Section {
                        Button("Remove beacon", role: .destructive) { pick(nil) }
                    }
                    .brandRow()
                }
            }
            .navigationTitle("Bedroom beacon")
            .brandForm()
            .readableWidth()
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
    }

    private func detail(for beacon: BeaconConfig) -> String {
        if beacon.isStandIn { return "XIAO board or spare iPad/iPhone. Set the door boundary again after switching." }
        if Shared.blueCharm?.uuid == beacon.uuid { return "Set up in Goodnight Phone" }
        return "iBeacon"
    }
}

/// Setting up a bedroom hub: get the parts, install it from a computer, plug it in by the bed.
/// The app never links to a store (the website holds the shopping links), and the install needs
/// Chrome or Edge on a computer, so the app shares that link instead of opening it.
private struct HubSetupView: View {
    let isCurrent: Bool
    let onUse: () -> Void
    @StateObject private var finder = HubFinder()

    var body: some View {
        Form {
            // Coming back from the computer, this is the first thing on screen.
            if finder.state == .found && !isCurrent {
                Section {
                    Button(action: onUse) {
                        Label("Use this board", systemImage: "checkmark.circle.fill").bold()
                    }
                } header: {
                    BrandHeader("Found your board")
                } footer: {
                    Text("If it's still plugged into the computer, move it to a charger by your bed first. After you tap Use this board, stand in the bedroom doorway and tap Mark doorway here.")
                }
                .brandRow()
            }

            Section {
                Text("A thumbnail-sized Bluetooth board that stays plugged in by your bed as your bedroom hub. You set exactly where the bedroom ends by standing in the doorway, and walking out lifts the block within seconds. One board works for up to three phones, each with its own bedtime.")
            }
            .brandRow()

            Section {
                Link(destination: AppLinks.buyHubKit) {
                    Label("Add the parts to your Amazon cart", systemImage: "cart")
                }
                Link(destination: AppLinks.chooseHub) {
                    Label("What's in the kit", systemImage: "list.bullet")
                }
            } header: {
                BrandHeader("1. Get the parts")
            } footer: {
                Text("A Seeed XIAO ESP32-C6, a small USB-C adapter and an outlet cube for by the bed, about $36 together. \(AppLinks.amazonDisclosure)")
            }
            .brandRow()

            Section {
                ShareLink(item: AppLinks.hubInstall) {
                    Label("Send the install link to your computer", systemImage: "laptopcomputer")
                }
            } header: {
                BrandHeader("2. Install it from a computer")
            } footer: {
                Text("Open the link in Chrome or Edge on a Mac or PC, plug the board in with a USB-C cable and click Install. It takes about a minute, once. An iPhone or iPad can't do this step.")
            }
            .brandRow()

            Section {
                HubFinderRow(finder: finder, thing: "board")
                Button(isCurrent ? "This is your bedroom beacon" : "Use this board", action: onUse)
                    .disabled(isCurrent)
            } header: {
                BrandHeader("3. Plug it in by the bed")
            } footer: {
                Text("Put it on the far side of the bed from the door. Your iPhone finds it on its own once it's installed and plugged in. Then tap Use this board, stand in the bedroom doorway and tap Mark doorway here.")
            }
            .brandRow()
        }
        .animation(.default, value: finder.state)
        .navigationTitle("Seeed XIAO board")
        .brandForm()
        .readableWidth()
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { finder.start() }
        .onDisappear { finder.stop() }
    }
}

/// Whether the hub's setup screen can hear it yet.
private struct HubFinderRow: View {
    @ObservedObject var finder: HubFinder
    /// "board" or "device".
    let thing: String

    var body: some View {
        LabeledContent("Your \(thing)") {
            switch finder.state {
            case .idle, .searching:
                HStack(spacing: 6) {
                    Text("Looking…")
                    ProgressView()
                }
            case .found:
                Label("Found", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(Color.accentColor)
            case .bluetoothOff:
                Text("Turn on Bluetooth")
            case .notAllowed:
                Text("Allow Bluetooth in Settings")
            }
        }
    }
}

/// A row in "Which beacon do you have?": the device's name, with a line on how to recognize it.
private struct DeviceRow: View {
    let title: String
    let detail: String
    let systemImage: String

    init(_ title: String, detail: String, systemImage: String) {
        self.title = title
        self.detail = detail
        self.systemImage = systemImage
    }

    var body: some View {
        Label {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).foregroundStyle(Color.primary)
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
        } icon: {
            Image(systemName: systemImage)
        }
    }
}

/// Setting up a Blue Charm BC-U1 or BC05: Goodnight Phone writes its settings over Bluetooth.
private struct BlueCharmSetupView: View {
    @ObservedObject private var blueCharm = BlueCharm.shared
    let onDone: (BlueCharmPairing) -> Void

    var body: some View {
        Form {
            Section {
                Text("Plug the USB stick (BC-U1) into a USB charger by the bed.")
            } header: {
                BrandHeader("1. Turn it on")
            } footer: {
                Text("For the round battery puck (BC05), twist it open, hold the white button inside for 3 seconds until the light flashes red, and close it.")
            }
            .brandRow()

            Section {
                Button {
                    Task {
                        guard let pairing = await blueCharm.setUp() else { return }
                        onDone(pairing)
                    }
                } label: {
                    HStack {
                        Text("Set up")
                        Spacer()
                        if blueCharm.isBusy { ProgressView() }
                    }
                }
                .disabled(blueCharm.isBusy)
            } header: {
                BrandHeader("2. Hold your iPhone next to it")
            } footer: {
                switch blueCharm.phase {
                case .searching: Text("Looking for the Blue Charm…")
                case .connecting: Text("Connecting…")
                case .writing: Text("Setting it up…")
                case .failed(let message): Text(message).foregroundStyle(.red)
                case .idle, .holding: Text("Goodnight Phone finds it and sets it up, no other app needed.")
                }
            }
            .brandRow()
        }
        .navigationTitle("Blue Charm beacon")
        .brandForm()
        .readableWidth()
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// Using a spare iPad or iPhone as the bedroom hub.
private struct SpareDeviceSetupView: View {
    let isCurrent: Bool
    let onUse: () -> Void
    @StateObject private var finder = HubFinder()

    var body: some View {
        Form {
            Section {
                Text("Install Goodnight Phone on it, open Setup, tap Use this device as a bedroom hub and turn it on.")
            } header: {
                BrandHeader("1. On the spare device")
            } footer: {
                Text("Leave it plugged in by the bed with Goodnight Phone open. iOS only keeps this running while the app is on screen, so the screen stays on.")
            }
            .brandRow()

            Section {
                HubFinderRow(finder: finder, thing: "spare device")
                Button(isCurrent ? "This is your bedroom beacon" : "Use the spare device", action: onUse)
                    .disabled(isCurrent)
            } header: {
                BrandHeader("2. On this iPhone")
            } footer: {
                Text("Then stand in the bedroom doorway and tap Mark doorway here.")
            }
            .brandRow()
        }
        .navigationTitle("Spare iPad or iPhone")
        .brandForm()
        .readableWidth()
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { finder.start() }
        .onDisappear { finder.stop() }
    }
}

/// "I don't have one yet": which beacon to get. The buy buttons open Amazon (tagged) through
/// the website's /go redirects, in Safari or the Amazon app.
private struct NoBeaconView: View {
    var body: some View {
        Form {
            Section {
                Text("A thumbnail-sized board that plugs into a small outlet cube by your bed. You set exactly where the bedroom ends by standing in the doorway, and walking out lifts the block within seconds. One board works for up to three phones.")
                Link(destination: AppLinks.buyHubKit) {
                    Label("Add the parts to your Amazon cart (about $36)", systemImage: "cart")
                }
                Link(destination: AppLinks.chooseHub) {
                    Label("What's in the kit", systemImage: "list.bullet")
                }
            } header: {
                BrandHeader("We recommend: Seeed XIAO board")
            } footer: {
                Text("Needs a one-time install from a Mac or PC, about a minute. \(AppLinks.amazonDisclosure)")
            }
            .brandRow()

            Section {
                Text("It can be your beacon for free. Go back and pick Spare iPad or iPhone.")
            } header: {
                BrandHeader("Have a spare iPad or iPhone?")
            }
            .brandRow()
        }
        .navigationTitle("Get a beacon")
        .brandForm()
        .readableWidth()
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// Typing in any other iBeacon's identity.
private struct OtherBeaconForm: View {
    @State private var uuid: String
    @State private var major: String
    @State private var minor: String
    private let onSave: (BeaconConfig) -> Void

    init(current: BeaconConfig?, onSave: @escaping (BeaconConfig) -> Void) {
        _uuid = State(initialValue: current?.uuid ?? "")
        _major = State(initialValue: current?.major.map(String.init) ?? "")
        _minor = State(initialValue: current?.minor.map(String.init) ?? "")
        self.onSave = onSave
    }

    /// nil when the fields don't make a valid beacon.
    private var draft: BeaconConfig? {
        let majorText = major.trimmingCharacters(in: .whitespaces)
        let minorText = minor.trimmingCharacters(in: .whitespaces)
        let majorValue = UInt16(majorText)
        let minorValue = UInt16(minorText)
        if !majorText.isEmpty, majorValue == nil { return nil }
        if !minorText.isEmpty, minorValue == nil { return nil }
        let config = BeaconConfig(
            uuid: uuid.trimmingCharacters(in: .whitespacesAndNewlines).uppercased(),
            major: majorValue,
            minor: minorValue
        )
        return config.isValid && !config.isStandIn ? config : nil
    }

    var body: some View {
        Form {
            Section {
                TextField("XXXXXXXX-XXXX-XXXX-XXXX-XXXXXXXXXXXX", text: $uuid, axis: .vertical)
                    .font(.body.monospaced())
                    .textInputAutocapitalization(.characters)
                    .autocorrectionDisabled()
            } header: {
                BrandHeader("Beacon UUID")
            } footer: {
                Text("It's on the box or in the beacon's setup app.")
            }
            .brandRow()

            Section {
                TextField("Major", text: $major).keyboardType(.numberPad)
                TextField("Minor", text: $minor).keyboardType(.numberPad)
            } header: {
                BrandHeader("Optional")
            } footer: {
                Text("Only needed if other beacons nearby share the same UUID. Minor needs a major.")
            }
            .brandRow()
        }
        .navigationTitle("Another iBeacon")
        .brandForm()
        .readableWidth()
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") { if let draft { onSave(draft) } }
                    .disabled(draft == nil)
            }
        }
    }
}

// MARK: - Blue Charm range

/// Shorter / Longer for a Blue Charm the app set up: steps its transmit power over Bluetooth.
/// Locked while blocking like every other setting, so it can't shrink the bedroom to escape,
/// except during the tuning window right after setup (BlueCharmPairing.tuningWindow).
private struct BlueCharmRange: View {
    @EnvironmentObject private var model: AppModel
    @ObservedObject private var blueCharm = BlueCharm.shared
    let pairing: BlueCharmPairing

    private var steps: [Int] { BlueCharm.powerSteps }
    /// The step last tapped, even before the beacon has it, so each tap shows at once.
    private var power: Int { blueCharm.targetPower ?? pairing.txPower }
    private var index: Int { steps.firstIndex(of: power) ?? steps.firstIndex(of: BlueCharm.startingPower)! }
    /// Busy with something other than a range change (setup), when the buttons wait.
    private var otherJob: Bool { blueCharm.isBusy && blueCharm.targetPower == nil }

    var body: some View {
        LabeledContent("Range") {
            HStack(spacing: 8) {
                if blueCharm.targetPower != nil, blueCharm.phase != .holding {
                    ProgressView()
                }
                Text("\(index + 1) of \(steps.count)")
                    .monospacedDigit()
            }
        }
        HStack {
            Button("Shorter") { step(-1) }
                .disabled(index == 0)
            Spacer()
            Button("Longer") { step(1) }
                .disabled(index == steps.count - 1)
        }
        // Borderless, or a tap anywhere in the row would press both buttons.
        .buttonStyle(.borderless)
        .disabled((model.isLocked && !pairing.inTuningWindow()) || otherJob)
        if case .failed(let message) = blueCharm.phase {
            Text(message).font(.caption).foregroundStyle(.red)
        }
    }

    private func step(_ delta: Int) {
        blueCharm.requestPower(steps[index + delta], for: pairing) { model.saveBlueCharm($0) }
    }
}

// MARK: - Nights

private enum Weekdays {
    /// Calendar weekdays (1 = Sunday), starting on the locale's first day of the week.
    static var inOrder: [Int] {
        let first = Calendar.current.firstWeekday
        return (0..<7).map { (first - 1 + $0) % 7 + 1 }
    }
}

/// One circle per night, like the Clock app's alarm days: filled = blocking that night.
private struct NightToggles: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        HStack {
            ForEach(Weekdays.inOrder, id: \.self) { weekday in
                let isOn = model.schedule.hours(onWeekday: weekday) != nil
                Button {
                    var schedule = model.schedule
                    // Back on uses the usual hours; a night's own hours are set under Hours by night.
                    schedule.nights[weekday - 1] = isOn ? .off : .usual
                    model.saveSchedule(schedule)
                } label: {
                    Text(Calendar.current.veryShortWeekdaySymbols[weekday - 1])
                        .font(.subheadline.weight(.semibold))
                        .frame(width: 36, height: 36)
                        .foregroundStyle(isOn ? Brand.cream : Color.primary)
                        .background(Circle().fill(isOn ? Brand.red : Color(.tertiarySystemFill)))
                }
                // Borderless, or a tap anywhere in the row would press every button.
                .buttonStyle(.borderless)
                .frame(maxWidth: .infinity)
                .accessibilityLabel("\(Calendar.current.weekdaySymbols[weekday - 1]) night")
                .accessibilityValue(isOn ? "On" : "Off")
                .accessibilityAddTraits(isOn ? .isSelected : [])
            }
        }
        .padding(.vertical, 4)
    }
}

private struct NightsView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        Form {
            Section {
                ForEach(Weekdays.inOrder, id: \.self) { weekday in
                    NavigationLink { NightEditor(weekday: weekday) } label: {
                        LabeledContent(Calendar.current.weekdaySymbols[weekday - 1], value: hours(weekday))
                    }
                }
            } footer: {
                Text("Give a night its own hours, or take it off. Nights on usual hours follow Starts and Ends.")
            }
            .brandRow()
        }
        .navigationTitle("Hours by night")
        .brandForm()
        .readableWidth()
        .navigationBarTitleDisplayMode(.inline)
        .disabled(model.isLocked)
    }

    private func hours(_ weekday: Int) -> String {
        guard let hours = model.schedule.hours(onWeekday: weekday) else { return "Off" }
        return BedtimeSchedule.summary(start: hours.start, end: hours.end)
    }
}

private struct NightEditor: View {
    @EnvironmentObject private var model: AppModel
    /// Calendar weekday, 1 = Sunday.
    let weekday: Int

    private enum Choice: Hashable { case usual, own, off }

    private var night: BedtimeSchedule.Night { model.schedule.nights[weekday - 1] }
    private var dayName: String { Calendar.current.weekdaySymbols[weekday - 1] }
    private var nextDayName: String { Calendar.current.weekdaySymbols[weekday % 7] }

    var body: some View {
        Form {
            Section {
                Picker("Hours", selection: choiceBinding) {
                    Text("Usual hours").tag(Choice.usual)
                    Text("Different hours").tag(Choice.own)
                    Text("Off").tag(Choice.off)
                }
                .pickerStyle(.inline)
                .labelsHidden()
            } footer: {
                switch night {
                case .usual:
                    Text("\(BedtimeSchedule.summary(start: model.schedule.startMinutes, end: model.schedule.endMinutes)), like the other nights on usual hours.")
                case .hours:
                    Text("Only \(dayName) night. The usual hours stay as they are.")
                case .off:
                    Text("Nothing is blocked from \(dayName) evening through \(nextDayName) morning.")
                }
            }
            .brandRow()
            if case .hours = night {
                Section {
                    DatePicker("Starts", selection: timeBinding(start: true), displayedComponents: .hourAndMinute)
                    DatePicker("Ends", selection: timeBinding(start: false), displayedComponents: .hourAndMinute)
                }
                .brandRow()
            }
        }
        .navigationTitle(dayName)
        .brandForm()
        .readableWidth()
        .navigationBarTitleDisplayMode(.inline)
        .disabled(model.isLocked)
    }

    private var choiceBinding: Binding<Choice> {
        Binding(
            get: {
                switch night {
                case .usual: return .usual
                case .hours: return .own
                case .off: return .off
                }
            },
            set: { choice in
                switch choice {
                case .usual: save(.usual)
                case .off: save(.off)
                case .own:
                    if case .hours = night { return }
                    // Start from the usual hours, ready to adjust.
                    save(.hours(start: model.schedule.startMinutes, end: model.schedule.endMinutes))
                }
            }
        )
    }

    private func timeBinding(start: Bool) -> Binding<Date> {
        Binding(
            get: {
                guard case .hours(let s, let e) = night else { return .now }
                return BedtimeSchedule.date(fromMinutes: start ? s : e)
            },
            set: { newValue in
                guard case .hours(let s, let e) = night else { return }
                let minutes = BedtimeSchedule.minutes(from: newValue)
                save(start ? .hours(start: minutes, end: e) : .hours(start: s, end: minutes))
            }
        )
    }

    private func save(_ newValue: BedtimeSchedule.Night) {
        var schedule = model.schedule
        schedule.nights[weekday - 1] = newValue
        model.saveSchedule(schedule)
    }
}

// MARK: - Stand-in beacon

private struct StandInBeaconView: View {
    @ObservedObject private var broadcaster = BeaconBroadcaster.shared

    var body: some View {
        Form {
            Section {
                Toggle("Broadcast as bedroom beacon", isOn: Binding(
                    get: { broadcaster.isOn },
                    set: { broadcaster.setOn($0) }
                ))
                LabeledContent("Status", value: broadcaster.label)
            } footer: {
                Text("Leave Goodnight Phone open with the device plugged in by the bed. iOS only keeps this running while the app is on screen, so the display stays on while this is on. On your iPhone, open Setup, tap Add a beacon (or Beacon details, then Change beacon…), then Spare iPad or iPhone, then Use the spare device, then mark the doorway.")
            }
            .brandRow()
        }
        .navigationTitle("Stand-in beacon")
        .brandForm()
        .readableWidth()
        .navigationBarTitleDisplayMode(.inline)
    }
}
