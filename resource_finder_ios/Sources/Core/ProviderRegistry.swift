import Foundation

struct ProviderConfig: Identifiable, Sendable {
    let id: String
    let name: String
    var api: String? = nil
    var experimental = false
    var interval: TimeInterval = 0
}
enum ProviderRegistry {
    static let all: [ProviderConfig] = [
        .init(id: "jianpian", name: "荐片影视"), .init(id: "kkys", name: "可可影视"),
        .init(id: "hongniu", name: "红牛资源", api: "https://www.hongniuzy2.com/api.php/provide/vod/"),
        .init(id: "s360", name: "360资源", api: "https://360zyzz.com/api.php/provide/vod/"),
        .init(id: "modu", name: "魔都资源", api: "https://www.mdzyapi.com/api.php/provide/vod/"),
        .init(id: "feifan", name: "非凡资源", api: "https://api.ffzyapi.com/api.php/provide/vod/", experimental: true),
        .init(id: "liangzi", name: "量子资源", api: "https://cj.lziapi.com/api.php/provide/vod/", experimental: true),
        .init(id: "baofeng", name: "暴风资源", api: "https://bfzyapi.com/api.php/provide/vod/", experimental: true),
        .init(id: "wujin", name: "无尽资源", api: "https://api.wujinapi.me/api.php/provide/vod/", experimental: true),
        .init(id: "tianya", name: "天涯资源", api: "https://tyyszyapi.com/api.php/provide/vod/", experimental: true, interval: 5)
    ]
    static func config(_ id: String) -> ProviderConfig? { all.first { $0.id == id } }
    static func name(_ id: String) -> String { config(id)?.name ?? id }
}

enum VerificationState: String, Codable, Sendable {
    case unverified, resolved, failed, unsupported
    var label: String {
        switch self { case .unverified: return "未验证"; case .resolved: return "已解析"; case .failed: return "本次失败"; case .unsupported: return "暂不支持" }
    }
}
struct AccessObservation: Codable, Equatable, Sendable {
    var state: VerificationState = .unverified
    var detail = ""
    var checkedAt: Date? = nil
}
struct ProviderObservation: Codable, Equatable, Sendable {
    var catalog = AccessObservation()
    var media = AccessObservation()
}
