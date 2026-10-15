import SwiftUI

struct SettingsView: View {
    @State private var config = AIConfig.load()
    @State private var testResult: String?
    @State private var testing = false
    @State private var showKey = false
    @State private var availText = ""
    @State private var availOK = false

    private var selectedService: ApplicationAIService { ApplicationAIService(config: config) }
    private var routeBinding: Binding<AIRoute> {
        Binding(get: { config.route }, set: {
            config.routeRaw = $0.rawValue
            config.save()
            testResult = nil
            refreshAvail()
        })
    }

    private func refreshAvail() {
        let availability = selectedService.availability
        availOK = availability.isAvailable
        availText = availability.reason
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("AI 來源") {
                    Picker("路由", selection: routeBinding) {
                        ForEach(AIRoute.allCases) { route in
                            Text(route.title).tag(route)
                        }
                    }
                    .disabled(testing)
                    Text(config.route.subtitle).font(.caption).foregroundStyle(.secondary)
                    HStack {
                        Text(availText).font(.caption).foregroundStyle(availOK ? Color.green : Color.orange)
                        Spacer()
                        Button("檢查") { refreshAvail() }.font(.caption)
                    }
                    Button(testing ? "測試中…" : "測試所選來源") {
                        // Snapshot the displayed configuration before asynchronous work.
                        let service = selectedService
                        config.save()
                        Task {
                            testing = true
                            testResult = nil
                            defer { testing = false; refreshAvail() }
                            do {
                                let response = try await service.testConnection()
                                testResult = "\(service.route.title) 連線成功：\(response.prefix(60))"
                            } catch {
                                testResult = "\(service.route.title) 失敗：\(error.localizedDescription)"
                            }
                        }
                    }
                    .disabled(testing || !selectedService.availability.isAvailable)
                    .accessibilityIdentifier("testSelectedAIProvider")
                    if let result = testResult {
                        Text(result).font(.caption).foregroundStyle(.secondary)
                    }
                    Text("所有 AI 功能只使用所選來源；失敗時會顯示原因，不會改送其他供應商。測試會向所選來源傳送合成的簡短文字。")
                        .font(.caption).foregroundStyle(.secondary)
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
                    Button("儲存") {
                        config.save()
                        refreshAvail()
                        testResult = "已儲存 ✓"
                    }
                    Text("Apple 來源不需要這些欄位或 API Key。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section("常用端點") {
                    ForEach([
                        ("OpenAI", "https://api.openai.com/v1"),
                        ("OpenRouter", "https://openrouter.ai/api/v1"),
                        ("Gemini", "https://generativelanguage.googleapis.com/v1beta/openai"),
                    ], id: \.0) { name, url in
                        Button(name) { config.baseURL = url; refreshAvail() }
                    }
                }
                Section("轉寫") {
                    Text("語音辨識在支援時使用端側模型，否則可能使用 Apple 遠端辨識。首次轉寫需授權；支援情況依裝置、語言與已安裝的辨識模型而定。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section("關於") {
                    Text("PodSnip v0.1 — 播客播放、擷取與 AI 摘要。Apple 端側在裝置處理；PCC 與 OpenAI 相容來源會將選取內容傳送至各自服務。")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .navigationTitle("設定")
        }
        .onAppear { refreshAvail() }
    }
}
