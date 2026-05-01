//
//  FeedView.swift
//  jobs-ios
//
//  Entry screen. Scrollable list of open roles, newest first, with
//  multi-keyword search + date-range + remote + state + tier filters stacked
//  above the list. The bottom of the list shows a numbered paginator —
//  first page, last page, current ± 2, ellipses for gaps — plus Prev
//  / Next arrows. Mirrors the web's Pagination component exactly.
//

import SwiftUI

#if canImport(UIKit)
import UIKit
#endif

struct FeedView: View {
    @State private var model = FeedViewModel()
    @State private var filters = FilterState()
    @State private var searchText: String = ""
    @State private var searchTask: Task<Void, Never>?
    @State private var filterTask: Task<Void, Never>?

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                filterStack
                Divider()
                list
            }
            .navigationTitle("Jobs")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .searchable(
                text: $searchText,
                prompt: "Search title or company"
            )
            .searchSuggestions {
                // Discoverability for the operator vocabulary: when
                // the user focuses an empty search field, surface the
                // four supported operators as labelled rows. These
                // are display-only (no `searchCompletion`) — tapping
                // them shouldn't replace the user's draft.
                if searchText.isEmpty {
                    Section("Search operators") {
                        Label {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("staff engineer").font(.system(.body, design: .monospaced))
                                Text("each word must appear in title or company")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        } icon: { Image(systemName: "text.magnifyingglass") }
                        Label {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("\"new grad\"").font(.system(.body, design: .monospaced))
                                Text("quoted phrase, exact substring")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        } icon: { Image(systemName: "quote.opening") }
                        Label {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("-intern").font(.system(.body, design: .monospaced))
                                Text("exclude rows containing the term")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        } icon: { Image(systemName: "minus.circle") }
                        Label {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("title:engineer  company:google")
                                    .font(.system(.body, design: .monospaced))
                                Text("constrain to a column")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        } icon: { Image(systemName: "square.dashed") }
                    }
                }
            }
            .onChange(of: searchText) { _, new in
                let normalized = normalizeSearchInput(new)
                if normalized != new {
                    searchText = normalized
                    return
                }
                // Debounce to avoid one query per keystroke.
                searchTask?.cancel()
                searchTask = Task {
                    try? await Task.sleep(for: .milliseconds(250))
                    if Task.isCancelled { return }
                    await MainActor.run {
                        filters.search = normalized
                    }
                }
            }
            .onChange(of: filters) { _, new in
                scheduleFilterLoad(new)
            }
            .task { await model.load(filters: filters) }
            .refreshable {
                filterTask?.cancel()
                await model.load(filters: filters)
            }
        }
    }

    private func scheduleFilterLoad(_ next: FilterState) {
        filterTask?.cancel()
        filterTask = Task {
            if Task.isCancelled { return }
            await model.load(filters: next)
        }
    }

    // MARK: - Filter UI

    private var filterStack: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Filter bar with date / remote / state / tier / sort menus
            // and a Clear button. Free-text search lives in the
            // navigation ``.searchable`` slot above; whitespace, commas,
            // and semicolons are all separators, and every term must hit
            // either the title or the company (Google-style AND).
            //
            // The chip styling mirrors the web revamp — outlined pill
            // for idle, solid fill for active, with the active value
            // baked into the label (`Posted · 7d`). Tighter spacing
            // keeps all 5 chips visible at iPhone widths without
            // forcing horizontal scroll on idle.
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    DateRangeMenu(selection: $filters.posted)
                    RemoteFilterMenu(selection: $filters.remote)
                    StateFilterMenu(selection: $filters.state)
                    TierFilterMenu(selection: $filters.tier)
                    SortOrderMenu(selection: $filters.sort)
                    // "Clear filters" is decoupled from the search
                    // field's own clear (the native `.searchable` x).
                    // Resets only the date/remote/state/tier/sort dimensions
                    // and preserves the user's search query — a user
                    // often wants to drop the filter set while
                    // keeping the search, or vice versa, and a
                    // single combined Clear conflates the two.
                    //
                    // Compact icon + label, matching the chip aesthetic
                    // without using the same active-fill styling (Clear
                    // is an action, not a filter dimension).
                    if filters.hasNonSearchFilters {
                        Button {
                            var next = filters
                            next.posted = .any
                            next.remote = .all
                            next.state = .all
                            next.tier = .all
                            next.sort = .newest
                            filters = next
                        } label: {
                            HStack(spacing: 4) {
                                Image(systemName: "xmark")
                                    .font(.system(size: 10, weight: .semibold))
                                Text("Clear")
                            }
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .contentShape(Capsule())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Clear filters")
                    }
                }
                .padding(.horizontal)
            }
        }
        .padding(.vertical, 8)
        .background(.regularMaterial)
    }

    // MARK: - Results list

    @ViewBuilder
    private var list: some View {
        if model.isLoading && model.jobs.isEmpty {
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let error = model.errorMessage, model.jobs.isEmpty {
            ContentUnavailableView(
                "Couldn't load jobs",
                systemImage: "exclamationmark.triangle",
                description: Text(error)
            )
        } else if model.jobs.isEmpty {
            ContentUnavailableView(
                "No jobs match",
                systemImage: "magnifyingglass",
                description: Text("Try clearing a filter or broadening the date range.")
            )
        } else {
            List {
                ForEach(model.jobs) { job in
                    if let url = job.safePostingURL {
                        Link(destination: url) { JobRow(job: job) }
                            .buttonStyle(.plain)
                    } else {
                        JobRow(job: job)
                    }
                }
                if model.totalPages > 1 {
                    PaginatorRow(
                        currentPage: model.currentPage,
                        totalPages: model.totalPages,
                        totalCount: model.totalCount,
                        pageSize: 100,
                        pageCount: model.jobs.count,
                        isLoading: model.isLoading,
                        onSelect: { page in Task { await model.loadPage(page) } }
                    )
                    .listRowSeparator(.hidden)
                    .listRowInsets(EdgeInsets(top: 12, leading: 12, bottom: 12, trailing: 12))
                } else if model.totalCount > 0 {
                    Text("\(model.totalCount) \(model.totalCount == 1 ? "result" : "results")")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                        .listRowSeparator(.hidden)
                }
            }
            .listStyle(.plain)
        }
    }
}

// MARK: - Date range menu

private struct DateRangeMenu: View {
    @Binding var selection: DateRange

    /// Short label rendered inside the active chip ("Posted · 7d"). The
    /// long form lives in ``DateRange.label`` and shows only inside the
    /// picker menu — keeping the chip compact at every iPhone width.
    private static let shortLabel: [DateRange: String] = [
        .any: "",
        .h24: "24h",
        .d7: "7d",
        .d30: "30d",
    ]

    var body: some View {
        Menu {
            ForEach(DateRange.allCases) { range in
                Button {
                    selection = range
                } label: {
                    HStack {
                        Text(range.label)
                        if selection == range {
                            Image(systemName: "checkmark")
                        }
                    }
                }
            }
        } label: {
            FilterChipLabel(
                label: "Posted",
                valueText: selection == .any ? nil : Self.shortLabel[selection]
            )
        }
        .accessibilityLabel("Posted within: \(selection.label)")
    }
}

// MARK: - Remote filter menu

private struct RemoteFilterMenu: View {
    @Binding var selection: RemoteFilter

    var body: some View {
        Menu {
            ForEach(RemoteFilter.allCases) { r in
                Button {
                    selection = r
                } label: {
                    HStack {
                        Text(r.label)
                        if selection == r {
                            Image(systemName: "checkmark")
                        }
                    }
                }
            }
        } label: {
            FilterChipLabel(
                label: "Remote",
                valueText: selection == .all ? nil : "On"
            )
        }
        .accessibilityLabel("Remote filter: \(selection.label)")
    }
}

// MARK: - State filter menu

private struct StateFilterMenu: View {
    @Binding var selection: StateFilter

    var body: some View {
        Menu {
            ForEach(StateFilter.allCases) { s in
                Button {
                    selection = s
                } label: {
                    HStack {
                        Text(s.label)
                        if selection == s {
                            Image(systemName: "checkmark")
                        }
                    }
                }
            }
        } label: {
            FilterChipLabel(
                label: "State",
                // Use the 2-letter postal code (`State · CA`) on the
                // chip rather than the full state name — keeps the
                // active chip compact even when the picker shows
                // "California" inside the menu.
                valueText: selection == .all ? nil : selection.rawValue
            )
        }
        .accessibilityLabel("State: \(selection.label)")
    }
}

// MARK: - Tier filter menu

private struct TierFilterMenu: View {
    @Binding var selection: TierFilter

    /// Short tier labels for chip display. "MAANG+" and "Startups" are
    /// already short; the numbered tiers compress to T1/T2/T3.
    private static let shortLabel: [TierFilter: String] = [
        .all: "",
        .maang: "MAANG+",
        .tier1: "T1",
        .tier2: "T2",
        .tier3: "T3",
        .startups: "Startups",
    ]

    var body: some View {
        Menu {
            ForEach(TierFilter.allCases) { t in
                Button {
                    selection = t
                } label: {
                    HStack {
                        Text(t.label)
                        if selection == t {
                            Image(systemName: "checkmark")
                        }
                    }
                }
            }
        } label: {
            FilterChipLabel(
                label: "Tier",
                valueText: selection == .all ? nil : Self.shortLabel[selection]
            )
        }
        .accessibilityLabel("Tier: \(selection.label)")
    }
}

// MARK: - Sort order menu

/// Sort dropdown — Newest first (default) / Oldest first. Mirrors
/// the web's `SortFilter`. Picking any value explicitly disables the
/// landing-page diversification shuffle in `FeedViewModel`.
private struct SortOrderMenu: View {
    @Binding var selection: SortOrder

    var body: some View {
        Menu {
            ForEach(SortOrder.allCases) { s in
                Button {
                    selection = s
                } label: {
                    HStack {
                        Text(s.label)
                        if selection == s {
                            Image(systemName: "checkmark")
                        }
                    }
                }
            }
        } label: {
            FilterChipLabel(
                label: "Sort",
                valueText: selection == .newest ? nil : "Oldest"
            )
        }
        .accessibilityLabel("Sort: \(selection.label)")
    }
}

// MARK: - Numbered paginator

/// Row rendered at the bottom of the list. Two tiers:
///   - status line: "Showing 1–100 of 5,432 · Page 3 of 55"
///   - button row: « Prev   1  …  5  6  [7]  8  9  …  20   Next »
/// Ellipsis placeholders (`nil` from `buildPageList`) become an
/// un-tappable "…" label. The current page is highlighted and
/// non-tappable (per ARIA "current page" convention on web).
private struct PaginatorRow: View {
    let currentPage: Int
    let totalPages: Int
    let totalCount: Int
    let pageSize: Int
    let pageCount: Int
    let isLoading: Bool
    let onSelect: (Int) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if totalCount > 0 {
                Text(statusLine)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    PaginatorArrow(
                        label: "‹ Prev",
                        disabled: currentPage <= 1 || isLoading,
                        onTap: { onSelect(currentPage - 1) }
                    )
                    ForEach(Array(pageList.enumerated()), id: \.offset) { (idx, p) in
                        if let p {
                            PageNumberButton(
                                page: p,
                                current: p == currentPage,
                                disabled: isLoading,
                                onTap: { onSelect(p) }
                            )
                        } else {
                            Text("…")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                                .frame(width: 18)
                                .accessibilityHidden(true)
                        }
                    }
                    PaginatorArrow(
                        label: "Next ›",
                        disabled: currentPage >= totalPages || isLoading,
                        onTap: { onSelect(currentPage + 1) }
                    )
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var pageList: [Int?] {
        buildPageList(current: currentPage, total: totalPages, window: 2)
    }

    private var statusLine: String {
        let from = (currentPage - 1) * pageSize + 1
        let to = (currentPage - 1) * pageSize + pageCount
        let fmt = NumberFormatter()
        fmt.numberStyle = .decimal
        let fromS = fmt.string(from: NSNumber(value: from)) ?? "\(from)"
        let toS = fmt.string(from: NSNumber(value: to)) ?? "\(to)"
        let totalS = fmt.string(from: NSNumber(value: totalCount)) ?? "\(totalCount)"
        return "Showing \(fromS)–\(toS) of \(totalS) · Page \(currentPage) of \(totalPages)"
    }
}

/// Page-number tile. Current page renders as a solid `Color.primary`
/// fill (matching the active filter chip), other pages get a neutral
/// outlined capsule. Monospaced digits keep numbers edge-aligned so
/// the row width doesn't jitter as the user pages.
private struct PageNumberButton: View {
    let page: Int
    let current: Bool
    let disabled: Bool
    let onTap: () -> Void

    var body: some View {
        Button(action: current ? {} : onTap) {
            Text("\(page)")
                .font(.subheadline)
                .monospacedDigit()
                .fontWeight(current ? .semibold : .regular)
                .frame(minWidth: 36, minHeight: 30)
                .padding(.horizontal, 6)
                .background(
                    Capsule()
                        .fill(
                            current
                                ? AnyShapeStyle(Color.primary)
                                : AnyShapeStyle(Color.gray.opacity(0.08))
                        )
                )
                .overlay(
                    Capsule()
                        .strokeBorder(
                            current ? Color.clear : Color.gray.opacity(0.3),
                            lineWidth: 1
                        )
                )
                .foregroundStyle(
                    current ? AnyShapeStyle(.background) : AnyShapeStyle(Color.primary)
                )
                .opacity(disabled && !current ? 0.5 : 1.0)
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .disabled(current || disabled)
        .accessibilityLabel(current ? "Page \(page), current page" : "Page \(page)")
    }
}

private struct PaginatorArrow: View {
    let label: String
    let disabled: Bool
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            Text(label)
                .font(.subheadline)
                .fontWeight(.medium)
                .frame(minHeight: 30)
                .padding(.horizontal, 10)
                .background(
                    Capsule()
                        .fill(Color.gray.opacity(0.08))
                )
                .overlay(
                    Capsule()
                        .strokeBorder(
                            Color.gray.opacity(disabled ? 0.15 : 0.3),
                            lineWidth: 1
                        )
                )
                .foregroundStyle(disabled ? Color.secondary.opacity(0.5) : Color.primary)
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .disabled(disabled)
    }
}

// MARK: - Row

private struct JobRow: View {
    let job: Job

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Text(job.title)
                    .font(.body.weight(.medium))
                    .lineLimit(2)
                Spacer(minLength: 8)
                Text(displayAge(for: job))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    // Tabular numerals so the right-aligned timestamp
                    // column doesn't shimmy as relative ages tick
                    // ("1m ago" → "12m ago" stays edge-aligned).
                    .monospacedDigit()
            }
            HStack(spacing: 6) {
                Text(job.company)
                    .font(.subheadline.weight(.medium))
                if !job.location.isEmpty {
                    // Bullet separator between company and location,
                    // matching the web revamp's `Company · Location`
                    // pattern. Subtle gray so company + location read
                    // as two pieces of metadata, not three.
                    Text("·")
                        .font(.subheadline)
                        .foregroundStyle(.tertiary)
                        .accessibilityHidden(true)
                    Text(job.location)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                if job.isRemote {
                    // Green pill only for genuinely-remote roles. Onsite
                    // US jobs don't get a badge — the whole feed is
                    // already US-scoped.
                    Text("Remote")
                        .font(.caption2)
                        .fontWeight(.medium)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(.green.opacity(0.15), in: Capsule())
                        .foregroundStyle(.green)
                }
            }
        }
        .padding(.vertical, 4)
    }

    /// Format a job's age for the feed row's right-side timestamp.
    ///
    /// Bucketed thresholds rather than raw "Nd ago" forever — preserves
    /// the truthful `effective_posted_at` across the whole range (even
    /// ancient zombie reqs that boards left open since 2012) without
    /// the long tail looking like a UI bug.
    ///
    ///   <  1 hour     → "posted Nm ago" (or "just now" at zero)
    ///   < 24 hours    → "posted Nh ago"
    ///   < 30 days     → "posted Nd ago"
    ///   < 12 months   → "posted Nmo ago"
    ///   < 24 months   → "posted 1y+ ago"
    ///   ≥ 24 months   → "open since YYYY"  ← signals "stale listing" to the user
    ///
    /// Mirrors the web's `formatPostedAge` in `app/page.tsx` exactly so
    /// users switching between surfaces see identical strings.
    private func displayAge(for job: Job) -> String {
        guard let date = job.effectivePostedAt else { return "" }
        let interval = max(0, Date().timeIntervalSince(date))
        let minutes = interval / 60
        if minutes < 60 {
            let m = Int(minutes.rounded())
            return m == 0 ? "posted just now" : "posted \(m)m ago"
        }
        let hours = minutes / 60
        if hours < 24 { return "posted \(Int(hours.rounded()))h ago" }
        let days = hours / 24
        if days < 30 { return "posted \(Int(days.rounded()))d ago" }
        let months = days / 30
        if months < 12 { return "posted \(Int(months.rounded()))mo ago" }
        let years = days / 365
        if years < 2 { return "posted 1y+ ago" }
        let year = Calendar(identifier: .gregorian).component(.year, from: date)
        return "open since \(year)"
    }
}

// The #Preview macro plugin only loads under Xcode. Under SwiftPM
// (`swift build`) the PreviewsMacros module isn't resolvable, so we
// guard the preview block out of the type-check build. Xcode never
// defines SWIFT_PACKAGE — the real iOS app target keeps the preview.
#if !SWIFT_PACKAGE
#Preview {
    FeedView()
}
#endif
