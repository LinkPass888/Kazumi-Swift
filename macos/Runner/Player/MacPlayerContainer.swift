//
//  MacPlayerContainer.swift
//  Kazumi (macOS)
//
//  把共享的 `MPVMetalView`（NSView 版）塞进 SwiftUI，并在挂上窗口时把内核建起来。
//

import AppKit
import SwiftUI

struct MacPlayerContainer: NSViewRepresentable {
    let model: MacPlayerModel

    func makeCoordinator() -> Coordinator {
        Coordinator(model: model)
    }

    func makeNSView(context: Context) -> MPVMetalView {
        let view = MPVMetalView(frame: .zero)
        model.attachMetalView(view)
        return view
    }

    func updateNSView(_ nsView: MPVMetalView, context: Context) {
        // 幂等：已经起过的引擎这里只把 surface 重新挂一次。
        model.attachMetalView(nsView)
    }

    static func dismantleNSView(_ nsView: MPVMetalView, coordinator: Coordinator) {
        // 画面没了就把内核收掉：mpv 的 vo 线程握着这块 layer。
        coordinator.model.stop()
    }

    @MainActor
    final class Coordinator {
        let model: MacPlayerModel

        init(model: MacPlayerModel) {
            self.model = model
        }
    }
}