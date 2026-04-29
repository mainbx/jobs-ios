//
//  Filters.swift
//  jobs-ios
//
//  Filter helpers + types for the feed. Mirrors the web's
//  `lib/filters.ts` — keep semantics in sync by hand.
//
//  Filter semantics:
//    - Free-text `search` is **Google-style AND-of-keywords**. The
//      user types any number of words (separated by whitespace,
//      `,`, or `;`); a row matches only when *every* term is found in
//      either the title or the company. Quoted phrases
//      (`"staff software engineer"` / `'lululemon devops'`) stay as a
//      single term. The previous OR semantics meant typing more
//      words *broadened* the result set, opposite of how every other
//      search box works.
//    - `DateRange` applies to `effective_posted_at`: backend-normalized
//      board `posted_at` when known, else `first_seen`.
//    - `RemoteFilter` maps to the `is_remote` column. "All" leaves the
//      filter off. "Remote only" keeps `is_remote=true`. The feed is
//      already US-scoped by Supabase.
//    - `TierFilter` maps to the `tier` column populated at
//      Supabase-sync time by the backend's tier classifier.
//
//  Wire shape per term: each term emits one PostgREST `or(...)` clause
//  that ORs `title ILIKE *t*` against `company ILIKE *t*`. The caller
//  chains `.or(clause)` once per term; supabase-swift + PostgREST
//  joins repeated `or=` query parameters with AND. Trigram indexes
//  (`idx_jobs_title_trgm`, `idx_jobs_company_trgm`, `pg_trgm`) cover
//  every ILIKE.
//
//  The pre-defined keyword chip catalog was removed earlier in favor
//  of free-text search.
//

import Foundation

enum DateRange: String, CaseIterable, Identifiable {
    case any = "any"
    case h24 = "24h"
    case d7 = "7d"
    case d30 = "30d"

    var id: String { rawValue }

    var label: String {
        switch self {
        case .any: return "Any time"
        case .h24: return "Last 24 hours"
        case .d7: return "Last 7 days"
        case .d30: return "Last 30 days"
        }
    }

    /// Lower-bound timestamp for the date filter.
    ///
    /// The query compares this against `effective_posted_at`, a backend
    /// TIMESTAMPTZ populated from board `posted_at` when known, else
    /// `first_seen`. A single indexed timestamp avoids the old slow
    /// compound query across `posted_at` TEXT and `first_seen`.
    ///
    /// `nil` means "Any time" — no floor, feed returns everything.
    var floorISO: String? {
        let days: Int
        switch self {
        case .any: return nil
        case .h24: days = 1
        case .d7: days = 7
        case .d30: days = 30
        }
        let floor = Date().addingTimeInterval(TimeInterval(-days * 24 * 60 * 60))

        let full = ISO8601DateFormatter()
        full.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return full.string(from: floor)
    }
}

/// Two-state filter on the `is_remote` column. `.all` leaves the
/// filter off; `.remote` narrows to `is_remote=true`. The feed is
/// already US-scoped by the Supabase mirror, so "Remote only" =
/// remote-workable from the US. Onsite isn't surfaced — the only
/// non-default case users actually ask for is "hide non-remote."
enum RemoteFilter: String, CaseIterable, Identifiable {
    case all = "all"
    case remote = "remote"

    var id: String { rawValue }

    var label: String {
        switch self {
        case .all: return "All roles"
        case .remote: return "Remote only"
        }
    }
}

/// Company-tier filter on the `tier` column. `.all` leaves it off
/// (unranked rows only show up in that mode). The four labeled cases
/// map 1:1 to values populated at Supabase-sync time by the backend's
/// tier classifier. Keep in sync with the web frontend's
/// `src/lib/filters.ts::TIER_FILTERS`.
enum TierFilter: String, CaseIterable, Identifiable {
    case all = "all"
    case faang = "faang"
    case tier1 = "t1"
    case tier2 = "t2"
    case tier3 = "t3"
    case startups = "startups"

    var id: String { rawValue }

    var label: String {
        switch self {
        case .all: return "All tiers"
        case .faang: return "FAANG+"
        case .tier1: return "Tier 1"
        case .tier2: return "Tier 2"
        case .tier3: return "Tier 3"
        case .startups: return "Startups"
        }
    }

    /// String stored on the `tier` column on Supabase, or `nil` for
    /// `.all` (which means "don't filter").
    var dbValue: String? {
        switch self {
        case .all: return nil
        case .faang: return "FAANG+"
        case .tier1: return "Tier 1"
        case .tier2: return "Tier 2"
        case .tier3: return "Tier 3"
        case .startups: return "Startups"
        }
    }
}

/// Snapshot of every filter the user has active. Passed to the view
/// model's `load(filters:)`.
struct FilterState: Equatable {
    var search: String = ""
    var posted: DateRange = .any
    var remote: RemoteFilter = .all
    var tier: TierFilter = .all

    var isEmpty: Bool {
        search.isEmpty && posted == .any && remote == .all && tier == .all
    }
}

/// Split a free-text search input into individual ILIKE-ready terms.
///
/// Tokenizer:
///   - Quoted phrases (`"staff software engineer"` or
///     `'lululemon devops'`) stay as a single term. Quotes only open
///     phrase mode at the start of a token, so mid-word apostrophes
///     (`mcdonald's`, `o'reilly`) survive intact.
///   - Anything else is split on whitespace, `,` and `;` — all three
///     are treated identically. (Whitespace was *not* a separator
///     before, which is why typing "lululemon staff software engineer"
///     used to return zero rows: it became one giant 32-char term.)
///   - Empty terms are dropped, case-insensitive de-dup, internal
///     whitespace collapsed.
///   - Characters that would break PostgREST's `or(...)` syntax —
///     `(`, `)`, `,` — are replaced with spaces. Stray leading or
///     trailing quotes (from unbalanced input like `staff "engineer`)
///     are stripped.
///
/// Examples:
///   ""                                     → []
///   "rust"                                 → ["rust"]
///   "lululemon staff software engineer"    → ["lululemon", "staff", "software", "engineer"]
///   "staff software engineer; lululemon"   → ["staff", "software", "engineer", "lululemon"]
///   "\"staff software engineer\" lululemon" → ["staff software engineer", "lululemon"]
///   "rust, rust ; rust"                    → ["rust"]                        // dedup
///   "mcdonald's"                           → ["mcdonald's"]                  // mid apostrophe kept
func splitSearchTerms(_ input: String) -> [String] {
    var seen = Set<String>()
    var out: [String] = []
    var current = ""
    var inDouble = false
    var inSingle = false

    func flush() {
        // Replace PostgREST-hostile chars with spaces, collapse internal
        // whitespace, then trim.
        var cleaned = current
            .replacingOccurrences(of: "(", with: " ")
            .replacingOccurrences(of: ")", with: " ")
            .replacingOccurrences(of: ",", with: " ")
        cleaned = cleaned
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
        // Strip leading/trailing stray quotes from unbalanced phrases
        // like `"unclosed` or `engineer"`. Mid-word apostrophes are
        // unaffected because we never opened phrase mode for them.
        while let first = cleaned.first, first == "'" || first == "\"" {
            cleaned.removeFirst()
        }
        while let last = cleaned.last, last == "'" || last == "\"" {
            cleaned.removeLast()
        }
        cleaned = cleaned.trimmingCharacters(in: .whitespaces)
        current = ""
        guard !cleaned.isEmpty else { return }
        let key = cleaned.lowercased()
        if seen.contains(key) { return }
        seen.insert(key)
        out.append(cleaned)
    }

    for c in input {
        if inDouble {
            if c == "\"" { inDouble = false; flush() }
            else { current.append(c) }
            continue
        }
        if inSingle {
            if c == "'" { inSingle = false; flush() }
            else { current.append(c) }
            continue
        }
        if c == "\"" {
            if !current.isEmpty { flush() }
            inDouble = true
            continue
        }
        if c == "'" {
            // Open phrase mode only when the apostrophe starts a token
            // — otherwise it's mid-word (e.g. `mcdonald's`).
            if current.isEmpty {
                inSingle = true
            } else {
                current.append(c)
            }
            continue
        }
        if c.isWhitespace || c == "," || c == ";" {
            if !current.isEmpty { flush() }
            continue
        }
        current.append(c)
    }
    if !current.isEmpty { flush() }
    return out
}

/// Build one PostgREST `or(...)` clause **per term**. Each clause ORs
/// the term against every column — `title.ilike.*t*,company.ilike.*t*`
/// — and the caller chains `.or(clause)` once per clause so the
/// request gains one repeated `or=…` query parameter per term.
/// PostgREST joins those with AND, giving us
///
///     (t1 in title|company) AND (t2 in title|company) AND …
///
/// for free, with no nested-filter syntax to debug.
///
/// Returns an empty array when the term list is empty (caller skips).
///
/// Example: `searchTermClauses(["lululemon", "staff"], ["title", "company"])`
///   → [
///       "title.ilike.*lululemon*,company.ilike.*lululemon*",
///       "title.ilike.*staff*,company.ilike.*staff*",
///     ]
func searchTermClauses(_ terms: [String], columns: [String]) -> [String] {
    return terms.map { t in
        columns.map { col in "\(col).ilike.*\(t)*" }.joined(separator: ",")
    }
}
