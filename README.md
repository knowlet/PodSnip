# PodSnip

**Listen, capture, and revisit podcast ideas.**

PodSnip 是以 SwiftUI 與 SwiftData 製作的原生 iOS Podcast 專案，串起 RSS 節目庫、音訊播放、逐字稿、時間戳擷取（Snip）與選用的 AI 整理。想留下某個觀點時，可以記下播放位置和附近的逐字稿，再以 Markdown 分享。

目前是開發中的原型。以下功能與限制依原始碼整理，**尚未完成 Xcode 建置、模擬器或真機執行驗證**。

## 功能

- **RSS 節目庫**：貼上節目 RSS 連結，載入節目封面與單集列表。
- **播放與下載**：使用 AVPlayer 串流播放，或播放已下載的音檔；提供進度拖曳、後退 15 秒與前進 30 秒。
- **逐字稿**：下載音檔後透過 Apple Speech 轉寫，預設語言為 `zh-TW`，以約 4 分鐘分段處理。介面提供點句跳播、目前段落高亮與自動捲動。
- **Snip 擷取**：記錄當下時間戳，以及起始時間距播放位置約 45 秒內的逐字稿段落；沒有逐字稿時仍可留下時間標記。Snip 是文字與時間紀錄，並非匯出剪輯音檔。
- **AI 整理（選用）**：依逐字稿產生總覽、要點、章節、可展開的心智圖與洞見，並提供逐集問答。設定自帶 API Key 後，建立 Snip 也會嘗試產生 AI 筆記。
- **Markdown 分享**：「擷取」頁可分享單筆 Snip 的單集名稱、時間、文字與 AI 筆記。

播放器已有 Now Playing 與 MediaPlayer 遙控指令的程式碼，包括將 bookmark 指令連到 Snip；鎖屏、耳機與背景播放的實際行為仍待驗證，詳見下方限制。

## 使用流程

完成建置與必要的專案設定後：

1. 在「節目」頁按 ＋，貼上 RSS 連結並加入。
2. 選擇單集進入播放器；也可在單集列表滑動選擇「下載」。
3. 按「轉寫」，下載音檔並請求語音辨識授權，再產生逐字稿。
4. 播放時按「Snip 這一段」，到「擷取」頁查看或分享。
5. 若要使用 AI，在「設定」填入可信任服務的 Base URL、API Key 與模型，儲存後測試連線；有逐字稿後可執行「AI 全套」或問答。

### AI 來源的目前狀態

主要 AI 功能目前直接呼叫 `AIClient`，將請求送到設定的 OpenAI 相容 `/chat/completions` 端點。供應商與模型需要支援程式使用的請求格式，包含部分功能要求的 JSON 回應。

| 來源 | 程式中的條件 | 目前接入範圍 |
| --- | --- | --- |
| 自帶 Key（OpenAI 相容） | Base URL、Key、模型設定完整 | AI 整理、問答、Snip 筆記與連線測試；尚未執行驗證 |
| Apple 端側 | iOS 26 版本判斷與模型可用性檢查 | 設定頁檢查／測試與 `AppleBrain` 呼叫實作；尚未接入主要 AI 功能 |
| Apple 雲端 | iOS 27 版本判斷、可用性與配額檢查 | 設定頁檢查／測試與 `AppleBrain` 呼叫實作；尚未接入主要 AI 功能 |

**切換設定頁的 Apple 路由，不會使「AI 全套」、問答或 Snip 筆記改用 Apple 模型。** Apple API／SDK 相容性與實際推理亦尚未驗證。

## 資料流與隱私

本專案未包含自建後端；但使用過程會連線至外部服務，不能視為全程離線或「純端側」。

- **RSS、封面與音訊**：由 App 直接向對應網址取得。下載音檔存於 App 的 Documents 目錄；節目、單集、逐字稿、AI 整理結果與 Snip 使用本機 SwiftData 儲存。
- **語音辨識**：當 `supportsOnDeviceRecognition` 為真時，程式要求裝置端辨識；不支援時沒有強制本機辨識，可能使用 Apple 的遠端辨識服務。
- **AI 請求**：使用目前主要 AI 功能時，逐字稿內容或擷取文字，以及問答輸入，會送至設定的供應商。設定有效的 API Key 後，按 Snip 也可能觸發這類請求。費用與資料處理由該服務的規則決定。
- **憑證與設定**：API Key 透過 Keychain 儲存；Base URL、模型與路由選擇存於 UserDefaults。Keychain 儲存不代表內容不會傳送：API 請求仍會使用該 Key 向所選端點驗證。
- **分享**：Markdown 經系統分享介面送至使用者選擇的目的地，請先確認內容適合分享。

## 建置

[project.yml](project.yml) 是 XcodeGen 專案設定來源。目前設定為：

- iOS deployment target：**17.0**
- Swift language mode：**5.0**
- App target／scheme：`PodSnip`
- 簽章：`CODE_SIGNING_ALLOWED: NO`，`DEVELOPMENT_TEAM` 為空

需要 macOS、Xcode 與 [XcodeGen](https://github.com/yonaskolb/XcodeGen)。Deployment target 不等於可用的建置 SDK：原始碼直接匯入 `FoundationModels`，並引用 `PrivateCloudComputeLanguageModel` 等符號。既有建置說明要求 Xcode 27+／iOS 27 SDK；**目前沒有建置結果可確認這項需求或相關 API 相容性**。

在專案根目錄執行既有建置命令：

```sh
xcodegen generate
xcodebuild -project PodSnip.xcodeproj -scheme PodSnip -sdk iphonesimulator CODE_SIGNING_ALLOWED=NO build
```

以上是待執行的建置步驟，並非已通過的驗證。真機安裝另需設定自己的開發團隊與簽章。

## 已知限制與驗證狀態

- **權限與背景設定尚有缺口**：目前 `Info.plist` 未宣告 `NSSpeechRecognitionUsageDescription` 或 `UIBackgroundModes` 的 `audio`，可能導致語音授權流程失敗及背景播放無法正常運作；測試前需補齊必要設定。
- **長逐字稿會截斷**：AI 整理通常最多使用約 12,000 字元；一般摘要保留開頭與結尾，含時間戳的章節／問答保留前段。因此輸出可能缺少未送入模型的內容。
- **AI 輸出需要核對**：摘要、章節與問答依賴供應商回應；本專案尚未驗證其正確性、涵蓋率或速度。
- **原生驗證尚未執行**：Swift／Xcode 編譯、Speech／AVFoundation／MediaPlayer 整合、UI、背景播放及 Apple 模型推理均未完成執行驗證。原始碼中已有實作，不代表這些路徑已可在裝置上使用。

### 尚未合併的修正

截至 2026-10-14，[Draft PR #1](https://github.com/knowlet/PodSnip/pull/1) 的程式碼基準為 `9198ba3d856272ae8a4f3991f4a5cf042977fbca`，包含四項修正，尚未合併至 `main`：

1. 轉寫分段的時間偏移只套用一次，避免後段時間戳重複加總。
2. 轉寫流程結束時清除忙碌與進度狀態。
3. 每個 AudioPlayer 實例只註冊一次遙控指令，避免切集後重複回呼。
4. 每次轉寫使用獨立暫存目錄，並在流程結束時嘗試清理。

這些修正經原始碼檢視；時間戳另做過算術診斷，但不是 Swift 或 iOS 測試。既有逐字稿不會自動重寫。合併前仍需驗證長音檔時間戳、失敗後重試、多次切集的遙控行為，以及重疊轉寫的檔案隔離與清理；完整驗收項目見 PR。
