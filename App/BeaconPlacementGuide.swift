import SwiftUI

/// "Where to put the beacon": illustrated tips for placing it where switching it off takes effort.
/// Read-only, so it stays open to read while apps are blocked. Art source: docs/art/guide-scenes.py.
struct BeaconPlacementGuide: View {
    private struct Tip: Identifiable {
        /// nil for a text-only tip, so only the main ideas get a picture.
        var art: String?
        let title: String
        let text: String
        var id: String { title }
    }

    private let tips = [
        Tip(
            art: "GuideHardware",
            title: "What goes by the bed",
            text: "The bedroom hub: a thumbnail-sized board on a small outlet cube that plugs into the wall, so there's no battery to die.\nOr a spare iPad or iPhone running Goodnight Phone, left plugged in."
        ),
        Tip(
            art: "GuideNightstand",
            title: "Keep it out of reach",
            text: "Not on the nightstand or by your pillow. If you can reach it from bed, you'll unplug it."
        ),
        Tip(
            art: "GuideUnderBed",
            title: "Plug it in under the bed",
            text: "Use an outlet behind or under the bed, so unplugging it means crawling under. Leave a little wall space beside the cube for the board."
        ),
        Tip(
            title: "Want it even harder to reach?",
            text: "Pick an outlet behind the headboard or a heavy dresser. The signal goes right through furniture."
        ),
        Tip(
            art: "GuideFloorPlan",
            title: "Keep it away from the door",
            text: "Put it on the far side of the room, so the signal is clearly weaker in the doorway. Then stand in the doorway and tap Mark doorway here. If Goodnight Phone still says “In the bedroom” out in the hallway, tap Mark doorway again in Beacon details."
        ),
        Tip(
            title: "Using a spare iPad or iPhone instead?",
            text: "Leave it plugged in on a dresser across the room, with Use this device as a bedroom hub turned on. Then mark the doorway the same way."
        ),
    ]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 32) {
                Text("Hide the beacon somewhere hard to reach, so you can't just unplug it at bedtime.")
                    .font(.system(.body, design: .rounded))
                    .foregroundStyle(Brand.ink.opacity(0.85))

                ForEach(tips) { tip in
                    VStack(alignment: .leading, spacing: 10) {
                        if let art = tip.art {
                            Image(art)
                                .resizable()
                                .scaledToFit()
                                .frame(maxWidth: 290)
                                .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
                                .overlay(RoundedRectangle(cornerRadius: 28, style: .continuous).strokeBorder(Brand.fixedInk, lineWidth: 3))
                                .frame(maxWidth: .infinity)
                                .accessibilityHidden(true)
                                .padding(.bottom, 6)
                        }
                        Text(tip.title)
                            .font(Brand.heading(26))
                            .foregroundStyle(Brand.green)
                            .accessibilityAddTraits(.isHeader)
                        Text(tip.text)
                            .font(.system(.body, design: .rounded))
                            .foregroundStyle(Brand.ink.opacity(0.85))
                    }
                }
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 16)
            .frame(maxWidth: ReadableWidth.max)
            .frame(maxWidth: .infinity)
        }
        .background(Brand.paper.ignoresSafeArea())
        .navigationTitle("Where to put it")
        .navigationBarTitleDisplayMode(.inline)
    }
}

#Preview {
    NavigationStack { BeaconPlacementGuide() }
}
