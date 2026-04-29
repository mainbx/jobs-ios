//
//  FeedView.swift
//  jobs-ios
//
//  Entry screen. Scrollable list of open roles, newest first, with
//  multi-keyword search + date-range + remote + tier filters stacked
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
            .onChange(of: searchText) { _, new in
                // Debounce to avoid one query per keystroke.
                searchTask?.cancel()
                searchTask = Task {
                    try? await Task.sleep(for: .milliseconds(250))
                    if Task.isCancelled { return }
                    filters.search = new
                    await model.load(filters: filters)
                }
            }
            .onChange(of: filters.posted) { _, _ in
                Task { await model.load(filters: filters) }
            }
            .onChange(of: filters.remote) { _, _ in
                Task { await model.load(filters: filters) }
            }
            .onChange(of: filters.tier) { _, _ in
                Task { await model.load(filters: filters) }
            }
            .task { await model.load(filters: filters) }
            .refreshable { await model.load(filters: filters) }
        }
    }

    // MARK: - Filter UI

    private var filterStack: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Filter bar with date / remote / tier menus and a Clear
            // button. Free-text search lives in the navigation
            // ``.searchable`` slot above; whitespace, commas, and
            // semicolons are all separators, and every term must hit
            // either the title or the company (Google-style AND).
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 16) {
                    DateRangeMenu(selection: $filters.posted)
                    RemoteFilterMenu(selection: $filters.remote)
                    TierFilterMenu(selection: $filters.tier)
                    if !filters.isEmpty {
                        Button("Clear") {
                            filters = FilterState()
                            searchText = ""
                        }
                        .font(.footnote)
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
                    if let url = URL(string: job.postingUrl) {
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
            HStack(spacing: 4) {
                Image(systemName: "calendar")
                Text("Posted: \(selection.label)")
                    .font(.footnote)
            }
            .foregroundStyle(.secondary)
        }
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
            HStack(spacing: 4) {
                Image(systemName: selection == .remote ? "house" : "globe.americas")
                Text(selection.label)
                    .font(.footnote)
            }
            .foregroundStyle(.secondary)
        }
    }
}

// MARK: - Tier filter menu

private struct TierFilterMenu: View {
    @Binding var selection: TierFilter

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
            HStack(spacing: 4) {
                Image(systemName: "rosette")
                Text(selection.label)
                    .font(.footnote)
            }
            .foregroundStyle(.secondary)
        }
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

/// Rounded-rect page number tile. Current page is filled with the
/// accent color; other pages are bordered neutrals.
private struct PageNumberButton: View {
    let page: Int
    let current: Bool
    let disabled: Bool
    let onTap: () -> Void

    var body: some View {
        Button(action: current ? {} : onTap) {
            Text("\(page)")
                .font(.subheadline)
                .fontWeight(current ? .semibold : .regular)
                .frame(minWidth: 32, minHeight: 30)
                .padding(.horizontal, 6)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(current ? Color.accentColor : Color.clear)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(current ? Color.clear : Color.gray.opacity(0.3), lineWidth: 1)
                )
                .foregroundStyle(current ? Color.white : Color.primary)
                .opacity(disabled && !current ? 0.5 : 1.0)
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
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(Color.gray.opacity(disabled ? 0.15 : 0.3), lineWidth: 1)
                )
                .foregroundStyle(disabled ? Color.secondary.opacity(0.5) : Color.primary)
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
                    .font(.body)
                    .lineLimit(2)
                Spacer(minLength: 8)
                Text(displayAge(for: job))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            HStack(spacing: 8) {
                Text(job.company)
                    .font(.subheadline)
                    .fontWeight(.medium)
                if !job.location.isEmpty {
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

    private func relativeTime(from date: Date) -> String {
        let interval = Date().timeIntervalSince(date)
        let mins = Int(max(0, interval / 60))
        if mins < 60 { return "\(mins)m" }
        let hrs = mins / 60
        if hrs < 24 { return "\(hrs)h" }
        return "\(hrs / 24)d"
    }

    private func displayAge(for job: Job) -> String {
        // Prefer a real posted_at when the scraper captured one.
        // The backend guarantees a valid ISO-8601 UTC string when non-empty.
        if !job.postedAt.isEmpty,
           let posted = Self.iso8601.date(from: job.postedAt) ?? Self.iso8601NoFrac.date(from: job.postedAt)
        {
            return "posted \(relativeTime(from: posted))"
        }
        return "seen \(relativeTime(from: job.lastSeen))"
    }

    private static let iso8601: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    private static let iso8601NoFrac: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()
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
