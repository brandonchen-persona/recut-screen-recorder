import Foundation

/// A tiny assertion harness.
///
/// XCTest ships with Xcode, not with the Command Line Tools this project builds
/// against, so `swift test` can't link here. Rather than add a dependency, the
/// suites run from the app binary via `Recut --test`. The assertions map
/// one-to-one onto XCTest's, so moving to a real test target later is a rename.
final class TestRunner {

    private struct Failure {
        var suite: String
        var test: String
        var message: String
        var line: Int
    }

    private var failures: [Failure] = []
    private var assertions = 0
    private var testCount = 0
    private var currentSuite = "?"
    private var currentTest = "?"
    private var currentTestFailed = false

    /// ANSI colours, but only when stdout is a terminal.
    private let colour = isatty(fileno(stdout)) == 1
    private func green(_ s: String) -> String { colour ? "\u{1B}[32m\(s)\u{1B}[0m" : s }
    private func red(_ s: String) -> String { colour ? "\u{1B}[31m\(s)\u{1B}[0m" : s }
    private func dim(_ s: String) -> String { colour ? "\u{1B}[2m\(s)\u{1B}[0m" : s }

    func suite(_ name: String, _ body: () -> Void) {
        currentSuite = name
        print("\n\(name)")
        body()
    }

    func test(_ name: String, _ body: () -> Void) {
        currentTest = name
        currentTestFailed = false
        testCount += 1
        body()
        if currentTestFailed {
            print("  \(red("✗")) \(name)")
        } else {
            print("  \(green("✓")) \(dim(name))")
        }
    }

    // MARK: Assertions

    func expect(_ condition: Bool, _ message: @autoclosure () -> String, line: Int = #line) {
        assertions += 1
        guard !condition else { return }
        record(message(), line: line)
    }

    func equal<T: Equatable>(_ actual: T, _ expected: T, _ label: String, line: Int = #line) {
        assertions += 1
        guard actual != expected else { return }
        record("\(label): expected \(expected), got \(actual)", line: line)
    }

    /// Floating point comparison — exact equality on Doubles is a trap.
    func close(
        _ actual: Double, _ expected: Double, _ label: String,
        tolerance: Double = 1e-6, line: Int = #line
    ) {
        assertions += 1
        guard abs(actual - expected) > tolerance else { return }
        record(
            String(format: "%@: expected %.6f ± %.6f, got %.6f",
                   label, expected, tolerance, actual),
            line: line
        )
    }

    func greater(_ actual: Double, _ bound: Double, _ label: String, line: Int = #line) {
        assertions += 1
        guard actual <= bound else { return }
        record(String(format: "%@: expected > %.6f, got %.6f", label, bound, actual), line: line)
    }

    func less(_ actual: Double, _ bound: Double, _ label: String, line: Int = #line) {
        assertions += 1
        guard actual >= bound else { return }
        record(String(format: "%@: expected < %.6f, got %.6f", label, bound, actual), line: line)
    }

    private func record(_ message: String, line: Int) {
        currentTestFailed = true
        failures.append(
            Failure(suite: currentSuite, test: currentTest, message: message, line: line)
        )
    }

    // MARK: Result

    /// Prints the summary and returns the process exit code.
    func finish() -> Int32 {
        print("")
        if failures.isEmpty {
            print(green("All \(testCount) tests passed (\(assertions) assertions)."))
            return 0
        }
        print(red("\(failures.count) failure(s) across \(testCount) tests:"))
        for failure in failures {
            print("  \(red("✗")) \(failure.suite) › \(failure.test)")
            print("      \(failure.message)  \(dim("(TestSuites.swift:\(failure.line))"))")
        }
        return 1
    }
}
