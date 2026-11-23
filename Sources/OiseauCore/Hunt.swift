import Foundation

// The find / report flows' client rules (Android: domain/Hunt.kt; web: FindSheet.tsx,
// ReportSheet.tsx). The server decides — proximity is checked there, in SQL — so
// these only word its answers.

/// web: `Position acquise (±N m)` / `Acquisition de la position…`.
public func positionStatus(_ p: Position?) -> UiText {
    guard let p else { return .of("hunt_locating") }
    return .of("hunt_located", String(Int(p.accuracyM.rounded())))
}

/// What the find sheet says when the server refuses: the codes a player hits are
/// worded by the app, anything else is the server's message.
public func findErrorMessage(_ e: ApiError) -> UiText {
    // Only when the find couldn't be parked either (storage refused it).
    if e.isUnavailable { return .of("find_error_network") }
    switch e.code {
    case "too_far": return .of("find_error_too_far")
    case "already_found": return .of("find_error_already")
    case "archived": return .of("find_error_archived")
    default: return .raw(e.message ?? e.code)
    }
}

/// What the report sheet says when the server refuses (web: ReportSheet#submit).
public func reportErrorMessage(_ e: ApiError) -> UiText {
    if e.isUnavailable { return e.toUiText() }
    switch e.code {
    case "too_far": return .of("report_error_too_far")
    case "already_reported": return .of("report_error_already")
    case "cannot_report_own": return .of("report_error_own")
    case "archived": return .of("report_error_archived")
    default: return .raw(e.message ?? e.code)
    }
}

/// The web's note limit (and the server's: `note` max 1000).
public let reportNoteMax = 1000
