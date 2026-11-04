//
//  PlaybackLifecycleDiagnostics.swift
//  Kazumi
//
//  Read-only lifecycle observations. Activation does not identify its trigger,
//  and a scene connection does not establish that the process was restarted.
//

import UIKit

@MainActor
enum PlaybackLifecycleDiagnostics {
    /// One identity per process; scene aliases remain stable across reconnects in this run.
    static let runID = String(UUID().uuidString.prefix(8)).lowercased()
    private static var sceneIDs: [String: String] = [:]

    static func processBoot() {
        var details = "callback=application.didFinishLaunchingWithOptions version=\(KazumiAppInfo.fullVersion)"
        if let stamp = Bundle.main.object(forInfoDictionaryKey: "KazumiBuildStamp") as? String,
           !stamp.isEmpty {
            details += " buildStamp=\(stamp)"
        }
        log("process.boot", details: details)
    }

    static func log(_ event: String, scene: UIScene? = nil, details: String = "") {
        let context: String
        if let scene {
            context = describe(scene)
        } else {
            // Report all connected scenes rather than guessing which one owns a view.
            let scenes = UIApplication.shared.connectedScenes
                .sorted { $0.session.persistentIdentifier < $1.session.persistentIdentifier }
                .map { describe($0) }
            context = "connectedScenes=[\(scenes.joined(separator: "; "))]"
        }
        let suffix = details.isEmpty ? "" : " \(details)"
        KazumiLogBuffer.player("[Lifecycle run=\(runID)] \(event) \(context)\(suffix)")
    }

    private static func describe(_ scene: UIScene) -> String {
        let session = scene.session.persistentIdentifier
        let alias: String
        if let existing = sceneIDs[session] {
            alias = existing
        } else {
            alias = "s\(sceneIDs.count + 1)"
            sceneIDs[session] = alias
        }
        return "scene=\(alias) activation=\(activationName(scene.activationState))"
    }

    private static func activationName(_ state: UIScene.ActivationState) -> String {
        switch state {
        case .unattached: "unattached"
        case .foregroundActive: "foregroundActive"
        case .foregroundInactive: "foregroundInactive"
        case .background: "background"
        @unknown default: "unknown(\(state.rawValue))"
        }
    }
}
