//
//  FeedViewModel.swift
//  jobs-ios
//
//  Fetches a page of the most-recently-seen relevant jobs from
//  Supabase, optionally narrowed by a `FilterState` (search + keyword
//  chips + posted-at window + remote filter). The RLS policy
//  `jobs_public_read` already scopes to `relevant = true`, so that
//  filter is never sent from the app.
//
//  Pagination is numbered — each load replaces the list and jumps to
//  the requested page. Total-row count comes from PostgREST's
//  Content-Range header via `PostgrestResponse.count`, which the
//  `count: .exact` option on `.select` opts us into.
//

import Foundation
import Supabase

/// 100-row pages, matching the web app.
private let pageSize = 100

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

    private func performLoad(filters: FilterState, page: Int) async {
        isLoading = true
        defer { isLoading = false }
        errorMessage = nil

        let from = (page - 1) * pageSize
        let to = from + pageSize - 1 // inclusive range

        do {
            // US-only by design (matches the supabase_sync filter that
            // drops non-US rows from the Supabase mirror). The explicit
            // filter here is belt-and-braces.
            //
            // `count: .exact` asks PostgREST to return the total row
            // count in the Content-Range response header; we read it
            // via `response.count`.
            var query = SupabaseAPI.client
                .from("jobs")
                .select(
                    "canonical_key, company, title, posting_url, " +
                    "location, us_or_remote_eligible, is_remote, " +
                    "last_seen, posted_at",
                    count: .exact
                )
                .eq("us_or_remote_eligible", value: true)

            // Free-text search: title OR company (ILIKE substring).
            let trimmed = filters.search.trimmingCharacters(in: .whitespaces)
            if !trimmed.isEmpty {
                let safe = trimmed.replacingOccurrences(of: "(", with: " ")
                    .replacingOccurrences(of: ")", with: " ")
                    .replacingOccurrences(of: ",", with: " ")
                query = query.or("title.ilike.*\(safe)*,company.ilike.*\(safe)*")
            }

            // Keyword chips: title-only, OR across selections.
            if !filters.keywords.isEmpty {
                let clause = filters.keywords
                    .map { "title.ilike.*\($0)*" }
                    .joined(separator: ",")
                query = query.or(clause)
            }

            // Date range: filter on the precomputed
            // `effective_posted_at` column (populated by
            // `supabase_sync` as `posted_at` parsed to TIMESTAMPTZ
            // when known, else `first_seen`). Single indexed range
            // scan — dodges the 3s anon statement timeout we hit
            // with the compound OR across posted_at (TEXT) and
            // first_seen (TIMESTAMPTZ). Mirrors the web.
            if let floors = filters.posted.floors {
                query = query.gte("effective_posted_at", value: floors.iso)
            }

            // Remote filter — two-state. `.all` leaves it off.
            switch filters.remote {
            case .all:
                break
            case .remote:
                query = query.eq("is_remote", value: true)
            }

            // Tier filter — five-state. `.all` leaves it off.
            if let tierValue = filters.tier.dbValue {
                query = query.eq("tier", value: tierValue)
            }

            // Sort: `effective_posted_at DESC`, covered by
            // `idx_jobs_effective_posted_at`. This column is
            // populated by `supabase_sync._effective_posted_at` as
            // `posted_at` parsed to TIMESTAMPTZ when the board
            // exposes one, else `first_seen`. A just-discovered job
            // (no posted_at) whose first_seen is 5 min ago beats a
            // board-posted job from 1 day ago; among board-dated
            // jobs, the most recent posting wins. Single-column sort
            // on a single index — and mirrors the web feed exactly
            // so users switching between apps see the same top of
            // feed. Previously compound (`posted_at DESC, last_seen
            // DESC`), which drifted from the web and fell back to
            // processing order once the daily cron stamped every
            // active job with today's last_seen.
            let response = try await query
                .order("effective_posted_at", ascending: false)
                .range(from: from, to: to)
                .execute()

            if Task.isCancelled { return }

            let decoded: [Job] = try JSONDecoder.supabase.decode([Job].self, from: response.data)
            let count = response.count ?? decoded.count
            let pages = max(count == 0 ? 0 : 1, (count + pageSize - 1) / pageSize)

            self.jobs = decoded
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
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let d = formatter.date(from: raw) { return d }
            formatter.formatOptions = [.withInternetDateTime]
            if let d = formatter.date(from: raw) { return d }
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Unparseable ISO-8601 date: \(raw)"
            )
        }
        return decoder
    }()
}
