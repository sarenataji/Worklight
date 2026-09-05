import Foundation

/// Exclusive categories keep every repository represented exactly once.
enum ProjectCategory: String, CaseIterable {
    case attention = "Needs attention"
    case working = "Work in progress"
    case current = "Up to date"
    case unverified = "Not verified"

    static func classify(_ repo: Repository) -> ProjectCategory {
        if repo.error != nil || repo.conflicts > 0 || repo.branch == "(detached)" { return .attention }
        if repo.upstream.isEmpty || repo.checked == nil { return .unverified }
        if repo.behind > 0 { return .attention }
        if repo.changed > 0 || repo.ahead > 0 { return .working }
        return .current
    }
}
