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
//    - `DateRange` applies to `effective_posted_at`: backend-normalized
//      board `posted_at` when known, else `first_seen`.
//    - `RemoteFilter` maps to the `is_remote` column. "All" leaves the
//      filter off. "Remote only" keeps is_remote=true. Feed is already
//      US-scoped by Supabase.
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
        Keyword(label: "Software Engineering",  match: "software engineering"),
        // `match` uses PostgreSQL ILIKE `%<match>%` on the backend, so
        // 2-3 letter acronyms get space-padded to stop them matching
        // inside words like "sweetwater" / "html" / "email" / "inside".
        // The feed is already narrowed by the relevance classifier
        // (which uses `\b…\b` regex in ``matcher.py``) so collisions
        // are rare in practice, but the space padding is
        // belt-and-suspenders.
        Keyword(label: "SWE",                   match: " swe "),
        Keyword(label: "SDE",                   match: " sde "),
        Keyword(label: "SDET",                  match: " sdet "),
        Keyword(label: "MTS",                   match: " mts "),
        Keyword(label: "SRE",                   match: " sre "),
        Keyword(label: "GTM",                   match: " gtm "),
        Keyword(label: "Developer",             match: "developer"),
        Keyword(label: "Engineer",              match: "engineer"),
        Keyword(label: "Engineering",           match: "engineering"),
        Keyword(label: "Technical",             match: "technical"),
        Keyword(label: "Staff Engineer",        match: "staff engineer"),
        Keyword(label: "Principal Engineer",    match: "principal engineer"),
        Keyword(label: "Principal",             match: "principal"),
        Keyword(label: "Distinguished",         match: "distinguished"),
        Keyword(label: "Member of Technical Staff", match: "member of technical staff"),

        // Architecture / solutions
        Keyword(label: "Architect",             match: "architect"),
        Keyword(label: "Solutions Architect",   match: "solutions architect"),
        Keyword(label: "Security Architect",    match: "security architect"),
        Keyword(label: "Solution Engineer",     match: "solution engineer"),
        Keyword(label: "Solutions Engineer",    match: "solutions engineer"),

        // Forward-deployed / applied / success / deployment engineering
        Keyword(label: "Forward Deployed",      match: "forward deployed"),
        Keyword(label: "Forward Deployed Engineer", match: "forward deployed engineer"),
        Keyword(label: "FDE",                   match: " fde "),
        Keyword(label: "Applied AI Engineer",   match: "applied ai engineer"),
        Keyword(label: "AI Deployment Engineer", match: "ai deployment engineer"),
        Keyword(label: "Deployment Engineer",   match: "deployment engineer"),
        Keyword(label: "Technical Deployment",  match: "technical deployment"),
        Keyword(label: "Technical Development", match: "technical development"),
        Keyword(label: "Technical Program Management", match: "technical program management"),
        Keyword(label: "Support Engineer",      match: "support engineer"),
        Keyword(label: "Production Engineer",   match: "production engineer"),
        Keyword(label: "Performance Engineer",  match: "performance engineer"),
        Keyword(label: "Performance",           match: "performance"),
        Keyword(label: "Observability",         match: "observability"),
        Keyword(label: "Inference",             match: "inference"),
        Keyword(label: "Distributed",           match: "distributed"),
        Keyword(label: "Agent",                 match: "agent"),
        Keyword(label: "Agents",                match: "agents"),
        Keyword(label: "Startup",               match: "startup"),
        Keyword(label: "Prompt Engineer",       match: "prompt engineer"),
        Keyword(label: "Product Design Engineer", match: "product design engineer"),
        Keyword(label: "Product Engineer",      match: "product engineer"),
        Keyword(label: "Customer Engineer",     match: "customer engineer"),
        Keyword(label: "Developer Advocate",    match: "developer advocate"),
        Keyword(label: "Developer Experience",  match: "developer experience"),
        Keyword(label: "DevEx",                 match: " devex "),
        Keyword(label: "DevX",                  match: " devx "),
        Keyword(label: "Solutions Consultant",  match: "solutions consultant"),
        Keyword(label: "Operations Engineer",   match: "operations engineer"),
        Keyword(label: "Operations Engineering", match: "operations engineering"),
        Keyword(label: "Red Team",              match: "red team"),
        Keyword(label: "Offensive Security",    match: "offensive security"),

        // Layered software roles
        Keyword(label: "Backend",               match: "backend"),
        Keyword(label: "Backend Engineer",      match: "backend engineer"),
        Keyword(label: "Frontend",              match: "frontend"),
        Keyword(label: "Fullstack",             match: "fullstack"),
        Keyword(label: "Full-Stack",            match: "full-stack"),
        Keyword(label: "Full Stack",            match: "full stack"),
        Keyword(label: "Application",           match: "application"),
        Keyword(label: "Framework",             match: "framework"),

        // Product
        Keyword(label: "Product",               match: "product"),
        Keyword(label: "Product Manager",       match: "product manager"),
        Keyword(label: "Product Management",    match: "product management"),
        Keyword(label: "Product Owner",         match: "product owner"),

        // AI / ML / Data
        Keyword(label: "AI",                    match: " ai "),
        Keyword(label: "AI Engineer",           match: "ai engineer"),
        Keyword(label: "ML",                    match: " ml "),
        Keyword(label: "ML Engineer",           match: "ml engineer"),
        Keyword(label: "ML Ops",                match: "ml ops"),
        Keyword(label: "MLOps",                 match: "mlops"),
        Keyword(label: "ML Platform",           match: "ml platform"),
        Keyword(label: "LLM",                   match: " llm "),
        Keyword(label: "Language Model",        match: "language model"),
        Keyword(label: "Machine Learning",      match: "machine learning"),
        Keyword(label: "Agentic",               match: "agentic"),
        Keyword(label: "AI Agents",             match: "ai agents"),
        Keyword(label: "Automated Reasoning",   match: "automated reasoning"),
        Keyword(label: "Reasoning",             match: "reasoning"),
        Keyword(label: "Algorithm",             match: "algorithm"),
        Keyword(label: "Research Engineer",     match: "research engineer"),
        Keyword(label: "Research Scientist",    match: "research scientist"),
        Keyword(label: "Research Manager",      match: "research manager"),
        Keyword(label: "Research Lead",         match: "research lead"),
        Keyword(label: "Researcher",            match: "researcher"),
        Keyword(label: "Fellow",                match: "fellow"),
        Keyword(label: "Fellows",               match: "fellows"),
        Keyword(label: "Applied Science",       match: "applied science"),
        Keyword(label: "Applied Scientist",     match: "applied scientist"),
        Keyword(label: "Applied Research",      match: "applied research"),
        Keyword(label: "Research Intern",       match: "research intern"),
        Keyword(label: "Data",                  match: "data"),
        Keyword(label: "Data Engineer",         match: "data engineer"),
        Keyword(label: "Data Scientist",        match: "data scientist"),
        Keyword(label: "Data Science",          match: "data science"),
        Keyword(label: "Data Center",           match: "data center"),
        Keyword(label: "Search",                match: "search"),
        Keyword(label: "Ads",                   match: " ads "),

        // Systems / infra / network / SRE / security
        Keyword(label: "Infrastructure",        match: "infrastructure"),
        Keyword(label: "Infrastructure Engineer", match: "infrastructure engineer"),
        Keyword(label: "Machines Infrastructure", match: "machines infrastructure"),
        Keyword(label: "AI Infrastructure",     match: "ai infrastructure"),
        Keyword(label: "Cloud",                 match: "cloud"),
        Keyword(label: "Cloud Inference",       match: "cloud inference"),
        Keyword(label: "AWS",                   match: " aws "),
        Keyword(label: "Site Reliability",      match: "site reliability"),
        Keyword(label: "Site",                  match: "site"),
        Keyword(label: "Systems",               match: "systems"),
        Keyword(label: "Network",               match: "network"),
        Keyword(label: "Network Engineer",      match: "network engineer"),
        Keyword(label: "Compute",               match: "compute"),
        Keyword(label: "Connectivity",          match: "connectivity"),
        Keyword(label: "Validation",            match: "validation"),
        Keyword(label: "Verification Engineer", match: "verification engineer"),
        Keyword(label: "Security",              match: "security"),
        Keyword(label: "Security Engineer",     match: "security engineer"),
        Keyword(label: "Trust",                 match: "trust"),
        Keyword(label: "Trust & Safety",        match: "trust & safety"),

        // Test / QA
        Keyword(label: "Test",                  match: "test"),
        Keyword(label: "Test Engineer",         match: "test engineer"),

        // Hardware / silicon / electrical / digital
        Keyword(label: "Embedded",              match: "embedded"),
        Keyword(label: "Embedded Systems",      match: "embedded systems"),
        Keyword(label: "Firmware",              match: "firmware"),
        Keyword(label: "Kernel",                match: "kernel"),
        Keyword(label: "Kernels",               match: "kernels"),
        Keyword(label: "TPU",                   match: " tpu "),
        Keyword(label: "Linux",                 match: "linux"),
        Keyword(label: "Unix",                  match: "unix"),
        Keyword(label: "Hardware",              match: "hardware"),
        Keyword(label: "Silicon",               match: "silicon"),
        Keyword(label: "GPU",                   match: "gpu"),
        Keyword(label: "CPU",                   match: "cpu"),
        Keyword(label: "RF",                    match: " rf "),
        Keyword(label: "Electrical",            match: "electrical"),
        Keyword(label: "Electronic",            match: "electronic"),
        Keyword(label: "Digital",               match: "digital"),
        Keyword(label: "Digital Engineer",      match: "digital engineer"),
        Keyword(label: "Design Engineer",       match: "design engineer"),
        Keyword(label: "UI",                    match: " ui "),
        Keyword(label: "UX",                    match: " ux "),
        Keyword(label: "User Experience",       match: "user experience"),
        Keyword(label: "User Interaction",      match: "user interaction"),
        Keyword(label: "iOS",                   match: " ios "),
        Keyword(label: "Android",               match: "android"),
        Keyword(label: "API",                   match: " api "),
        Keyword(label: "API Engineer",          match: "api engineer"),
        Keyword(label: "Workday Engineer",      match: "workday engineer"),
        Keyword(label: "Salesforce",            match: "salesforce"),
        Keyword(label: "Salesforce Engineer",   match: "salesforce engineer"),
        Keyword(label: "Salesforce Administrator", match: "salesforce administrator"),

        // Robotics
        Keyword(label: "Robotics",              match: "robotics"),
        Keyword(label: "Robot",                 match: "robot"),

        // Quant / trading / GTM
        Keyword(label: "Trader",                match: "trader"),
        Keyword(label: "Trading",               match: "trading"),
        Keyword(label: "Quant",                 match: "quant"),
        Keyword(label: "Go to Market",          match: "go to market"),

        // Languages — short tokens ("Go", "C") get space-padded so they
        // don't match inside "Google" / "Section C Manager".
        Keyword(label: "Python",                match: "python"),
        Keyword(label: "Java",                  match: "java"),
        Keyword(label: "Rust",                  match: "rust"),
        Keyword(label: "Go",                    match: " go "),
        Keyword(label: "C",                     match: " c "),
        Keyword(label: "C++",                   match: "c++"),
        Keyword(label: ".NET",                  match: ".net"),
        Keyword(label: "Angular",               match: "angular"),

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
    var keywords: Set<String> = []   // stores the `.match` values
    var posted: DateRange = .any
    var remote: RemoteFilter = .all
    var tier: TierFilter = .all

    var isEmpty: Bool {
        search.isEmpty && keywords.isEmpty && posted == .any && remote == .all && tier == .all
    }
}
