import SwiftUI

enum Destination: String, CaseIterable, Identifiable {
    case overview = "Overview", games = "Games", backups = "Backups", provider = "Cloud Provider", setup = "Setup", stats = "Stats & Scripts", migration = "Migration", manifest = "Manifest Pins", cloud = "Cloud Files"
    var id: String { rawValue }
    var symbol: String {
        switch self {
        case .overview: "square.grid.2x2"; case .games: "gamecontroller"; case .backups: "clock.arrow.circlepath"; case .provider: "cloud"; case .setup: "gearshape"; case .stats: "chart.bar"; case .migration: "arrow.left.arrow.right"; case .manifest: "pin"; case .cloud: "externaldrive"
        }
    }
    var section: String {
        switch self { case .overview, .games, .backups: "Library"; case .provider, .setup, .stats: "Sync"; case .migration, .manifest, .cloud: "Tools" }
    }
}
let sage = Color(red: 175/255, green: 191/255, blue: 164/255)
let sageIcon = Color(red: 0.40, green: 0.47, blue: 0.38)
let providers: [(String, String)] = [("local", "Local Storage"), ("folder", "Custom Folder"), ("gdrive", "Google Drive"), ("onedrive", "OneDrive"), ("r2", "Cloudflare R2"), ("s3", "S3 Compatible")]
func providerName(_ key: String) -> String { providers.first { $0.0 == key }?.1 ?? key }
func number(_ item: [String: Any], _ key: String) -> Int { (item[key] as? NSNumber)?.intValue ?? Int(item[key] as? String ?? "") ?? 0 }
func string(_ item: [String: Any], _ key: String) -> String { item[key] as? String ?? "" }
