import Foundation

struct ProjectFileActivity: Identifiable {
    var id: String { repository + "/" + path }
    let repository: String
    let path: String
    let lines: Int

    static func parse(_ output: String, repository: String) -> [ProjectFileActivity] {
        var totals: [String: Int] = [:]
        for line in output.split(separator: "\n") {
            let fields = line.split(separator: "\t", maxSplits: 2)
            guard fields.count == 3, let added = Int(fields[0]), let deleted = Int(fields[1]), added >= 0, deleted >= 0 else { continue }
            totals[String(fields[2]), default: 0] += added + deleted
        }
        return totals.filter { $0.value > 0 }.map { .init(repository: repository, path: $0.key, lines: $0.value) }
            .sorted { $0.lines == $1.lines ? $0.path < $1.path : $0.lines > $1.lines }
    }
}

// Called from the model's existing background refresh, never from SwiftUI rendering.
func collectProjectActivity(_ paths: [String]) -> (files: [ProjectFileActivity], failed: Int) {
    var files: [ProjectFileActivity] = []
    var failed = 0
    for path in paths {
        let result = run("/usr/bin/git", ["-c", "core.quotePath=false", "log", "--since=7 days ago", "--format=", "--numstat", "--no-renames", "--no-ext-diff", "--no-textconv", "HEAD", "--"], at: path)
        if result.status == 0 { files += ProjectFileActivity.parse(result.output, repository: path) }
        else { failed += 1 }
    }
    return (files.sorted { $0.lines == $1.lines ? $0.id < $1.id : $0.lines > $1.lines }, failed)
}
