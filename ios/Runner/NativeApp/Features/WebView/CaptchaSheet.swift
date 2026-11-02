//
//  CaptchaSheet.swift
//  Kazumi
//
//  验证面板 UI（对应 source_captcha_flow.dart 里的 _CaptchaDialog /
//  _AutomatedVerifyDialog / _VerificationCompleteDialog）。
//

import SwiftUI

struct CaptchaSheet: View {
    @Environment(\.colorScheme) private var colorScheme

    let flow: CaptchaFlow
    let onClose: () -> Void

    @State private var code = ""
    @State private var didStart = false
    @FocusState private var isCodeFocused: Bool

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 12) {
                    header
                    content
                }
                .padding(16)
                .frame(maxWidth: .infinity)
            }
            .frame(maxWidth: .infinity)
            .background(KazumiPalette.heroBackground(for: colorScheme).ignoresSafeArea())
            .navigationTitle(sheetTitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("取消") {
                        Task {
                            switch flow.phase {
                            case .completed, .failed, .cancelled: break
                            default: await flow.cancel()
                            }
                            onClose()
                        }
                    }
                }
            }
        }
        .task {
            guard !didStart else { return }
            didStart = true
            await flow.start()
        }
        .onDisappear { flow.dispose() }
        .task(id: flow.phase) {
            guard flow.phase == .completed else { return }
            do { try await Task.sleep(for: .seconds(3)) } catch { return }
            onClose()
        }
    }

    private var sheetTitle: String {
        switch flow.phase {
        case .completed: String(localized: "验证通过")
        case .cancelled: String(localized: "已取消验证")
        default: String(localized: "需要验证")
        }
    }

    private var header: some View {
        VStack(spacing: 8) {
            Image(systemName: "checkmark.shield")
                .font(.system(size: 34, weight: .semibold))
                .foregroundStyle(KazumiPalette.accent(for: colorScheme))
            Text(flow.plugin.name)
                .font(.headline)
            Text(headerDescription)
                .font(.footnote)
                .foregroundStyle(KazumiPalette.secondaryText(for: colorScheme))
                .multilineTextAlignment(.center)
        }
    }

    private var headerDescription: String {
        switch flow.phase {
        case .verifying: String(localized: "正在验证")
        case .completed: String(localized: "即将自动继续检索。")
        case .failed(let message): message
        case .cancelled: String(localized: "已取消验证")
        default: flow.requiresUserInput ? String(localized: "请输入页面上的验证码") : String(localized: "正在自动完成站点验证，请勿关闭…")
        }
    }

    @ViewBuilder
    private var content: some View {
        switch flow.phase {
        case .failed:
            Button("重试") {
                code = ""
                Task { await flow.reload() }
            }
            .buttonStyle(.borderedProminent)
        case .completed, .cancelled:
            EmptyView()
        default:
            if flow.requiresUserInput {
                Group {
                    if flow.phase == .verifying {
                        ProgressView("正在等待验证结果…")
                    } else if let image = flow.captchaImage, let uiImage = UIImage(data: image) {
                        Image(uiImage: uiImage)
                            .resizable()
                            .scaledToFit()
                            .frame(maxHeight: 100)
                            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                            .onTapGesture {
                                Task { await flow.reload() }
                            }
                    } else {
                        ProgressView("正在加载验证码…")
                    }
                }
                .frame(height: 100)
                TextField("验证码", text: $code)
                    .textFieldStyle(.roundedBorder)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.asciiCapable)
                    .multilineTextAlignment(.center)
                    .focused($isCodeFocused)
                    .disabled(flow.phase == .verifying)
                Button {
                    isCodeFocused = false
                    Task { await flow.submit(code) }
                } label: {
                    Text(flow.phase == .verifying ? "验证中…" : "提交")
                }
                .buttonStyle(.borderedProminent)
                .disabled(code.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || flow.phase == .verifying)
                Button("换一张") {
                    Task { await flow.reload() }
                }
                .font(.footnote)
                .disabled(flow.phase == .verifying)
            } else {
                ProgressView()
                    .padding(.vertical, 24)
            }
        }
    }
}
