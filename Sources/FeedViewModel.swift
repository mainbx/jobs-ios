//
//  FeedViewModel.swift
//  jobs-ios
//
//  Fetches a page of the most-recently-seen relevant jobs from
//  Supabase, optionally narrowed by a `FilterState` (multi-keyword
//  search + posted-at window + remote + state + tier filter). The app reads the
//  narrow `public_jobs_feed` view and still sends the US/remote filter
//  as a belt-and-braces guard.
//
//  Pagination is numbered — each load replaces the list and jumps to
//  the requested page. Total-row count comes from PostgREST's
//  Content-Range header via `PostgrestResponse.count`, using
//  `count: .estimated` to avoid slow exact COUNT(*) scans.
//

import Foundation
import Supabase

/// 100-row pages, matching the web app.
private let pageSize = 100

private struct FeedPageResult {
    let jobs: [Job]
    let totalCount: Int
}

@Observable
@MainActor
final class FeedViewModel {
    var jobs: [Job] = []
    var isLoading = false
    var errorMessage: String?

    /// 1-based current page number. Driven by `loadPage(_:)`;
    /// `load(filters:)` resets to 1.
    private(set) var currentPage: Int = 1

    /// Total number of pages for the current filter set. Computed
    /// from `totalCount / pageSize` after each successful load.
    /// `0` when no results; at least `1` otherwise.
    private(set) var totalPages: Int = 0

    /// Total matching rows across all pages.
    private(set) var totalCount: Int = 0

    /// Filter snapshot that produced the current `jobs`. Used by
    /// `loadPage` to re-fetch with the same filters when only the
    /// page index changes.
    private var lastFilters = FilterState()

    /// Re-entrancy guard — if the user types quickly or taps multiple
    /// page numbers, we want the last-fired request to win, not
    /// whichever finishes first.
    private var currentTask: Task<Void, Never>?

    /// Fresh load (resets pagination + replaces the list). Call on
    /// filter change, pull-to-refresh, and first appearance. Debouncing
    /// / coalescing is the caller's job (the view debounces text input).
    func load(filters: FilterState = FilterState()) async {
        currentTask?.cancel()
        let task = Task {
            await self.performLoad(filters: filters, page: 1)
        }
        currentTask = task
        await task.value
    }

    /// Jump to a specific 1-based page without changing filters.
    /// Clamps out-of-range values so `loadPage(0)` or
    /// `loadPage(totalPages + 5)` can't crash the view.
    func loadPage(_ page: Int) async {
        let clamped = max(1, min(page, max(1, totalPages)))
        if clamped == currentPage && !jobs.isEmpty { return }
        currentTask?.cancel()
        let task = Task {
            await self.performLoad(filters: lastFilters, page: clamped)
        }
        currentTask = task
        await task.value
    }

    private func fetchPage(filters: FilterState, page: Int, includeCount: Bool) async throws -> FeedPageResult {
        let from = (page - 1) * pageSize
        let to = from + pageSize - 1 // inclusive range

        // US-only by design (matches the supabase_sync filter that
        // drops non-US rows from the Supabase mirror). The explicit
        // filter here is belt-and-braces.
        var query = SupabaseAPI.client
            .from("public_jobs_feed")
            .select(
                "canonical_key, company, title, posting_url, " +
                "location, is_remote, effective_posted_at",
                count: includeCount ? .estimated : nil
            )
            .eq("us_or_remote_eligible", value: true)

        for atom in parseSearchAtoms(filters.search) {
            let pat = "*\(atom.value)*"
            if atom.negate {
                switch atom.scope {
                case .any:
                    query = query
                        .filter("title", operator: "not.ilike", value: pat)
                        .filter("company", operator: "not.ilike", value: pat)
                case .title:
                    query = query.filter("title", operator: "not.ilike", value: pat)
                case .company:
                    query = query.filter("company", operator: "not.ilike", value: pat)
                }
            } else {
                switch atom.scope {
                case .any:
                    query = query.or("title.ilike.\(pat),company.ilike.\(pat)")
                case .title:
                    query = query.ilike("title", pattern: pat)
                case .company:
                    query = query.ilike("company", pattern: pat)
                }
            }
        }

        if let floorISO = filters.posted.floorISO {
            query = query.gte("effective_posted_at", value: floorISO)
        }

        switch filters.remote {
        case .all:
            break
        case .remote:
            query = query.eq("is_remote", value: true)
        }

        if let tierValue = filters.tier.dbValue {
            query = query.eq("tier", value: tierValue)
        }

        if let stateValue = filters.state.dbValue {
            query = query.overlaps("states", value: [stateValue, "*"])
        }

        let response = try await query
            .order("effective_posted_at", ascending: filters.sort == .oldest)
            .range(from: from, to: to)
            .execute()

        let decoded: [Job] = try JSONDecoder.supabase.decode([Job].self, from: response.data)
        let count = response.count ?? (decoded.count + (decoded.count == pageSize ? 1 : 0))
        return FeedPageResult(jobs: decoded, totalCount: count)
    }

    private func performLoad(filters: FilterState, page: Int) async {
        isLoading = true
        defer { isLoading = false }
        errorMessage = nil

        do {
            let result: FeedPageResult
            do {
                result = try await fetchPage(filters: filters, page: page, includeCount: true)
            } catch {
                if Task.isCancelled { return }
                print("[feed] counted query error, retrying without count:", error)
                result = try await fetchPage(filters: filters, page: page, includeCount: false)
            }

            if Task.isCancelled { return }

            let count = result.totalCount
            let pages = max(count == 0 ? 0 : 1, (count + pageSize - 1) / pageSize)

            self.jobs = result.jobs
            self.totalCount = count
            self.totalPages = pages
            self.currentPage = page
            self.lastFilters = filters
        } catch {
            if Task.isCancelled { return }
            self.errorMessage = error.localizedDescription
            print("[feed] error:", error)
        }
    }
}

// MARK: - Pagination helpers

/// Windowed numbered paginator model. `nil` entries represent an
/// ellipsis (…). Mirrors the web's `buildPageList` so both surfaces
/// behave the same.
///
///     buildPageList(current: 7, total: 20, window: 2)
///       → [1, nil, 5, 6, 7, 8, 9, nil, 20]
///
func buildPageList(current: Int, total: Int, window: Int = 2) -> [Int?] {
    if total <= 1 { return [1] }
    var set = Set<Int>()
    set.insert(1)
    set.insert(total)
    for i in (current - window)...(current + window) where i >= 1 && i <= total {
        set.insert(i)
    }
    let sorted = set.sorted()
    var out: [Int?] = []
    var prev = 0
    for p in sorted {
        if p - prev > 1 { out.append(nil) } // ellipsis
        out.append(p)
        prev = p
    }
    return out
}

// MARK: - Date decoding

/// Supabase returns ISO-8601 timestamps with fractional seconds ("…+00").
/// We extend the built-in decoder so it handles both "with" and "without"
/// fractional-seconds variants without caller gymnastics.
extension JSONDecoder {
    static let supabase: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let raw = try container.decode(String.self)
            if let d = SupabaseDateFormatters.fractional.date(from: raw) { return d }
            if let d = SupabaseDateFormatters.internet.date(from: raw) { return d }
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Unparseable ISO-8601 date: \(raw)"
            )
        }
        return decoder
    }()
}

private enum SupabaseDateFormatters {
    static let fractional: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    static let internet: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()
}
