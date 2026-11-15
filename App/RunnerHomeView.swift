import AssistantCore
import SwiftUI

@MainActor
final class RunnerHomeModel: ObservableObject {
    @Published private(set) var automaticRepliesPaused = false
    @Published private(set) var statusMessage = "运行器已加载"

    private let takeover = ManualTakeoverCenter()

    func setPaused(_ paused: Bool) {
        Task {
            do {
                if paused {
                    try await takeover.pauseAllAutomaticReplies()
                } else {
                    try await takeover.resumeAutomaticReplies()
                }
                automaticRepliesPaused = await takeover.isAutomationPaused
                statusMessage = paused ? "全部自动回复已暂停" : "自动回复已允许"
            } catch {
                statusMessage = "状态更新失败，请重试"
            }
        }
    }
}

struct RunnerHomeView: View {
    @StateObject private var model = RunnerHomeModel()

    var body: some View {
        NavigationStack {
            VStack(spacing: 24) {
                Image(systemName: model.automaticRepliesPaused
                    ? "pause.circle.fill"
                    : "checkmark.shield.fill")
                    .font(.system(size: 72))
                    .foregroundStyle(
                        model.automaticRepliesPaused
                            ? Color.orange
                            : Color.green
                    )

                Text("iPhone 客服助手")
                    .font(.title.bold())

                Text(model.statusMessage)
                    .foregroundStyle(.secondary)

                Button {
                    model.setPaused(!model.automaticRepliesPaused)
                } label: {
                    Label(
                        model.automaticRepliesPaused ? "恢复自动回复" : "暂停全部自动回复",
                        systemImage: model.automaticRepliesPaused
                            ? "play.fill"
                            : "pause.fill"
                    )
                    .frame(maxWidth: .infinity)
                    .padding()
                }
                .buttonStyle(.borderedProminent)
                .tint(model.automaticRepliesPaused ? .green : .orange)

                VStack(alignment: .leading, spacing: 8) {
                    Label("本地队列已集成", systemImage: "internaldrive")
                    Label("高风险任务默认转人工", systemImage: "person.crop.circle.badge.exclamationmark")
                    Label("发送状态不确定时禁止重发", systemImage: "exclamationmark.shield")
                }
                .font(.footnote)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)

                Spacer()

                Text("此版本仅用于安装与本地能力验证。平台自动化和持续后台运行尚未启用。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .padding(24)
            .navigationTitle("客服助手")
        }
    }
}
