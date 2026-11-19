//
//  SyncplayClient.swift
//  Kazumi
//
//  基于 Apple Network.framework 实现的 Syncplay 1.2.x 协议客户端。
//  负责与 Syncplay 服务器（如 publicserver.syncplay.pl 或自建服务）建立长连接，
//  处理 Hello 握手、Ping/Pong 时钟延迟测算、换行分隔 JSON 解析与事件分发。
//

import Foundation
import Network

struct SyncplayMember: Identifiable, Equatable, Sendable {
    var id: String { name }
    let name: String
    var room: String
    var fileName: String?
    var duration: Double?
    var isReady: Bool = true
}

struct SyncplayStateUpdate: Sendable {
    let position: Double
    let paused: Bool
    let doSeek: Bool
    let setBy: String?
    let latencyCalculation: Double?
}

enum SyncplayClientEvent: Sendable {
    case connected(server: String, user: String, room: String)
    case disconnected(reason: String)
    case playStateChanged(SyncplayStateUpdate)
    case userListUpdated([SyncplayMember])
    case userJoined(String)
    case userLeft(String)
    case chatReceived(user: String, message: String)
    case rttUpdated(Int)
}

final class SyncplayClient: @unchecked Sendable {
    private let host: String
    private let port: Int
    private let username: String
    private let room: String
    private let password: String?

    private var connection: NWConnection?
    private let queue = DispatchQueue(label: "com.kazumi.syncplay.client", qos: .userInitiated)
    private var isClosed = false
    private var incomingBuffer = Data()

    // Ping & RTT 状态
    private var clientRtt: Double = 0
    private var avgRtt: Double = 0
    private var lastLatencyCalculation: Double?
    private let pingWeight: Double = 0.85
    private var pingTimer: Task<Void, Never>?

    // 本地播放状态缓存
    private var localPosition: Double = 0
    private var localPaused: Bool = true
    private var clientIgnoringOnTheFly: Int = 0
    private var serverIgnoringOnTheFly: Int = 0

    // 已知成员
    private var members: [String: SyncplayMember] = [:]

    var onEvent: (@Sendable (SyncplayClientEvent) -> Void)?

    init(host: String, port: Int, username: String, room: String, password: String? = nil) {
        self.host = host
        self.port = port
        self.username = username
        self.room = room
        self.password = password
    }

    func connect() {
        queue.async { [weak self] in
            guard let self, !self.isClosed else { return }
            self.members = [:]
            self.members[self.username] = SyncplayMember(name: self.username, room: self.room)
            let endpoint = NWEndpoint.hostPort(
                host: NWEndpoint.Host(self.host),
                port: NWEndpoint.Port(rawValue: UInt16(self.port)) ?? 8999
            )
            let params = NWParameters.tcp
            params.allowFastOpen = true
            let conn = NWConnection(to: endpoint, using: params)
            self.connection = conn

            conn.stateUpdateHandler = { [weak self] state in
                guard let self else { return }
                switch state {
                case .ready:
                    self.sendHello()
                    self.startReading()
                    self.startPingLoop()
                    self.onEvent?(.userListUpdated(Array(self.members.values)))
                case .failed(let error):
                    self.disconnect(reason: String(localized: "连接失败：\(error.localizedDescription)"))
                case .cancelled:
                    break
                case .waiting(let error):
                    KazumiLog.player.warning("Syncplay waiting: \(error.localizedDescription)")
                default:
                    break
                }
            }
            conn.start(queue: self.queue)
        }
    }

    func disconnect(reason: String = String(localized: "已断开连接")) {
        queue.async { [weak self] in
            guard let self, !self.isClosed else { return }
            self.isClosed = true
            self.pingTimer?.cancel()
            self.pingTimer = nil
            self.connection?.cancel()
            self.connection = nil
            self.onEvent?(.disconnected(reason: reason))
        }
    }

    // MARK: - 发送命令

    func sendPlayState(position: Double, paused: Bool, doSeek: Bool = false) {
        queue.async { [weak self] in
            guard let self, !self.isClosed else { return }
            self.localPosition = position
            self.localPaused = paused
            self.clientIgnoringOnTheFly += 1

            let now = Date().timeIntervalSince1970
            var pingObj: [String: Any] = [
                "clientLatencyCalculation": now,
                "clientRtt": self.clientRtt
            ]
            if let last = self.lastLatencyCalculation {
                pingObj["latencyCalculation"] = last
            }

            var playstateObj: [String: Any] = [
                "position": position,
                "paused": paused,
                "setBy": self.username
            ]
            if doSeek {
                playstateObj["doSeek"] = true
            }

            var stateDict: [String: Any] = [
                "ping": pingObj,
                "playstate": playstateObj
            ]
            if self.clientIgnoringOnTheFly > 0 || self.serverIgnoringOnTheFly > 0 {
                var fly: [String: Any] = [:]
                if self.clientIgnoringOnTheFly > 0 { fly["client"] = self.clientIgnoringOnTheFly }
                if self.serverIgnoringOnTheFly > 0 { fly["server"] = self.serverIgnoringOnTheFly }
                stateDict["ignoringOnTheFly"] = fly
            }

            self.sendJSON(["State": stateDict])
        }
    }

    func sendFile(name: String, duration: Double, size: Int = 0) {
        queue.async { [weak self] in
            guard let self, !self.isClosed else { return }
            var me = self.members[self.username] ?? SyncplayMember(name: self.username, room: self.room)
            me.fileName = name
            me.duration = duration
            self.members[self.username] = me
            self.onEvent?(.userListUpdated(Array(self.members.values)))

            let fileDict: [String: Any] = [
                "name": name,
                "duration": duration,
                "size": size
            ]
            self.sendJSON(["Set": ["file": fileDict]])
        }
    }

    func sendChat(_ message: String) {
        queue.async { [weak self] in
            guard let self, !self.isClosed else { return }
            self.sendJSON(["Chat": message])
        }
    }

    // MARK: - 内部协议逻辑

    private func sendHello() {
        var helloDict: [String: Any] = [
            "username": username,
            "room": ["name": room],
            "version": "1.2.9",
            "realversion": "1.2.9",
            "features": [
              "sharedPlaylists": true,
              "chat": true,
              "featureList": true,
              "readiness": true,
              "managedRooms": false
            ]
        ]
        if let password, !password.isEmpty {
            helloDict["password"] = password
        }
        sendJSON(["Hello": helloDict])
    }

    private func sendJSON(_ obj: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: obj),
              var line = String(data: data, encoding: .utf8) else { return }
        line += "\r\n"
        if let lineData = line.data(using: .utf8) {
            connection?.send(content: lineData, completion: .contentProcessed { error in
                if let error {
                    KazumiLog.player.error("Syncplay send error: \(error.localizedDescription)")
                }
            })
        }
    }

    private func startReading() {
        connection?.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let data, !data.isEmpty {
                self.queue.async {
                    self.incomingBuffer.append(data)
                    self.processIncomingBuffer()
                }
            }
            if isComplete {
                self.disconnect(reason: String(localized: "服务器连接已关闭"))
            } else if let error {
                self.disconnect(reason: String(localized: "网络接收异常：\(error.localizedDescription)"))
            } else {
                self.startReading()
            }
        }
    }

    private func processIncomingBuffer() {
        let newline = UInt8(ascii: "\n")
        let carriage = UInt8(ascii: "\r")

        while let lineEndIndex = incomingBuffer.firstIndex(of: newline) {
            var lineData = incomingBuffer.subdata(in: 0..<lineEndIndex)
            incomingBuffer.removeSubrange(0...lineEndIndex)
            if lineData.last == carriage {
                lineData.removeLast()
            }
            guard !lineData.isEmpty else { continue }
            guard let json = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any] else {
                continue
            }
            handleMessage(json)
        }
    }

    private func handleMessage(_ json: [String: Any]) {
        if let hello = json["Hello"] as? [String: Any] {
            let user = (hello["username"] as? String) ?? username
            let roomName = ((hello["room"] as? [String: Any])?["name"] as? String) ?? room
            onEvent?(.connected(server: "\(host):\(port)", user: user, room: roomName))

            // 设置 Ready
            sendJSON(["Set": ["ready": ["isReady": true, "manuallyInitiated": false]]])
        }

        if let state = json["State"] as? [String: Any] {
            handleState(state)
        }

        if let set = json["Set"] as? [String: Any] {
            handleSet(set)
        }

        if let chat = json["Chat"] as? [String: Any] {
            if let user = chat["username"] as? String, let msg = chat["message"] as? String {
                onEvent?(.chatReceived(user: user, message: msg))
            }
        } else if let chatMsg = json["Chat"] as? String {
            onEvent?(.chatReceived(user: String(localized: "系统"), message: chatMsg))
        }

        if let error = json["Error"] as? [String: Any], let msg = error["message"] as? String {
            disconnect(reason: String(localized: "服务错误：\(msg)"))
        }
    }

    private func handleState(_ state: [String: Any]) {
        // Ping / Latency
        if let ping = state["ping"] as? [String: Any] {
            if let latencyCalc = ping["clientLatencyCalculation"] as? Double {
                let now = Date().timeIntervalSince1970
                let rtt = max(0, now - latencyCalc)
                clientRtt = rtt
                if avgRtt == 0 {
                    avgRtt = rtt
                } else {
                    avgRtt = avgRtt * pingWeight + rtt * (1.0 - pingWeight)
                }
                onEvent?(.rttUpdated(Int(avgRtt * 1000)))
            }
            if let serverLatency = ping["latencyCalculation"] as? Double {
                lastLatencyCalculation = serverLatency
            }
        }

        // IgnoringOnTheFly 避免本地操作回声
        if let ignoring = state["ignoringOnTheFly"] as? [String: Any] {
            if let serverAck = (ignoring["server"] as? NSNumber)?.intValue ?? (ignoring["server"] as? Int) {
                clientIgnoringOnTheFly = max(0, clientIgnoringOnTheFly - serverAck)
            }
            if let clientAck = (ignoring["client"] as? NSNumber)?.intValue ?? (ignoring["client"] as? Int) {
                serverIgnoringOnTheFly = clientAck
            }
        }

        if clientIgnoringOnTheFly > 0 {
            // 本地还有未被服务器确认的滑动/暂停操作，暂不被远端状态覆盖
            return
        }

        if let playstate = state["playstate"] as? [String: Any] {
            let position = (playstate["position"] as? Double) ?? 0
            let paused = (playstate["paused"] as? Bool) ?? true
            let doSeek = (playstate["doSeek"] as? Bool) ?? false
            let setBy = playstate["setBy"] as? String

            localPosition = position
            localPaused = paused

            onEvent?(.playStateChanged(SyncplayStateUpdate(
                position: position,
                paused: paused,
                doSeek: doSeek,
                setBy: setBy,
                latencyCalculation: lastLatencyCalculation
            )))
        }
    }

    private func handleSet(_ set: [String: Any]) {
        if let userDict = set["user"] as? [String: [String: Any]] {
            for (userName, userInfo) in userDict {
                var member = members[userName] ?? SyncplayMember(name: userName, room: room)
                if let roomObj = userInfo["room"] as? [String: Any], let roomName = roomObj["name"] as? String {
                    member.room = roomName
                }
                if let fileObj = userInfo["file"] as? [String: Any] {
                    member.fileName = fileObj["name"] as? String
                    member.duration = fileObj["duration"] as? Double
                }
                if let eventObj = userInfo["event"] as? [String: Any] {
                    if eventObj["joined"] as? Bool == true {
                        onEvent?(.userJoined(userName))
                    } else if eventObj["left"] as? Bool == true {
                        if userName != username {
                            members.removeValue(forKey: userName)
                        }
                        onEvent?(.userLeft(userName))
                        continue
                    }
                }
                members[userName] = member
            }
            if members[username] == nil {
                members[username] = SyncplayMember(name: username, room: room)
            }
            onEvent?(.userListUpdated(Array(members.values)))
        }
    }

    private func startPingLoop() {
        pingTimer?.cancel()
        pingTimer = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1.5))
                guard !Task.isCancelled, let self else { break }
                self.queue.async {
                    guard !self.isClosed else { return }
                    let now = Date().timeIntervalSince1970
                    var pingObj: [String: Any] = [
                        "clientLatencyCalculation": now,
                        "clientRtt": self.clientRtt
                    ]
                    if let last = self.lastLatencyCalculation {
                        pingObj["latencyCalculation"] = last
                    }
                    var stateDict: [String: Any] = ["ping": pingObj]
                    if self.clientIgnoringOnTheFly > 0 || self.serverIgnoringOnTheFly > 0 {
                        var fly: [String: Any] = [:]
                        if self.clientIgnoringOnTheFly > 0 { fly["client"] = self.clientIgnoringOnTheFly }
                        if self.serverIgnoringOnTheFly > 0 { fly["server"] = self.serverIgnoringOnTheFly }
                        stateDict["ignoringOnTheFly"] = fly
                    }
                    self.sendJSON(["State": stateDict])
                }
            }
        }
    }
}
