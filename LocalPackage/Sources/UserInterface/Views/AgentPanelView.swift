import Model
import SwiftUI

struct AgentPanelView: View {
    @ObservedObject var controller: AgentController
    @State private var isShowingKey = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 12) {
                Form {
                    Section("Gemini API Key") {
                        HStack {
                            if isShowingKey {
                                TextField("Enter API Key", text: $controller.apiKey)
                                    .textInputAutocapitalization(.never)
                                    .autocorrectionDisabled()
                            } else {
                                SecureField("Enter API Key", text: $controller.apiKey)
                                    .textInputAutocapitalization(.never)
                                    .autocorrectionDisabled()
                            }
                            Button(isShowingKey ? "Hide" : "Show") {
                                isShowingKey.toggle()
                            }
                        }
                        Text("The key is stored securely in Keychain and only used locally.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }

                    Section("Goal") {
                        TextField("Describe the goal for the agent", text: $controller.goal, axis: .vertical)
                            .lineLimit(1...3)
                    }

                    Section("Agent Controls") {
                        Toggle("Enable Agent Mode", isOn: $controller.isAgentModeEnabled)
                        Stepper(value: $controller.stepLimit, in: 1...50) {
                            Text("Auto run step limit: \(controller.stepLimit)")
                        }
                        HStack {
                            Button("Step Once") { controller.step() }
                                .buttonStyle(.borderedProminent)
                                .disabled(!controller.isAgentModeEnabled || controller.goal.isEmpty)
                            Button(controller.isRunning ? "Running..." : "Run") {
                                controller.runAutomatically()
                            }
                            .buttonStyle(.bordered)
                            .disabled(!controller.isAgentModeEnabled || controller.goal.isEmpty || controller.isRunning)
                            Button("Stop") { controller.stop() }
                                .tint(.red)
                                .buttonStyle(.bordered)
                        }
                        if controller.awaitingSafetyConfirmation {
                            Button("Continue after safety warning") {
                                controller.resumeAfterSafetyCheck()
                            }
                            .buttonStyle(.borderedProminent)
                            .tint(.orange)
                        }
                    }
                }

                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("Live Log")
                            .font(.headline)
                        Spacer()
                        if controller.isRunning {
                            ProgressView()
                        }
                    }
                    LogListView(entries: controller.logs)
                        .frame(maxWidth: .infinity)
                        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color(.separator)))
                        .padding(.bottom, 8)
                    if let last = controller.lastModelOutput, !last.isEmpty {
                        Text("Last model output: \n\(last)")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding(.horizontal)
            }
            .navigationTitle("Agent Mode")
        }
    }
}

private struct LogListView: View {
    let entries: [AgentLogEntry]

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 6) {
                    ForEach(entries) { entry in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(entry.date.formatted(date: .omitted, time: .standard))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Text("[\(entry.kind.rawValue.uppercased())] \(entry.message)")
                                .font(.callout)
                                .foregroundStyle(color(for: entry.kind))
                        }
                        .id(entry.id)
                        Divider()
                    }
                }
                .padding(8)
            }
            .onChange(of: entries.count) { _, _ in
                if let last = entries.last?.id {
                    withAnimation {
                        proxy.scrollTo(last, anchor: .bottom)
                    }
                }
            }
        }
    }

    private func color(for kind: AgentLogEntry.Kind) -> Color {
        switch kind {
        case .error: return .red
        case .warning: return .orange
        case .model: return .blue
        case .action: return .purple
        case .result: return .green
        case .info: return .primary
        }
    }
}
