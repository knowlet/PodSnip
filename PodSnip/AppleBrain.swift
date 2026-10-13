import Foundation
import UIKit
import FoundationModels

/// AI 路由：Apple 端側 / Apple 雲端 / 自帶 OpenAI 相容 key。
/// - onDevice：SystemLanguageModel，iOS 26+，裝置端免費，需 Apple Intelligence。
/// - appleCloud：PrivateCloudComputeLanguageModel，iOS 27+，有配額（quota），超額會回 LimitIncreaseSuggestion。
///   注意：SDK 裡沒有名為 "pro" 的 tier；所謂 pro 只是配額提升後的狀態，App 不虛構該 API。
/// - byok：既有 AIClient（OpenAI-compatible），全版本可用。
enum AIRoute: String, CaseIterable, Identifiable {
    case onDevice = "apple-ondevice"
    case appleCloud = "apple-cloud"
    case byok = "byok"

    var id: String { rawValue }
    var title: String {
        switch self {
        case .onDevice: return "Apple 端側（免費）"
        case .appleCloud: return "Apple 雲端（配額制）"
        case .byok: return "自帶 Key（OpenAI 相容）"
        }
    }
    var subtitle: String {
        switch self {
        case .onDevice: return "需 iOS 26＋Apple Intelligence 機型"
        case .appleCloud: return "需 iOS 27，超額需等重置或提額"
        case .byok: return "全版本可用，走自己的 endpoint"
        }
    }
}

enum AppleBrainError: LocalizedError {
    case unsupportedOS(String)
    case unavailable(String)
    case quotaReached(String)

    var errorDescription: String? {
        switch self {
        case .unsupportedOS(let s): return s
        case .unavailable(let s): return s
        case .quotaReached(let s): return s
        }
    }
}

/// Apple Foundation Models 聊天（端側＋雲端），接口與 AIClient.chat 對齊。
struct AppleBrain {
    let route: AIRoute

    /// 可用性檢查（不花配額，可每次呼叫前先問）。
    static func check(_ route: AIRoute) -> (ok: Bool, reason: String) {
        switch route {
        case .byok:
            let c = AIConfig.load().isConfigured
            return (c, c ? "已設定" : "請先填 Base URL、Key、模型")
        case .onDevice:
            if #available(iOS 26, *) {
                switch SystemLanguageModel.default.availability {
                case .available: return (true, "端側模型可用")
                case .unavailable(let r):
                    switch r {
                    case .deviceNotEligible: return (false, "此裝置不支援 Apple Intelligence")
                    case .appleIntelligenceNotEnabled: return (false, "請到設定開啟 Apple Intelligence 並下載模型")
                    case .modelNotReady: return (false, "模型下載中，稍後再試")
                    @unknown default: return (false, "端側模型暫不可用")
                    }
                }
            } else {
                return (false, "需 iOS 26 以上（本機 \(UIDevice.current.systemVersion)）")
            }
        case .appleCloud:
            if #available(iOS 27, *) {
                let m = PrivateCloudComputeLanguageModel()
                switch m.availability {
                case .available:
                    if m.quotaUsage.isLimitReached {
                        return (false, "本期配額用完，重置日後再試")
                    }
                    return (true, "雲端模型可用")
                case .unavailable(let r):
                    switch r {
                    case .deviceNotEligible: return (false, "此裝置不支援 Apple 雲端模型")
                    case .systemNotReady: return (false, "系統尚未就緒，稍後再試")
                    @unknown default: return (false, "雲端模型暫不可用")
                    }
                }
            } else {
                return (false, "需 iOS 27 以上（本機 \(UIDevice.current.systemVersion)）")
            }
        }
    }

    func chat(system: String, user: String) async throws -> String {
        switch route {
        case .byok:
            return try await AIClient(config: .load()).chat(system: system, user: user, jsonMode: true)
        case .onDevice:
            guard #available(iOS 26, *) else {
                throw AppleBrainError.unsupportedOS("端側模型需 iOS 26 以上")
            }
            guard case .available = SystemLanguageModel.default.availability else {
                let c = Self.check(.onDevice)
                throw AppleBrainError.unavailable(c.reason)
            }
            let session = LanguageModelSession(model: SystemLanguageModel.default, instructions: system)
            let resp = try await session.respond(to: user)
            return resp.content
        case .appleCloud:
            guard #available(iOS 27, *) else {
                throw AppleBrainError.unsupportedOS("Apple 雲端模型需 iOS 27 以上")
            }
            let model = PrivateCloudComputeLanguageModel()
            guard case .available = model.availability else {
                let c = Self.check(.appleCloud)
                throw AppleBrainError.unavailable(c.reason)
            }
            if model.quotaUsage.isLimitReached {
                throw AppleBrainError.quotaReached("本期雲端配額用完，請等重置或改用端側／自帶 Key")
            }
            let session = LanguageModelSession(model: model, instructions: system)
            let resp = try await session.respond(to: user)
            return resp.content
        }
    }
}
