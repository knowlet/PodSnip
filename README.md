# PodSnip

Snipd 式擷取 ＋ Podwise 式 AI 的原生 iOS App（純端側，無伺服器）。

- 節目庫：貼 RSS 連結 → 單集列表（含封面）
- 播放器：串流／本地、背景播放、鎖屏＋耳機鍵，🔖 鍵＝一鍵 Snip
- 逐字稿：iOS 端側 Speech 轉寫，點句跳播、跟隨高亮
- AI 三路：Apple 端側（iOS 26+）／Apple 雲端（iOS 27+，配額制）／自帶 OpenAI 相容 Key
- AI 全套：總覽＋要點＋章節＋心智圖＋洞見＋逐集問答
- 擷取頁：Snip 列表＋ Markdown 分享

## 建置

`project.yml` 是唯一真相（[XcodeGen](https://github.com/yonaskolb/XcodeGen)）：

```sh
xcodegen generate
xcodebuild -project PodSnip.xcodeproj -scheme PodSnip -sdk iphonesimulator CODE_SIGNING_ALLOWED=NO build
```

需求：Xcode 27+（FoundationModels cloud API 需 iOS 27 SDK）。

## 真機驗證缺口

模擬器跑不了 Apple Intelligence 模型（蘋果不給 sim 下模型）。
端側／雲端真實推理需 Apple Intelligence 真機（iPhone 15 Pro 以上）＋ iOS 26/27。
