//
//  Job.swift
//  jobs-ios
//
//  Mirrors the row shape of Supabase `public.jobs`. Only columns the app
//  actually reads are decoded — keeps the feed payload small and forward-
//  compatible if the backend adds new columns.
//
//  Source of truth for the schema: backend's sql/supabase_schema.sql.
//

import Foundation

struct Job: Codable, Identifiable, Hashable {
    let canonicalKey: String
    let company: String
    let title: String
    let postingUrl: String
    let location: String
    let usOrRemoteEligible: Bool
    /// Narrower than `usOrRemoteEligible` — true only when at least one
    /// fragment actually names a remote-work mode. Drives the green
    /// "Remote" pill in `FeedView`.
    let isRemote: Bool
    let lastSeen: Date
    /// ISO-8601 UTC timestamp when the board first advertised the
    /// posting, or empty when the scraper couldn't capture one. The
    /// backend guarantees parseability when non-empty.
    let postedAt: String

    /// SwiftUI `Identifiable` — `canonical_key` is already unique.
    var id: String { canonicalKey }

    enum CodingKeys: String, CodingKey {
        case canonicalKey = "canonical_key"
        case company, title, location
        case postingUrl = "posting_url"
        case usOrRemoteEligible = "us_or_remote_eligible"
        case isRemote = "is_remote"
        case lastSeen = "last_seen"
        case postedAt = "posted_at"
    }
}
