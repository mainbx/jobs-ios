//
//  Filters.swift
//  jobs-ios
//
//  Filter catalog + query-building helpers. Mirrors the web's
//  `lib/filters.ts` — keep the two lists in sync by hand.
//
//  Filter semantics match the web:
//    - Free-text `search` matches title OR company (ILIKE substring).
//    - Keyword chips are title-only substring match, OR'd across
//      selections.
//    - `DateRange` applies to `posted_at` (rows with an empty
//      posted_at are dropped when a window is active).
//    - `RemoteFilter` maps to the `is_remote` column. "All" leaves the
//      filter off. "Remote only" keeps is_remote=true, "Onsite only"
//      keeps is_remote=false. Feed is already US-scoped by Supabase.
//

import Foundation

struct Keyword: Identifiable, Hashable {
    /// UI label shown on the chip.
    let label: String
    /// Case-insensitive substring matched against `title` via ILIKE.
    let match: String
    var id: String { match }
}

enum Filters {
    /// Mirrors `jobs-web/src/lib/filters.ts::KEYWORDS`. Keep in sync by
    /// hand when adding / removing chips — chip labels on both
    /// surfaces should match so users jumping between web and iOS
    /// don't get confused.
    static let keywords: [Keyword] = [
        // Generic software
        Keyword(label: "Software",              match: "software"),
        Keyword(label: "Software Engineer",     match: "software engineer"),
        Keyword(label: "SWE",                   match: "swe"),
        Keyword(label: "SDE",                   match: "sde"),
        Keyword(label: "Developer",             match: "developer"),
        Keyword(label: "Engineer",              match: "engineer"),
        Keyword(label: "Staff Engineer",        match: "staff engineer"),
        Keyword(label: "Principal Engineer",    match: "principal engineer"),

        // Layered software roles
        Keyword(label: "Backend",               match: "backend"),
        Keyword(label: "Backend Engineer",      match: "backend engineer"),
        Keyword(label: "Fullstack",             match: "fullstack"),
        Keyword(label: "Full-Stack",            match: "full-stack"),
        Keyword(label: "Full Stack",            match: "full stack"),
        Keyword(label: "Application",           match: "application"),
        Keyword(label: "Framework",             match: "framework"),
        Keyword(label: "Product",               match: "product"),

        // AI / ML / Data
        Keyword(label: "AI",                    match: "ai"),
        Keyword(label: "AI Engineer",           match: "ai engineer"),
        Keyword(label: "ML Engineer",           match: "ml engineer"),
        Keyword(label: "Algorithm",             match: "algorithm"),
        Keyword(label: "Research Engineer",     match: "research engineer"),
        Keyword(label: "Research Scientist",    match: "research scientist"),
        Keyword(label: "Data",                  match: "data"),
        Keyword(label: "Data Engineer",         match: "data engineer"),
        Keyword(label: "Data Scientist",        match: "data scientist"),
        Keyword(label: "Data Science",          match: "data science"),

        // Systems / infra / network
        Keyword(label: "Systems",               match: "systems"),
        Keyword(label: "Network",               match: "network"),
        Keyword(label: "Network Engineer",      match: "network engineer"),
        Keyword(label: "Compute",               match: "compute"),
        Keyword(label: "Connectivity",          match: "connectivity"),
        Keyword(label: "Validation",            match: "validation"),

        // Hardware / silicon
        Keyword(label: "Embedded",              match: "embedded"),
        Keyword(label: "Embedded Systems",      match: "embedded systems"),
        Keyword(label: "Firmware",              match: "firmware"),
        Keyword(label: "Kernel",                match: "kernel"),
        Keyword(label: "Hardware",              match: "hardware"),
        Keyword(label: "Silicon",               match: "silicon"),
        Keyword(label: "GPU",                   match: "gpu"),
        Keyword(label: "CPU",                   match: "cpu"),
        Keyword(label: "RF",                    match: "rf"),

        // Robotics
        Keyword(label: "Robotics",              match: "robotics"),
        Keyword(label: "Robot",                 match: "robot"),

        // Quant / trading
        Keyword(label: "Trader",                match: "trader"),
        Keyword(label: "Trading",               match: "trading"),
        Keyword(label: "Quant",                 match: "quant"),

        // Languages
        Keyword(label: "Python",                match: "python"),
        Keyword(label: "C++",                   match: "c++"),
        Keyword(label: "Rust",                  match: "rust"),

        // Intern / grad seasons
        Keyword(label: "Fall",                  match: "fall"),
        Keyword(label: "Fall 2026",             match: "fall 2026"),
    ]
}

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

    /// Lower-bound timestamps for the compound date filter.
    ///
    /// Returns two strings because the filter runs on two columns:
    ///   - `posted_at` (TEXT) — needs byte-level format match with
    ///     the backend's `normalize_posted_at` output, which is
    ///     `YYYY-MM-DDTHH:MM:SS+00:00` (no millis, `+00:00` suffix).
    ///     PostgREST's `gte` is a lexicographic compare so exact
    ///     format alignment matters.
    ///   - `first_seen` (TIMESTAMPTZ) — native timestamp compare,
    ///     any valid ISO works.
    ///
    /// `nil` means "Any time" — no floor, feed returns everything.
    var floors: (postedText: String, iso: String)? {
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
        let iso = full.string(from: floor)

        let compact = ISO8601DateFormatter()
        compact.formatOptions = [.withInternetDateTime]
        // `.withInternetDateTime` produces "...Z"; rewrite to "+00:00"
        // to match the backend's stored format exactly.
        let postedText = compact.string(from: floor).replacingOccurrences(of: "Z", with: "+00:00")

        return (postedText: postedText, iso: iso)
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
/// map 1:1 to values populated at Supabase-sync time by
/// `jobwatcher.tiers.tier_for()`. Keep in sync with
/// `../../jobs-web/src/lib/filters.ts::TIER_FILTERS`.
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
    var keywords: Set<String> = []   // stores the `.match` values
    var posted: DateRange = .any
    var remote: RemoteFilter = .all
    var tier: TierFilter = .all

    var isEmpty: Bool {
        search.isEmpty && keywords.isEmpty && posted == .any && remote == .all && tier == .all
    }
}
