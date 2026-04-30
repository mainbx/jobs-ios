# jobs-ios

iOS app for the job aggregator. Reads from a Supabase project that the
backend pipeline writes to. Shares no code with the web frontend —
SwiftUI and Next.js don't mix — but both read from identical
public Supabase views.

## Architecture

```
backend pipeline             Supabase                       jobs-ios
─────────────────            ──────────                     ────────
scrape + SQLite ──push──► public.jobs (RLS) ──view/anon──► SwiftUI app
                           public_scrape_health             (iOS 17+)
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
├── FeedView.swift          # Scrollable list + search field + filter bar
├── FeedViewModel.swift     # @Observable model, async load + filter state
├── Filters.swift           # Search tokenizer + feed filter state
├── Job.swift               # Codable row type mirroring public_jobs_feed
└── SupabaseClient.swift    # Singleton SupabaseClient wired from Info.plist
Info.plist                  # App metadata + Supabase build-setting bridge
Package.swift               # Typecheck-only SPM manifest (see below)
```

Schema types live in `Job.swift`. Keep them in sync with the
backend's `sql/supabase_schema.sql`. The search tokenizer in
`Filters.swift` mirrors the web frontend's `src/lib/filters.ts` —
keep the two implementations in sync by hand.

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

Five filters are surfaced at the top of the feed, plus a numbered
paginator at the bottom:

- **Search** (native SwiftUI `.searchable`) — Google-style free
  text, debounced 250 ms. The same grammar as the web feed (see
  [`Sources/Filters.swift`](Sources/Filters.swift) for the parser):

  | Syntax                        | Effect                                                        |
  |-------------------------------|---------------------------------------------------------------|
  | `staff engineer`              | each word must appear in title or company (AND'd)             |
  | `"staff software engineer"`   | quoted phrase preserved as one term                           |
  | `-intern` / `-"new grad"`     | exclude rows containing that term anywhere                    |
  | `title:engineer`              | constrain to the `title` column only                          |
  | `company:"morgan stanley"`    | constrain to the `company` column only                        |
  | `-title:vp`                   | combine: exclude on a specific column                         |

  When the search field is focused with no draft, a `.searchSuggestions`
  panel surfaces the operator vocabulary as discoverability.
  Whitespace, `,`, and `;` are interchangeable separators.
- **Posted-date menu** — Any time (default) / 24h / 7d / 30d. Filters
  on `effective_posted_at`, populated by the backend as board
  `posted_at` when available, else `first_seen`.
- **Remote menu** — All roles (default) / Remote only. Maps to the
  `is_remote` column. The feed is already US-scoped, so "Remote
  only" = US-workable remote.
- **State menu** — All states (default) / one US state, DC, or
  territory. Maps to the backend-populated `states` array and also
  matches rows tagged `*` for nationwide / unspecified-US postings.
- **Tier menu** — All tiers (default) / MAANG+ / Tier 1 / Tier 2 /
  Tier 3 / Startups. Maps to the `tier` column, populated at
  Supabase-sync time by the backend's tier classifier. Every
  configured company is classified.
- **Numbered paginator** (bottom of list) — renders `‹ Prev  1 … 5 6
  [7] 8 9 … 20  Next ›` with always-visible first/last, current
  highlighted, ±2 neighbors, ellipses for gaps. Status line above
  shows "Showing 101–200 of 5,432 · Page 2 of 55". Total counts come
  from Supabase's `count: .estimated` (read from the `Content-Range`
  response header), with a no-count retry if the counted query fails.
  Tapping any number jumps directly to that page.

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
Either the public views (`public_jobs_feed`, `public_scrape_health`) are
missing/stale (check Supabase SQL editor against the backend's schema),
or the publishable key is wrong (regenerate from Dashboard → Settings → API).

**App Transport Security error**
Supabase URLs are HTTPS-only — ATS is not the issue. Check that
`SUPABASE_URL` starts with `https://` and the project ref is right.
