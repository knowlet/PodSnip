import SwiftUI

struct SettingsView: View {
    @State private var config = AIConfig.load()
    @State private var testResult: String?
    @State private var testing = false
    @State private var showKey = false
    @State private var availText = ""
    @State private var availOK = false

    var routeBinding: Binding<AIRoute> {
        Binding(get: { config.route }, set: { config.routeRaw = $0.rawValue; config.save(); refreshAvail() })
    }
    func refreshAvail() {
        let c = AppleBrain.check(config.route)
        availOK = c.ok; availText = c.reason
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("AI 來源") {
                    Picker("路由", selection: routeBinding) {
                        ForEach(AIRoute.allCases) { r in
                            Text(r.title).tag(r)
                        }
                    }
                    Text(config.route.subtitle).font(.caption).foregroundStyle(.secondary)
                    HStack {
                        Text(availText).font(.caption).foregroundStyle(availOK ? .green : .orange)
                        Spacer()
                        Button("檢查") { refreshAvail() }.font(.caption)
                    }
                }
                Section("自帶 AI（OpenAI 相容）") {
                    TextField("Base URL", text: $config.baseURL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .font(.caption)
                    if showKey {
                        TextField("API Key", text: $config.apiKey)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .font(.caption)
                    } else {
                        SecureField("API Key（存 Keychain）", text: $config.apiKey)
                            .font(.caption)
                    }
                    Toggle("顯示 Key", isOn: $showKey)
                    TextField("模型", text: $config.model)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    Button("儲存") { config.save(); testResult = "已儲存 ✓" }
                    Button(testing ? "測試中…" : "測試連線") {
                        Task {
                            testing = true; testResult = nil
                            config.save()
                            do {
                                let r: String
                                if config.route == .byok {
                                    r = try await AIClient(config: config).testConnection()
                                } else {
                                    r = try await AppleBrain(route: config.route).chat(system: "只回 OK", user: "hi")
                                }
                                testResult = "連線成功：\(r.prefix(60))"
                            } catch {
                                testResult = "失敗：\(error.localizedDescription)"
                            }
                            testing = false
                        }
                    }
                    .disabled(testing || !config.isConfigured)
                    if let t = testResult { Text(t).font(.caption).foregroundStyle(.secondary) }
                }
                Section("常用端點") {
                    ForEach([
                        ("OpenAI", "https://api.openai.com/v1"),
                        ("OpenRouter", "https://openrouter.ai/api/v1"),
                        ("Gemini", "https://generativelanguage.googleapis.com/v1beta/openai"),
                    ], id: \.0) { name, url in
                        Button(name) { config.baseURL = url }
                    }
                }
                Section("轉寫") {
                    Text("使用 iOS 端側語音辨識（免費）。首次轉寫需授權；部分語言需在「設定 → 一般 → 鍵盤」下載聽寫語言。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section("關於") {
                    Text("PodSnip v0.1 — 純端側，無伺服器。Snipd 式擷取＋ Podwise 式 AI。")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .navigationTitle("設定")
        }
        .onAppear { if availText.isEmpty { refreshAvail() } }
    }
}
