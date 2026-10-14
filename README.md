# PodSnip

**Listen, capture, and revisit podcast ideas.**

PodSnip 是 SwiftUI／SwiftData iOS Podcast 原型：RSS 節目庫、播放與下載、Speech 逐字稿、時間戳擷取（Snip）、AI 整理與 Markdown 分享。

2026-10-14 已以 **Xcode 27.0／iOS 27 SDK** 完成原生模擬器建置。三種 AI 來源已接入同一服務；**尚未驗證任何真實模型推理**。本次使用合成資料與注入的假 provider，完整驗證範圍及重現命令見 [docs/VALIDATION.md](docs/VALIDATION.md)。[PR #1](https://github.com/knowlet/PodSnip/pull/1) 保持 Draft。

完整測試包含 35 個單元／契約測試與 1 個 UI 導覽測試：iOS 27 全數通過；iOS 17 與 26 均零失敗，分別明確跳過 3 個與 1 個該版本不支援的 Apple API fixture。

## 使用

1. 在「節目」頁加入 RSS 連結，選擇單集播放或下載。
2. 按「轉寫」下載音檔並請求 Speech 授權；預設辨識語言為 `zh-TW`，約四分鐘切段。逐字稿可點句跳播。
3. 播放時按「Snip 這一段」留下時間與附近逐字稿；沒有逐字稿仍可留下標記。這不是剪輯音檔。
4. 在「設定」選擇 AI 來源；只有 OpenAI 相容來源需要 Base URL、API Key 與模型。按「測試所選來源」會對該來源傳送合成的簡短文字。
5. 有逐字稿後可執行「AI 全套」或問答；Snip 會先保存原文，再嘗試產生筆記。失敗原因會顯示在畫面與 Snip 紀錄。
6. 在「擷取」頁透過系統分享介面分享 Markdown。

## 三種 AI 來源

`ApplicationAIService` 以一次操作開始時的設定快照選擇唯一 provider。五個摘要階段、問答、Snip 筆記與連線測試，全部使用同一入口。變更設定不會讓正在進行的摘要中途換來源；未知路由或失敗會報錯，不會自動轉送其他供應商。

| 來源 | 執行條件 | 實作與驗證 |
| --- | --- | --- |
| Apple 端側 Foundation Models | iOS 26+、Apple Intelligence 合格裝置、功能已啟用且模型已就緒 | `SystemLanguageModel.default`；原生編譯與合成契約測試，真實推理待驗 |
| Apple 雲端 Foundation Models（PCC） | iOS 27+、Apple 資格與核准的 managed entitlement、系統可用及未達配額 | 真實 `PrivateCloudComputeLanguageModel` API；原生編譯與合成錯誤測試，entitlement／帳號資格未知，雲端推理待驗 |
| OpenAI 相容 API | 有效端點、Key、模型，供應商支援 `/chat/completions` 與 JSON object mode | 注入的合成 provider／HTTP fixture 測試；真實端點與費用未測 |

Apple 呼叫每次建立新的 `LanguageModelSession`。結構化結果使用實際 `GenerationSchema` guided generation，轉成共用 Codable 輸出並驗證欄位與時間；問答及測試使用純文字。OpenAI 相容 JSON object mode 不等於 schema enforcement，結果仍須通過相同解析與驗證。可偵測的不完整、無效或超出預算結果會顯示錯誤；Apple 的結構完整旗標不保證語意完整，部分相容端點也不提供結束原因。

PCC 是 Apple 官方提供且存在於本機 SDK 的 API；部分文件仍可能標示 beta。它需要 [Apple 核准的資格及 entitlement](https://developer.apple.com/private-cloud-compute/)；本專案未申請 entitlement、變更簽章或驗證使用者資格。配額訊息依 `quotaUsage` 與生成時的錯誤呈現，只有 Apple 提供時才顯示重置日期或提升建議；沒有剩餘次數或每日固定重置的保證。網路、服務與配額失敗都會保留原路由並顯示原因。[PCC API](https://developer.apple.com/documentation/foundationmodels/privatecloudcomputelanguagemodel)

## 長逐字稿與涵蓋範圍

已移除原本 12,000 字元的頭尾／前段截斷。摘要依來源的保守輸入預算分塊，保留文字、原始絕對時間戳與時間範圍；超長單句也會分塊。每塊執行全部五個階段，再依時間合併為分段摘要、要點、章節、心智圖與洞見；全部完成及驗證後才更新舊結果。畫面顯示來源、進度、處理片段數與涵蓋範圍。這是分段整理，未提供的音訊或轉寫空隙不在涵蓋範圍內。

Apple 端側是 4,096 token、PCC 是 32K 的共享上下文，包含輸入與輸出。[Apple 上下文說明](https://developer.apple.com/documentation/foundationmodels/managing-the-context-window)、[WWDC26 工程師說明（08:11）](https://developer.apple.com/videos/play/wwdc2026/8121/)

程式以 UTF-8 bytes 作保守輸入估算，另預留 schema、框架格式與輸出 token，並檢查 schema 實際編碼大小。這不是精確 tokenizer 保證；模型的上下文錯誤仍會顯示，不會偷偷縮短或換 provider。OpenAI 相容來源採 8,192 token 的應用預算，實際模型可能更小，須由使用者選擇相容模型。摘要會產生 **5 × 片段數** 個請求，長內容較慢且可能消耗更多雲端配額／費用。

問答依問題文字比對選取可放入預算的時間戳片段，每則答案顯示選取數量、範圍與遺漏提示；文字比對可能漏掉相關證據，答案不代表搜尋過全集。過長問題直接報錯。長 Snip 筆記也分塊處理，原始 Snip 內容不會因 AI 失敗遺失。完成與失敗狀態會保留，方便重試。

## 資料流

- RSS、封面及音訊由 App 直接向各網址取得；下載音檔位於 App Documents，節目、逐字稿、摘要與 Snip 位於本機 SwiftData。
- Speech 在 `supportsOnDeviceRecognition` 為真時要求端側辨識；其他情況可能使用 Apple 遠端辨識。
- Apple 端側 AI 在裝置處理。PCC 把內容傳至 Apple；OpenAI 相容路由把內容送至指定端點。Snip 也可能觸發所選來源的 AI 請求。請依服務規則評估內容及費用。
- API Key 存 Keychain，其他 AI 設定存 UserDefaults。Apple 來源不需要 BYOK Key。
- 分享內容包含文字、時間、筆記與可能的 AI 錯誤；分享前請確認內容。

## 建置與本地測試

[project.yml](project.yml) 是設定來源；產生的 Xcode 專案與共用測試 scheme 一併保留，修改設定後請重新產生。需要已安裝的 **Xcode 27+／iOS 27 SDK**（PCC 符號無法靠 `#available` 在舊 SDK 編譯）及 [XcodeGen](https://github.com/yonaskolb/XcodeGen)。保留 iOS **17.0** deployment target、Swift **5.0** language mode、`CODE_SIGNING_ALLOWED=NO`、空白開發團隊。

```sh
xcodegen generate
xcodebuild -project PodSnip.xcodeproj -scheme PodSnip \
  -sdk iphonesimulator -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath .build/local CODE_SIGNING_ALLOWED=NO build
xcodebuild -project PodSnip.xcodeproj -scheme PodSnip \
  -destination 'platform=iOS Simulator,id=YOUR_FRESH_SIMULATOR_UUID' \
  -derivedDataPath .build/local CODE_SIGNING_ALLOWED=NO test
```

請用已安裝 runtime 的全新模擬器執行合成測試。測試不使用私人音檔、麥克風、Keychain 憑證或實際模型。Speech usage description 與背景 audio 已由 `project.yml` 宣告；這些宣告不會授予裝置權限。

## 驗收限制與既有修正

既有四項修正保留：轉寫 offset 只加一次、離開轉寫流程時清除 busy／progress、每個播放器只註冊一次遠端指令，以及每次轉寫使用獨立暫存目錄並清理。新增的合成測試直接執行 production 時間分組與目錄管理 helper；既有已儲存逐字稿不會自動改寫。

真機 Speech 授權／失敗重試、八分鐘以上音檔、點句播放與高亮、鎖屏耳機指令、背景播放、真實 Apple／PCC／BYOK 推理及品質／速度仍需驗收。PCC 最小後續步驟是先確認帳號已具 Apple 核准的資格與 entitlement，再以獨立授權的簽章／合成輸入測試；本次沒有進行申請或更動。
