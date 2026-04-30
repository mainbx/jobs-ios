//
//  Filters.swift
//  jobs-ios
//
//  Filter helpers + types for the feed. Mirrors the web's
//  `lib/filters.ts` — keep semantics in sync by hand.
//
//  Search is **Google-style** with the four operators users actually
//  muscle-memory:
//
//    plain words            lululemon staff engineer
//                           ↑ AND'd; each word must hit title|company
//    quoted phrases         "staff software engineer"
//                           'morgan stanley'
//    negation               -intern   -"new grad"
//                           ↑ row must NOT contain that term
//    field constraints      title:engineer
//                           company:"morgan stanley"
//                           -title:vp
//
//  All four combine freely. Whitespace, `,`, and `;` are interchangeable
//  separators.
//
//  - `DateRange` applies to `effective_posted_at` (board `posted_at`
//    when known, else `first_seen`).
//  - `RemoteFilter` maps to the `is_remote` column.
//  - `TierFilter` maps to the `tier` column populated at sync time.
//  - `StateFilter` maps to the backend-populated `states` array.
//
//  Wire shape: `parseSearchAtoms` returns a list of `SearchAtom`s.
//  Each atom becomes one or two PostgREST filters (see the type doc).
//  PostgREST joins repeated request params with AND, so we never
//  construct nested `and(or(...))` URL syntax by hand. Trigram indexes
//  (`idx_jobs_title_trgm`, `idx_jobs_company_trgm`, `pg_trgm`) cover
//  every ILIKE / NOT ILIKE.
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

/// Sort order for the feed. `.newest` is the default; `.oldest` flips
/// `effective_posted_at` ascending. Mirrors the web's `SortOrder`.
///
/// One subtle interaction: the landing-page diversification shuffle
/// in `FeedViewModel.performLoad` only fires when sort is at default
/// (`.newest`). Picking `.oldest` (or any sort explicitly) disables
/// the shuffle and gives deterministic chronological order.
enum SortOrder: String, CaseIterable, Identifiable {
    case newest
    case oldest

    var id: String { rawValue }

    var label: String {
        switch self {
        case .newest: return "Newest first"
        case .oldest: return "Oldest first"
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
    // Renamed from `.faang` / `"FAANG+"` on 2026-04-29: Facebook is
    // Meta now, the modern acronym is MAANG (Meta, Apple, Amazon,
    // Netflix, Google). The dbValue + Supabase rows were flipped
    // atomically; no migration needed on the iOS side.
    case maang = "maang"
    case tier1 = "t1"
    case tier2 = "t2"
    case tier3 = "t3"
    case startups = "startups"

    var id: String { rawValue }

    var label: String {
        switch self {
        case .all: return "All tiers"
        case .maang: return "MAANG+"
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
        case .maang: return "MAANG+"
        case .tier1: return "Tier 1"
        case .tier2: return "Tier 2"
        case .tier3: return "Tier 3"
        case .startups: return "Startups"
        }
    }
}

/// US state / DC / territory filter. `.all` leaves it off. Concrete
/// values overlap the backend `states` text array with `[code, "*"]`
/// so nationwide rows appear under every state filter.
enum StateFilter: String, CaseIterable, Identifiable {
    case all = "all"
    case al = "AL", ak = "AK", az = "AZ", ar = "AR", ca = "CA"
    case co = "CO", ct = "CT", de = "DE", fl = "FL", ga = "GA"
    case hi = "HI", id = "ID", il = "IL", indiana = "IN", ia = "IA"
    case ks = "KS", ky = "KY", la = "LA", me = "ME", md = "MD"
    case ma = "MA", mi = "MI", mn = "MN", ms = "MS", mo = "MO"
    case mt = "MT", ne = "NE", nv = "NV", nh = "NH", nj = "NJ"
    case nm = "NM", ny = "NY", nc = "NC", nd = "ND", oh = "OH"
    case ok = "OK", oregon = "OR", pa = "PA", ri = "RI", sc = "SC"
    case sd = "SD", tn = "TN", tx = "TX", ut = "UT", vt = "VT"
    case va = "VA", wa = "WA", wv = "WV", wi = "WI", wy = "WY"
    case dc = "DC", pr = "PR", vi = "VI", gu = "GU", mp = "MP", americanSamoa = "AS"

    var id: String { rawValue }

    var label: String {
        switch self {
        case .all: return "All states"
        case .al: return "Alabama"
        case .ak: return "Alaska"
        case .az: return "Arizona"
        case .ar: return "Arkansas"
        case .ca: return "California"
        case .co: return "Colorado"
        case .ct: return "Connecticut"
        case .de: return "Delaware"
        case .fl: return "Florida"
        case .ga: return "Georgia"
        case .hi: return "Hawaii"
        case .id: return "Idaho"
        case .il: return "Illinois"
        case .indiana: return "Indiana"
        case .ia: return "Iowa"
        case .ks: return "Kansas"
        case .ky: return "Kentucky"
        case .la: return "Louisiana"
        case .me: return "Maine"
        case .md: return "Maryland"
        case .ma: return "Massachusetts"
        case .mi: return "Michigan"
        case .mn: return "Minnesota"
        case .ms: return "Mississippi"
        case .mo: return "Missouri"
        case .mt: return "Montana"
        case .ne: return "Nebraska"
        case .nv: return "Nevada"
        case .nh: return "New Hampshire"
        case .nj: return "New Jersey"
        case .nm: return "New Mexico"
        case .ny: return "New York"
        case .nc: return "North Carolina"
        case .nd: return "North Dakota"
        case .oh: return "Ohio"
        case .ok: return "Oklahoma"
        case .oregon: return "Oregon"
        case .pa: return "Pennsylvania"
        case .ri: return "Rhode Island"
        case .sc: return "South Carolina"
        case .sd: return "South Dakota"
        case .tn: return "Tennessee"
        case .tx: return "Texas"
        case .ut: return "Utah"
        case .vt: return "Vermont"
        case .va: return "Virginia"
        case .wa: return "Washington"
        case .wv: return "West Virginia"
        case .wi: return "Wisconsin"
        case .wy: return "Wyoming"
        case .dc: return "Washington, D.C."
        case .pr: return "Puerto Rico"
        case .vi: return "U.S. Virgin Islands"
        case .gu: return "Guam"
        case .mp: return "Northern Mariana Islands"
        case .americanSamoa: return "American Samoa"
        }
    }

    var dbValue: String? {
        self == .all ? nil : rawValue
    }
}

/// Snapshot of every filter the user has active. Passed to the view
/// model's `load(filters:)`.
struct FilterState: Equatable {
    var search: String = ""
    var posted: DateRange = .any
    var remote: RemoteFilter = .all
    var tier: TierFilter = .all
    var state: StateFilter = .all
    var sort: SortOrder = .newest

    /// `true` iff every dimension (including search) is at its default
    /// — the only time the *whole* feed is unfiltered.
    var isEmpty: Bool {
        search.isEmpty && !hasNonSearchFilters
    }

    /// `true` iff date / remote / tier / sort have any active
    /// constraint, ignoring search. Drives the "Clear filters" button
    /// — keeping it decoupled from the search field's own clear.
    var hasNonSearchFilters: Bool {
        posted != .any || remote != .all || tier != .all || state != .all || sort != .newest
    }
}


/// Column the `field:value` operator is allowed to constrain to.
/// Anything else falls through to `.any` so a stray `email:foo@bar.com`
/// paste doesn't blow up the query.
enum SearchScope: String {
    case any
    case title
    case company
}

/// One parsed unit from a Google-style search input. The query layer
/// applies each atom as its own PostgREST filter — repeated request
/// params AND together at the URL level, which is exactly what
/// "every term must match somewhere" needs.
///
/// Wire shape per atom (`*` = ILIKE wildcard in PostgREST URL syntax):
///
///   negate=false, scope=.any      → `or=(title.ilike.*v*,company.ilike.*v*)`
///   negate=false, scope=.title    → `title=ilike.*v*`
///   negate=false, scope=.company  → `company=ilike.*v*`
///   negate=true,  scope=.any      → `title=not.ilike.*v*` AND `company=not.ilike.*v*`
///                                   (de Morgan: NOT(A OR B) = NOT A AND NOT B)
///   negate=true,  scope=.title    → `title=not.ilike.*v*`
///   negate=true,  scope=.company  → `company=not.ilike.*v*`
struct SearchAtom: Equatable {
    /// True for `-term`, `-"phrase"`, or `-field:value` (exclude).
    var negate: Bool
    /// Column constraint — `.any` searches title OR company.
    var scope: SearchScope
    /// ILIKE substring (no wildcards yet — caller wraps in `*…*`).
    var value: String
}

/// Parse a free-text Google-style search input into atoms.
///
/// Recognised syntax (all combinable):
///
///   bare keyword            `lululemon`              must appear in title|company
///   quoted phrase           `"staff engineer"`       phrase preserved as one term
///                           `'morgan stanley'`       (apostrophe form too)
///   negation                `-intern`                row must NOT contain "intern"
///                           `-"new grad"`            anywhere in title or company
///   field constraint        `title:engineer`         match only that column
///                           `company:"morgan stanley"`
///   negated field           `-title:vp`              that column must NOT contain "vp"
///
/// Separators between atoms: whitespace, `,`, and `;` — all interchangeable.
///
/// Quoting rules: `"…"` and `'…'` only open phrase mode at the *start*
/// of an atom, so mid-word apostrophes (`mcdonald's`, `o'reilly`)
/// survive intact. Unbalanced quotes are tolerated — the rest of the
/// input is consumed up to EOF.
///
/// Field whitelist: only `title:` and `company:` are recognised. Other
/// `xyz:abc` patterns fall through to a bare `xyz:abc` term (no special
/// meaning) so users don't get silent zero-result surprises.
///
/// Implementation note: the TS sibling in `lib/filters.ts` uses the
/// same algorithm. Output verified bit-identical across the same test
/// cases (see commit history).
func parseSearchAtoms(_ input: String) -> [SearchAtom] {
    var seen = Set<String>()
    var out: [SearchAtom] = []
    let chars = Array(input)
    let n = chars.count
    var i = 0

    func isSep(_ c: Character) -> Bool {
        c.isWhitespace || c == "," || c == ";"
    }

    while i < n {
        // Skip leading separators.
        while i < n && isSep(chars[i]) { i += 1 }
        if i >= n { break }

        var negate = false
        var scope: SearchScope = .any

        // Leading `-` for negation. Must be followed by a non-separator,
        // otherwise it's a stray dash — skip past it.
        if chars[i] == "-" {
            let peek = i + 1
            if peek >= n || isSep(chars[peek]) {
                i += 1
                continue
            }
            negate = true
            i = peek
        }

        // `field:` prefix (only `title:` and `company:` recognised,
        // case-insensitive).
        let remainingStart = i
        let lookahead = String(chars[remainingStart..<min(remainingStart + 9, n)])
            .lowercased()
        if lookahead.hasPrefix("title:") {
            scope = .title
            i += 6
        } else if lookahead.hasPrefix("company:") {
            scope = .company
            i += 8
        }
        if scope != .any && (i >= n || isSep(chars[i])) {
            // `title:` / `-title:` with empty value — drop the atom.
            continue
        }

        // Collect the value: quoted phrase or bare run.
        var value: String
        if i < n && (chars[i] == "\"" || chars[i] == "'") {
            let quote = chars[i]
            i += 1
            var end = i
            while end < n && chars[end] != quote { end += 1 }
            value = String(chars[i..<end])
            i = end < n ? end + 1 : end
        } else {
            var end = i
            while end < n && !isSep(chars[end]) { end += 1 }
            value = String(chars[i..<end])
            i = end
        }

        // Strip PostgREST-hostile chars + collapse whitespace.
        var cleaned = value
            .replacingOccurrences(of: "(", with: " ")
            .replacingOccurrences(of: ")", with: " ")
            .replacingOccurrences(of: ",", with: " ")
        cleaned = cleaned
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
        // Strip stray leading/trailing quotes from unbalanced input.
        while let first = cleaned.first, first == "'" || first == "\"" {
            cleaned.removeFirst()
        }
        while let last = cleaned.last, last == "'" || last == "\"" {
            cleaned.removeLast()
        }
        cleaned = cleaned.trimmingCharacters(in: .whitespaces)
        if cleaned.isEmpty { continue }

        // Dedup by full atom signature (`-foo foo` keeps both, but
        // `foo foo` collapses to one).
        let key = "\(negate ? "-" : "+")\(scope.rawValue):\(cleaned.lowercased())"
        if seen.contains(key) { continue }
        seen.insert(key)
        out.append(SearchAtom(negate: negate, scope: scope, value: cleaned))
    }

    return out
}

/// Backward-compat shim — bare keyword strings only (no negation, no
/// field scope). Callers should consume `parseSearchAtoms` directly.
func splitSearchTerms(_ input: String) -> [String] {
    parseSearchAtoms(input)
        .filter { !$0.negate && $0.scope == .any }
        .map { $0.value }
}
