# jobs-ios

iOS app for the job aggregator. Reads from a Supabase project that the
backend pipeline writes to. Shares no code with the web frontend —
SwiftUI and Next.js don't mix — but both read from identical
RLS-scoped tables.

## Architecture

```
backend pipeline             Supabase                       jobs-ios
─────────────────            ──────────                     ────────
scrape + SQLite ──push──► public.jobs (RLS) ──anon key──► SwiftUI app
                           public.scrape_runs_latest        (iOS 17+)
```

The backend scraper + sync pipeline live in a separate private
repository.

## Stack

| | |
|---|---|
| Language | Swift 5.10+ |
| UI | SwiftUI (native) |
| State | `@Observable` (iOS 17+) |
| Data | [`supabase-swift`](https://github.com/supabase/supabase-swift) via SPM |
| Min target | **iOS 17** |
| IDE | Xcode 15+ |

No CocoaPods. No CLI tool installs — dependencies come via Swift
Package Manager inside Xcode.

## First-time setup

The `.xcodeproj`, `Info.plist`, and sources are all checked in. After
cloning you only need to plug in your own Supabase publishable key:

1. **Open `jobs-ios.xcodeproj` in Xcode 15+.** Xcode resolves the
   `supabase-swift` SPM dependency automatically on first open.

2. **Configure credentials via `Config.xcconfig`.**
   - Copy `Config.xcconfig.example` → `Config.xcconfig` and fill in the
     publishable key from Supabase Dashboard → Settings → API.
   - Keep the URL spelling as `https:/$()/...` in `Config.xcconfig`;
     Xcode expands it to `https://...`. A literal `https://` is parsed
     as an `.xcconfig` comment and truncates the value.
   - `Config.xcconfig` is `.gitignore`d — only the `.example` is tracked.

3. **Run.** Select an iPhone simulator (iPhone 15 is fine) and hit
   ⌘R. You should see a list of the 100 most-recently-seen relevant
   jobs from Supabase, pulled via RLS-scoped anon access.

The project wiring — `Config.xcconfig` bound to both Debug/Release,
`Info.plist` mapping `SUPABASE_URL` / `SUPABASE_ANON_KEY` from build
settings, and the `Supabase` SPM product linked to the target — is
already in the checked-in `jobs-ios.xcodeproj/project.pbxproj`.

## Source layout

```
Sources/
├── JobsApp.swift           # SwiftUI @main entry point
├── FeedView.swift          # Scrollable list + search + chip row + date menu
├── FeedViewModel.swift     # @Observable model, async load + filter state
├── Filters.swift           # Keyword catalog + DateRange enum + FilterState
├── Job.swift               # Codable row type mirroring public.jobs
└── SupabaseClient.swift    # Singleton SupabaseClient wired from Info.plist
Info.plist                  # App metadata + Supabase build-setting bridge
Package.swift               # Typecheck-only SPM manifest (see below)
```

Schema types live in `Job.swift`. Keep them in sync with the
backend's `sql/supabase_schema.sql`. The keyword catalog in
`Filters.swift` mirrors the web frontend's `src/lib/filters.ts` —
keep the two lists in sync by hand.

### `Package.swift` is for type-checking only

The `Package.swift` at the repo root exists so you can run
`swift build` to catch type errors without opening Xcode. It declares
the sources as a **library** target (not an app) and excludes
`JobsApp.swift` because `@main struct App` only compiles inside a
real iOS app target.

```bash
# Quick type-check pass (no simulator required):
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift build
```

The real iOS build still happens through the checked-in
`jobs-ios.xcodeproj`. Don't delete `Package.swift` — it's useful in CI
too.

## Scope: US / US-remote only

The feed only surfaces postings where `us_or_remote_eligible = true`.
Classifier rule: "keep any posting whose location fragments resolve
to a US address, or is remote-worldwide." The Supabase mirror is
US/remote-eligible and relevant-only by construction — the backend
uploads only `active=1 AND us_or_remote_eligible=1 AND relevant=1`
rows; the iOS query also includes
`.eq("us_or_remote_eligible", value: true)` as a belt-and-braces guard.

## Filter UI

Four filters are surfaced at the top of the feed, plus a numbered
paginator at the bottom:

- **Search** (native SwiftUI `.searchable`) — matches title OR company
  (ILIKE substring), debounced 250 ms so typing doesn't hammer Supabase.
- **Keyword chips** — horizontal scrollable row of pre-defined labels
  (Software, Backend, Robotics, Fall 2026, …). Tap to toggle. Multiple
  selected chips combine with OR logic on the title.
- **Posted-date menu** — Any time (default) / 24h / 7d / 30d. Filters
  on `effective_posted_at`, populated by the backend as board
  `posted_at` when available, else `first_seen`.
- **Remote menu** — All roles (default) / Remote only. Maps to the
  `is_remote` column. The feed is already US-scoped, so "Remote
  only" = US-workable remote.
- **Tier menu** — All tiers (default) / FAANG+ / Tier 1 / Tier 2 /
  Tier 3. Maps to the `tier` column, populated at Supabase-sync
  time by the backend's tier classifier. Every configured company is
  classified (10 FAANG+ / 53 Tier 1 / 155 Tier 2 / 204 Tier 3 / 11
  Startups as of 2026-04-23).
- **Numbered paginator** (bottom of list) — renders `‹ Prev  1 … 5 6
  [7] 8 9 … 20  Next ›` with always-visible first/last, current
  highlighted, ±2 neighbors, ellipses for gaps. Status line above
  shows "Showing 101–200 of 5,432 · Page 2 of 55". Total counts come
  from Supabase's `count: .exact` (read from the `Content-Range`
  response header). Tapping any number jumps directly to that page.

State lives in `FilterState` inside `FeedView`; current page lives in
`FeedViewModel` (not a URL-backed state since iOS has no URL). The
VM's `load(filters:)` debounces + cancels in-flight requests so rapid
toggles don't race. Changing any filter resets pagination to page 1.

## What's intentionally NOT built yet (phase 2)

- Supabase Auth (Sign in with Apple + magic link) — needed before the tracker.
- Compatibility score + "why this role" summary per job.
- Per-user "applied / saved / rejected" tracker (new `job_status` table).
- Company detail screen.
- Offline cache via SwiftData.

v1 = public read-only feed of relevant open roles.

## Troubleshooting

**`fatalError: SUPABASE_URL / SUPABASE_ANON_KEY missing`**
Config.xcconfig isn't being picked up by the build. Check:
- Project → Configurations → both Debug/Release → `Config.xcconfig`.
- `Info.plist` contains the two keys bound to `$(SUPABASE_URL)` /
  `$(SUPABASE_ANON_KEY)`. Both the `.xcconfig` binding and the
  `Info.plist` entries should already be set via the checked-in
  `jobs-ios.xcodeproj/project.pbxproj` — if they're missing, your
  local project drifted; re-check out from `main`.

**App launches but shows "Couldn't load jobs"**
Either the RLS policy `jobs_public_read` is missing (check Supabase
SQL editor against the backend's schema), or the publishable key is
wrong (regenerate from Dashboard → Settings → API).

**App Transport Security error**
Supabase URLs are HTTPS-only — ATS is not the issue. Check that
`SUPABASE_URL` starts with `https://` and the project ref is right.
