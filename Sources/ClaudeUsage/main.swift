import Foundation

// `--report` prints usage to stdout instead of launching the menu bar item.
if CommandLine.arguments.contains("--report") {
    Report.run()
    exit(0)
}

ClaudeUsageApp.main()
