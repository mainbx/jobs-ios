//
//  SupabaseClient.swift
//  jobs-ios
//
//  Wraps the Supabase Swift SDK with our project-specific URL + publishable key.
//  Values are loaded from `Info.plist` so the real secrets never end up in git.
//
//  See Config.xcconfig.example for the build-settings format.
//

import Foundation
import Supabase

/// Singleton client. The publishable key is public-by-design (it ships in the
/// iOS binary); RLS policies on the Supabase side control what this caller
/// can read. The secret/service-role key is **never** used on the device.
enum SupabaseAPI {
    static let client: SupabaseClient = {
        guard
            let urlString = Bundle.main.object(forInfoDictionaryKey: "SUPABASE_URL") as? String,
            let key = Bundle.main.object(forInfoDictionaryKey: "SUPABASE_ANON_KEY") as? String,
            let url = URL(string: urlString),
            !key.isEmpty
        else {
            fatalError(
                "SUPABASE_URL / SUPABASE_ANON_KEY missing from Info.plist. " +
                "Set them via Config.xcconfig — see README.md."
            )
        }
        return SupabaseClient(supabaseURL: url, supabaseKey: key)
    }()
}
