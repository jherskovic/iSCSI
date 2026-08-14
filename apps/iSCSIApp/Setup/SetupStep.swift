//
//  SetupStep.swift
//  The shape every setup step has to fit.
//
//  The rule this exists to enforce: **the UI renders the result of a check, and
//  never a static instruction.** A setup screen that lists "1. Approve the
//  daemon 2. Enable the extension" is wrong the moment any of it is already
//  done, and it cannot tell the user which half of a half-finished install
//  failed. Every step here answers "is this true right now?" and the screen is
//  a rendering of those answers.
//
//  The second rule: this runs on *every* launch, not just the first. That single
//  decision is what makes the post-update repair path fall out for free — a
//  Sparkle relaunch is just a launch, and a step that noticed its condition
//  stopped holding will offer to fix it without anything having to know that an
//  update happened.
//

import Foundation

enum StepState: Equatable {
    case checking
    /// True right now, with the evidence that says so.
    case satisfied(String)
    /// Not true, and there is something to do about it.
    case actionable(String)
    /// Not true, and pressing a button will not help. Says why.
    case blocked(String)

    var isSatisfied: Bool { if case .satisfied = self { return true }; return false }

    var detail: String {
        switch self {
        case .checking:            return "checking…"
        case .satisfied(let why):  return why
        case .actionable(let why): return why
        case .blocked(let why):    return why
        }
    }
}

/// One condition the product needs in order to work.
@MainActor
protocol SetupStep: AnyObject {
    /// Stable across launches; used as the SwiftUI identity.
    var id: String { get }
    var title: String { get }
    var state: StepState { get }

    /// Ask the system. Must be cheap enough to run on every launch and on every
    /// return to the foreground, and must never assume the result of a previous
    /// call — the whole point is to catch conditions that stopped holding.
    func check() async

    /// nil when the step has nothing the app can do — the user has to act
    /// somewhere else, or it is simply satisfied.
    var actionLabel: String? { get }
    func perform() async

    /// Non-nil when `perform()` changes something outside this app's own
    /// storage. The view puts it in a confirmation dialog and does not proceed
    /// without a yes.
    ///
    /// Exactly one step needs this today: the macOS 26.x enablement fallback
    /// writes to a file belonging to the OS. The System Settings switch it
    /// replaces is a *consent* gate, so bypassing it silently would be taking
    /// the consent rather than asking for it. Name the file and say what will
    /// happen.
    var consentPrompt: String? { get }
}

extension SetupStep {
    var actionLabel: String? { nil }
    var consentPrompt: String? { nil }
    func perform() async {}
}
