//
//  Job.swift
//  jobs-ios
//
//  Mirrors the row shape of Supabase `public_jobs_feed`. Only columns the
//  app actually reads are decoded — keeps the feed payload small and
//  forward-compatible if the backend adds new columns.
//
//  Source of truth for the schema: backend's sql/supabase_schema.sql.
//
//  As of 2026-04-29, `last_seen` and `posted_at` were dropped from the
//  public mirror. The single timestamp surfaced is `effective_posted_at`,
//  computed at sync time as the parsed `posted_at` when valid, else
//  `first_seen`. The view returns `null` only for rows that somehow
//  lost both — defensive `Date?` here.
//

import Foundation

struct Job: Codable, Identifiable, Hashable {
    let canonicalKey: String
    let company: String
    let title: String
    let postingUrl: String
    let location: String
    /// True only when at least one fragment actually names a remote-work
    /// mode. Drives the green "Remote" pill in `FeedView`.
    let isRemote: Bool
    /// Backend-computed canonical age timestamp. Parsed `posted_at`
    /// when the board exposed a valid one, else `first_seen`. The
    /// frontend formats this with bucketed thresholds (`formatPostedAge`
    /// in `FeedView.swift`) — "posted Nh ago", "posted Nmo ago",
    /// "posted 1y+ ago", or "open since YYYY" for ancient zombie reqs.
    let effectivePostedAt: Date?
    /// SwiftUI `Identifiable` — `canonical_key` is already unique.
    var id: String { canonicalKey }

    var safePostingURL: URL? {
        guard
            let url = URL(string: postingUrl),
            let scheme = url.scheme?.lowercased(),
            ((scheme == "http" || scheme == "https") && url.host != nil)
                || (scheme == "mailto" && postingUrl.contains("@"))
        else {
            return nil
        }
        return url
    }

    enum CodingKeys: String, CodingKey {
        case canonicalKey = "canonical_key"
        case company, title, location
        case postingUrl = "posting_url"
        case isRemote = "is_remote"
        case effectivePostedAt = "effective_posted_at"
    }
}
