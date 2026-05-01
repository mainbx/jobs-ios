//
//  FilterChip.swift
//  jobs-ios
//
//  Pill-shaped filter chip used as the SwiftUI ``Menu`` label for each
//  filter dimension (Posted / Remote / State / Tier / Sort). Mirrors
//  the web's ``FilterChip`` component:
//
//  * **Idle** state — outlined pill, just the dimension label
//    ("Posted") plus a chevron. Subtle by design.
//  * **Active** state — solid-fill pill with `Label · Value`
//    ("Posted · 7d"). The chevron is hidden because the value text
//    already signals "this is a populated dropdown" — saves space and
//    keeps the active state visually distinct.
//
//  Native ``Menu`` parents handle option selection, accessibility, and
//  Dynamic Type for free; this view is purely the visual chrome.
//
//  The compact pill keeps the horizontal-scroll filter row narrow so
//  all 5 chips + Clear fit a single iPhone width without scrolling at
//  every realistic device size, matching the web revamp.
//

import SwiftUI

/// Visible chrome for a filter chip. Drop into a SwiftUI ``Menu`` as
/// the ``label``; the parent owns option list + selection.
///
/// ```swift
/// Menu {
///     ForEach(DateRange.allCases) { ... }
/// } label: {
///     FilterChipLabel(label: "Posted", valueText: shortLabel(for: selection))
/// }
/// ```
///
/// Pass ``nil`` for ``valueText`` when the filter is at its default
/// (idle) state. A non-nil value flips the chip into active styling.
struct FilterChipLabel: View {
    /// Static dimension label shown on the chip ("Posted", "Remote",
    /// "Tier"). Always rendered.
    let label: String

    /// Short-form value rendered after a `·` separator when the filter
    /// is narrowed. ``nil`` (or empty) keeps the chip in idle styling.
    let valueText: String?

    private var isActive: Bool {
        guard let valueText, !valueText.isEmpty else { return false }
        return true
    }

    var body: some View {
        HStack(spacing: 4) {
            Text(label)
            if isActive, let valueText {
                Text("·")
                    .opacity(0.5)
                    .accessibilityHidden(true)
                Text(valueText)
            }
            // Chevron is shown on idle chips so users see the
            // dropdown affordance, hidden on active chips because the
            // value text + filled background already signal "populated
            // dropdown" — keeps the active pill compact.
            if !isActive {
                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .semibold))
                    .opacity(0.7)
                    .accessibilityHidden(true)
            }
        }
        .font(.subheadline.weight(.medium))
        // ``.background`` shape style resolves to the system background
        // color (white-ish in light, near-black in dark), giving the
        // active pill a guaranteed high-contrast inverse-text on its
        // ``Color.primary`` fill in both modes — and works
        // cross-platform without needing a UIColor/NSColor branch.
        .foregroundStyle(isActive ? AnyShapeStyle(.background) : AnyShapeStyle(Color.primary))
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(
            Capsule()
                .fill(
                    isActive
                        ? AnyShapeStyle(Color.primary)
                        : AnyShapeStyle(Color.gray.opacity(0.08))
                )
        )
        .overlay(
            Capsule()
                .strokeBorder(
                    isActive ? Color.clear : Color.gray.opacity(0.3),
                    lineWidth: 1
                )
        )
        // Capsule-shaped hit testing so taps near the rounded corners
        // route to the menu rather than missing the visual button.
        .contentShape(Capsule())
    }
}

#if !SWIFT_PACKAGE
#Preview("Filter chip — idle and active") {
    HStack(spacing: 8) {
        FilterChipLabel(label: "Posted", valueText: nil)
        FilterChipLabel(label: "Posted", valueText: "7d")
        FilterChipLabel(label: "Tier", valueText: "MAANG+")
        FilterChipLabel(label: "Remote", valueText: nil)
    }
    .padding()
}
#endif
