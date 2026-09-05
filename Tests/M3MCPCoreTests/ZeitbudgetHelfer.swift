import Foundation

/// Zeitschranken in Tests, die unter einem Sanitizer nicht zum Zufallsgenerator werden.
///
/// ThreadSanitizer verlangsamt die Ausfuehrung um ein Vielfaches. Eine Schranke, die ohne
/// Sanitizer aussagekraeftig ist, wird darunter zur Wette auf die Auslastung des Runners.
/// Gemessen am 5. September 2026: derselbe Commit lieferte auf demselben Runner einen gruenen
/// und einen roten Lauf, waehrend der betroffene Test lokal zehnmal hintereinander bestand.
///
/// `M3MCP_TIMING_SLACK` traegt den Faktor, um den eine Schranke gedehnt wird. Die CI setzt ihn
/// im Sanitizer-Schritt. Ohne die Variable bleibt die Schranke unveraendert, der Test misst
/// also im Normalfall genau das, was er vorher gemessen hat.
func zeitbudget(_ sekunden: Double) -> Double {
    guard let roh = ProcessInfo.processInfo.environment["M3MCP_TIMING_SLACK"],
          let faktor = Double(roh), faktor > 0 else {
        return sekunden
    }
    return sekunden * faktor
}
