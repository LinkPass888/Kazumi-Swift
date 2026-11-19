//
//  SyncplayManager.swift
//  Kazumi
//
//  主线程同播管理器，贯通 UI（SyncPlaySheet）、播放器（PlayerSurfaceModel）
//  与后台协议客户端（SyncplayClient），避免回声震荡，提供平滑同播同步。
//

import Foundation
import Observation

@MainActor
@Observable
final class SyncplayManager {
    static let shared = SyncplayManager()

    var isConnected: Bool = false
    var isConnecting: Bool = false
    var currentServer: String = ""
    var currentRoom: String = ""
    var currentUser: String = ""
    var members: [SyncplayMember] = []
    var rttMs: Int = 0
    var errorMessage: String?
    var lastToast: String?

    /// 标记当前是否正在将远端指令应用到本地播放器，防止将远端触发的暂停/跳转再次作为本地操作回传导致死循环震荡。
    private(set) var isApplyingRemoteUpdate: Bool = false

    private var client: SyncplayClient?

    // 播放器联动回调
    var onRemotePlay: ((_ user: String, _ position: Double) -> Void)?
    var onRemotePause: ((_ user: String, _ position: Double) -> Void)?
    var onRemoteSeek: ((_ user: String, _ position: Double) -> Void)?

    private init() {}

    func connect(
        endpoint: String,
        room: String,
        username: String,
        password: String? = nil
    ) {
        disconnect()

        let trimmedEndpoint = endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedRoom = room.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedUser = username.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !trimmedEndpoint.isEmpty else {
            errorMessage = String(localized: "请输入服务器地址")
            return
        }
        guard !trimmedRoom.isEmpty else {
            errorMessage = String(localized: "请输入房间名")
            return
        }
        let user = trimmedUser.isEmpty ? String(localized: "Kazumi用户") : trimmedUser

        // 解析 host 和 port
        let host: String
        let port: Int
        var raw = trimmedEndpoint
        if raw.contains("://") {
            if let u = URL(string: raw), let h = u.host {
                host = h
                port = u.port ?? 8999
            } else {
                errorMessage = String(localized: "服务器地址格式不正确")
                return
            }
        } else {
            let parts = raw.split(separator: ":")
            if parts.count == 2, let p = Int(parts[1]) {
                host = String(parts[0])
                port = p
            } else if parts.count == 1 {
                host = String(parts[0])
                port = 8999
            } else {
                errorMessage = String(localized: "服务器地址格式不正确")
                return
            }
        }

        isConnecting = true
        errorMessage = nil
        currentServer = "\(host):\(port)"
        currentRoom = trimmedRoom
        currentUser = user

        let newClient = SyncplayClient(
            host: host,
            port: port,
            username: user,
            room: trimmedRoom,
            password: password?.isEmpty == false ? password : nil
        )

        newClient.onEvent = { [weak self] event in
            Task { @MainActor [weak self] in
                self?.handleClientEvent(event)
            }
        }

        client = newClient
        newClient.connect()
    }

    func disconnect(reason: String? = nil) {
        client?.disconnect(reason: reason ?? String(localized: "已退出房间"))
        client = nil
        isConnected = false
        isConnecting = false
        members = []
        rttMs = 0
    }

    // MARK: - 本地操作广播

    func onLocalPlay(position: Double) {
        guard isConnected, !isApplyingRemoteUpdate else { return }
        client?.sendPlayState(position: position, paused: false)
    }

    func onLocalPause(position: Double) {
        guard isConnected, !isApplyingRemoteUpdate else { return }
        client?.sendPlayState(position: position, paused: true)
    }

    func onLocalSeek(to position: Double, paused: Bool) {
        guard isConnected, !isApplyingRemoteUpdate else { return }
        client?.sendPlayState(position: position, paused: paused, doSeek: true)
    }

    func onLocalEpisode(title: String, duration: Double) {
        guard isConnected else { return }
        client?.sendFile(name: title, duration: duration)
    }

    func sendChatMessage(_ message: String) {
        guard isConnected else { return }
        client?.sendChat(message)
    }

    // MARK: - 处理协议事件

    private func handleClientEvent(_ event: SyncplayClientEvent) {
        switch event {
        case .connected(let server, let user, let room):
            isConnected = true
            isConnecting = false
            currentServer = server
            currentUser = user
            currentRoom = room
            errorMessage = nil
            lastToast = String(localized: "已连接到「\(room)」")

        case .disconnected(let reason):
            isConnected = false
            isConnecting = false
            members = []
            rttMs = 0
            if !reason.isEmpty {
                errorMessage = reason
                lastToast = reason
            }

        case .playStateChanged(let update):
            let actorName = update.setBy ?? String(localized: "对方")
            isApplyingRemoteUpdate = true
            defer { isApplyingRemoteUpdate = false }

            if update.paused {
                onRemotePause?(actorName, update.position)
            } else {
                onRemotePlay?(actorName, update.position)
            }

            if update.doSeek {
                onRemoteSeek?(actorName, update.position)
            }

        case .userListUpdated(let list):
            self.members = list

        case .userJoined(let user):
            lastToast = String(localized: "「\(user)」加入了房间")

        case .userLeft(let user):
            lastToast = String(localized: "「\(user)」离开了房间")

        case .chatReceived(let user, let msg):
            lastToast = "\(user): \(msg)"

        case .rttUpdated(let ms):
            self.rttMs = ms
        }
    }
}
