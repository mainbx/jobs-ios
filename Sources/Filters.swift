//
//  Filters.swift
//  jobs-ios
//
//  Filter helpers + types for the feed. Mirrors the web's
//  `lib/filters.ts` — keep semantics in sync by hand.
//
//  Filter semantics:
//    - Free-text `search` is **multi-keyword**. The user types one or
//      more terms separated by `,` or `;`; each term becomes an ILIKE
//      substring match against title OR company; everything OR'd
//      together. Single-term inputs ("rust") behave like before.
//      Multi-term ("intern, engineer") gets the union.
//    - `DateRange` applies to `effective_posted_at`: backend-normalized
//      board `posted_at` when known, else `first_seen`.
//    - `RemoteFilter` maps to the `is_remote` column. "All" leaves the
//      filter off. "Remote only" keeps `is_remote=true`. The feed is
//      already US-scoped by Supabase.
//    - `TierFilter` maps to the `tier` column populated at
//      Supabase-sync time by the backend's tier classifier.
//
//  The pre-defined keyword chip catalog was removed in favor of free-
//  text multi-keyword search. The DB-side semantics are unchanged:
//  same trigram indexes (`idx_jobs_title_trgm`, `idx_jobs_company_trgm`)
//  cover both shapes.
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
/// - Splits on commas AND semicolons (users habitually use either).
/// - Trims each term, drops empties, de-duplicates case-insensitively.
/// - Strips `(`, `)`, `,` from each term — those characters break
///   PostgREST's ``or(...)`` filter syntax. Single quotes pass through
///   harmlessly inside the substring portion of an ``ilike`` value.
///
/// Examples:
///   ""                       → []
///   "rust"                   → ["rust"]
///   "rust, go"               → ["rust", "go"]
///   "rust ; go ; rust"       → ["rust", "go"]   // dedup
///   "intern; 'engineer'"     → ["intern", "'engineer'"]
func splitSearchTerms(_ input: String) -> [String] {
    var seen = Set<String>()
    var out: [String] = []
    let strippedSet = CharacterSet(charactersIn: "(),")
    for raw in input.split(whereSeparator: { $0 == "," || $0 == ";" }) {
        let cleanedScalars = String(raw).unicodeScalars.map { strippedSet.contains($0) ? Unicode.Scalar(" ") : $0 }
        let cleaned = String(String.UnicodeScalarView(cleanedScalars))
            .trimmingCharacters(in: .whitespaces)
        guard !cleaned.isEmpty else { continue }
        let key = cleaned.lowercased()
        if seen.contains(key) { continue }
        seen.insert(key)
        out.append(cleaned)
    }
    return out
}

/// Build a PostgREST ``or(...)`` clause covering the search terms
/// across the given columns. Each term × each column = one ILIKE
/// substring comparison; everything OR'd.
///
/// Returns ``nil`` when the term list is empty (caller skips the
/// filter).
///
/// Example: ``searchOrClause(["intern", "engineer"], ["title", "company"])``
///   →  "title.ilike.*intern*,title.ilike.*engineer*,company.ilike.*intern*,company.ilike.*engineer*"
///
/// The trigram indexes on ``title`` + ``company`` cover the ILIKE
/// lookup; multi-term queries don't change index usage compared to the
/// old single-substring shape.
func searchOrClause(_ terms: [String], columns: [String]) -> String? {
    guard !terms.isEmpty else { return nil }
    var parts: [String] = []
    for col in columns {
        for t in terms {
            parts.append("\(col).ilike.*\(t)*")
        }
    }
    return parts.joined(separator: ",")
}
