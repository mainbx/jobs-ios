//
//  FeedViewModel.swift
//  jobs-ios
//
//  Fetches a page of the most-recently-seen relevant jobs from
//  Supabase, optionally narrowed by a `FilterState` (multi-keyword
//  search + posted-at window + remote + tier filter). The RLS policy
//  `jobs_public_read` already scopes to the public feed slice
//  (`us_or_remote_eligible = true AND relevant = true`). The app still
//  sends the US/remote filter as a belt-and-braces guard.
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

            // Google-style free-text search. `parseSearchAtoms` turns
            // the raw input into a structured atom list: bare keywords,
            // quoted phrases, negation (`-`), and field constraints
            // (`title:` / `company:`). Each atom becomes one or two
            // PostgREST filters; supabase-swift + PostgREST joins
            // repeated request params with AND, so we never construct
            // nested `and(or(...))` URL syntax by hand.
            //
            // Per-atom wire shape (`*` = ILIKE wildcard in URL form):
            //   +any  v   →  or=(title.ilike.*v*,company.ilike.*v*)
            //   +tit  v   →  title=ilike.*v*    (raw filter via .or)
            //   +cmp  v   →  company=ilike.*v*  (raw filter via .or)
            //   -any  v   →  title=not.ilike.*v* AND company=not.ilike.*v*
            //                (de Morgan: NOT(A OR B) = NOT A AND NOT B)
            //   -tit  v   →  title=not.ilike.*v*
            //   -cmp  v   →  company=not.ilike.*v*
            //
            // Trigram indexes (`idx_jobs_title_trgm`,
            // `idx_jobs_company_trgm`, `pg_trgm`) cover every ILIKE /
            // NOT ILIKE. Mirrors the web exactly.
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

            // Date range: filter on the precomputed
            // `effective_posted_at` column (populated by
            // `supabase_sync` as `posted_at` parsed to TIMESTAMPTZ
            // when known, else `first_seen`). Single indexed range
            // scan — dodges the 3s anon statement timeout we hit
            // with the compound OR across posted_at (TEXT) and
            // first_seen (TIMESTAMPTZ). Mirrors the web.
            if let floorISO = filters.posted.floorISO {
                query = query.gte("effective_posted_at", value: floorISO)
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

            // Sort: `effective_posted_at` ordered by the user's
            // SortOrder (newest = DESC, oldest = ASC). Covered by
            // `idx_jobs_effective_posted_at` in either direction.
            // The column is populated by
            // `supabase_sync._effective_posted_at` as `posted_at`
            // parsed to TIMESTAMPTZ when the board exposes one,
            // else `first_seen`. A just-discovered job (no
            // posted_at) with first_seen 5 min ago beats a
            // board-posted job from 1 day ago; among board-dated
            // jobs, the most recent posting wins.
            //
            // Single-column sort on a single index — mirrors the
            // web feed so users switching between surfaces see the
            // same top of feed.
            let response = try await query
                .order("effective_posted_at", ascending: filters.sort == .oldest)
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
