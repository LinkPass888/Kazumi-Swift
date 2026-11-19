//
//  SyncPlaySheet.swift
//  Kazumi
//
//  一起看（Syncplay）房间配置与成员面板。
//  自动记住上次连接的服务器地址、房间名与昵称，并纳入设置备份。
//

import SwiftUI

struct SyncPlaySheet: View {
    @Bindable var settings: SettingsStore
    @Binding var isPresented: Bool
    @Bindable var surface: PlayerSurfaceModel

    @State private var syncplay = SyncplayManager.shared
    @Environment(\.colorScheme) private var colorScheme

    private let publicServers = [
        "publicserver.syncplay.pl:8999",
        "syncplay.pl:8999"
    ]

    var body: some View {
        NavigationStack {
            Group {
                if syncplay.isConnected {
                    connectedView
                } else {
                    connectForm
                }
            }
            .navigationTitle(syncplay.isConnected ? "房间 · \(syncplay.currentRoom)" : "一起看")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("关闭") {
                        isPresented = false
                    }
                }
            }
        }
        .frame(maxWidth: 600)
        .frame(maxWidth: .infinity)
        .presentationDetents([.medium, .large])
    }

    // MARK: - 未连接表单

    private var connectForm: some View {
        Form {
            Section {
                TextField("服务器地址（如 publicserver.syncplay.pl:8999）", text: $settings.syncPlayEndPoint)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)

                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        Text("公共服务：")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        ForEach(publicServers, id: \.self) { srv in
                            Button(srv) {
                                settings.syncPlayEndPoint = srv
                            }
                            .font(.caption2.weight(.medium))
                            .buttonStyle(.bordered)
                            .buttonBorderShape(.capsule)
                        }
                    }
                    .padding(.vertical, 2)
                }
            } header: {
                Text("服务器")
            } footer: {
                Text("支持标准 Syncplay 协议服务端。可使用官方免注册公共服务器或自建节点。")
            }

            Section {
                TextField("我的昵称", text: $settings.syncPlayUsername)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()

                TextField("房间名", text: $settings.syncPlayRoom)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()

                SecureField("房间口令（可选）", text: $settings.syncPlayPassword)
            } header: {
                Text("房间信息")
            } footer: {
                Text("与好友输入完全相同的房间名与口令即可加入同一房间，播放与拖拽自动同步。")
            }

            if let error = syncplay.errorMessage {
                Section {
                    Text(error)
                        .font(.footnote)
                        .foregroundStyle(.red)
                }
            }

            Section {
                Button {
                    connect()
                } label: {
                    HStack {
                        Spacer()
                        if syncplay.isConnecting {
                            ProgressView()
                                .padding(.trailing, 6)
                            Text("正在连接…")
                        } else {
                            Image(systemName: "person.2.fill")
                                .padding(.trailing, 2)
                            Text("加入一起看房间")
                                .fontWeight(.semibold)
                        }
                        Spacer()
                    }
                }
                .disabled(
                    syncplay.isConnecting ||
                    settings.syncPlayEndPoint.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
                    settings.syncPlayRoom.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                )
            }
        }
    }

    // MARK: - 已连接面板

    private var connectedView: some View {
        Form {
            Section {
                HStack(spacing: 12) {
                    Circle()
                        .fill(Color.green)
                        .frame(width: 10, height: 10)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(syncplay.currentRoom)
                            .font(.headline)
                        Text(syncplay.currentServer)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    HStack(spacing: 4) {
                        Image(systemName: "antenna.radiowaves.left.and.right")
                        Text("\(syncplay.rttMs) ms")
                    }
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Capsule().fill(Color.secondary.opacity(0.12)))
                }
                .padding(.vertical, 4)
            } header: {
                Text("当前连接状态")
            }

            Section {
                if syncplay.members.isEmpty {
                    Text("房间内仅你一人")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(syncplay.members) { member in
                        HStack(spacing: 10) {
                            Image(systemName: member.name == syncplay.currentUser ? "person.crop.circle.fill" : "person.crop.circle")
                                .foregroundStyle(member.name == syncplay.currentUser ? KazumiPalette.accent(for: colorScheme) : Color.secondary)
                                .font(.title3)

                            VStack(alignment: .leading, spacing: 2) {
                                HStack {
                                    Text(member.name)
                                        .font(.subheadline.weight(.semibold))
                                    if member.name == syncplay.currentUser {
                                        Text("（我）")
                                            .font(.caption2)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                                if let file = member.fileName, !file.isEmpty {
                                    Text(file)
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                }
                            }
                            Spacer()
                        }
                        .padding(.vertical, 2)
                    }
                }
            } header: {
                Text("房间成员（\(max(1, syncplay.members.count)) 人）")
            }

            Section {
                Button(role: .destructive) {
                    syncplay.disconnect()
                } label: {
                    HStack {
                        Spacer()
                        Image(systemName: "rectangle.portrait.and.arrow.right")
                        Text("离开房间")
                        Spacer()
                    }
                }
            }
        }
    }

    private func connect() {
        let defaultUser = settings.bangumiUsername.isEmpty ? String(localized: "Kazumi 用户") : settings.bangumiUsername
        let username = settings.syncPlayUsername.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? defaultUser
            : settings.syncPlayUsername

        if settings.syncPlayUsername.isEmpty {
            settings.syncPlayUsername = username
        }

        syncplay.connect(
            endpoint: settings.syncPlayEndPoint,
            room: settings.syncPlayRoom,
            username: username,
            password: settings.syncPlayPassword
        )
    }
}
