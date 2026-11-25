import Foundation
import Security

/// 可以接入的 AI 服务商。
/// 新加的四家（Grok、通义千问、豆包、FLUX）的接口格式都是 2026-11-22 对着官方文档写的，文档地址见 AIClient 里各自的调用处。
enum AIProvider: String, CaseIterable, Identifiable, Codable {
    case openai, gemini, minimax, grok, qwen, doubao, flux, custom

    var id: String { rawValue }

    var title: String {
        switch self {
        case .openai: return "OpenAI"
        case .gemini: return "Google Gemini"
        case .minimax: return "MiniMax"
        case .grok: return "xAI Grok"
        case .qwen: return "通义千问（阿里云百炼）"
        case .doubao: return "豆包 Seedream（火山方舟）"
        case .flux: return "FLUX（Black Forest Labs）"
        case .custom: return "自定义（OpenAI 兼容）"
        }
    }

    var shortTitle: String {
        switch self {
        case .openai: return "OpenAI"
        case .gemini: return "Gemini"
        case .minimax: return "MiniMax"
        case .grok: return "Grok"
        case .qwen: return "千问"
        case .doubao: return "豆包"
        case .flux: return "FLUX"
        case .custom: return "自定义"
        }
    }

    var defaultBaseURL: String {
        switch self {
        case .openai: return "https://api.openai.com/v1"
        case .gemini: return "https://generativelanguage.googleapis.com/v1beta"
        case .minimax: return "https://api.minimax.io/v1"
        case .grok: return "https://api.x.ai/v1"
        case .qwen: return "https://dashscope.aliyuncs.com/api/v1"
        case .doubao: return "https://ark.cn-beijing.volces.com/api/v3"
        case .flux: return "https://api.bfl.ai/v1"
        case .custom: return ""
        }
    }

    /// 官方给出的几个接入地址。不同地域的 Key 不通用，第一个是默认的。
    var baseURLChoices: [(title: String, url: String)] {
        switch self {
        case .minimax:
            return [("国际站", "https://api.minimax.io/v1"), ("国内站", "https://api.minimaxi.com/v1")]
        case .qwen:
            return [("北京", "https://dashscope.aliyuncs.com/api/v1"), ("新加坡", "https://dashscope-intl.aliyuncs.com/api/v1")]
        case .doubao:
            return [("北京", "https://ark.cn-beijing.volces.com/api/v3"), ("海外 BytePlus", "https://ark.ap-southeast.bytepluses.com/api/v3")]
        case .flux:
            return [("全球", "https://api.bfl.ai/v1"), ("欧洲", "https://api.eu.bfl.ai/v1"), ("美国", "https://api.us.bfl.ai/v1")]
        default:
            return []
        }
    }

    /// 内置的型号列表（2026-11 查官方文档得到）。型号更新很快，设置页里还可以联网刷新或手动填写。
    var builtinModels: [(id: String, note: String)] {
        switch self {
        case .openai:
            return [
                ("gpt-image-2.6-sunburst", "2.6 精细版，改图最准"),
                ("gpt-image-2.6-flare", "2.6 快速版"),
                ("gpt-image-2.5-sunburst", "2.5 精细版"),
                ("gpt-image-2.5-flare", "2.5 快速版"),
                ("gpt-image-2", "旧版，2027-02 停用"),
            ]
        case .gemini:
            return [
                ("gemini-nano-banana-2.1", "Nano Banana 2.1，官方推荐"),
                ("gemini-3-pro-image", "Nano Banana Pro"),
                ("gemini-3.1-flash-image", "Nano Banana 2"),
                ("gemini-3.1-flash-lite-image", "Nano Banana 2 Lite，便宜"),
                ("gemini-2.5-flash-image", "旧版"),
            ]
        case .minimax:
            return [
                ("MiniMax-H3-Image", "标准版"),
                ("MiniMax-H3-Image-Highspeed", "高速版"),
            ]
        case .grok:
            return [
                ("grok-imagine-image-2.0", "Imagine 2.0"),
                ("grok-imagine-image", "旧版，便宜"),
            ]
        case .qwen:
            return [
                ("qwen-image-3.0-pro", "3.0 Pro"),
                ("qwen-image-3.0", "3.0 标准版"),
                ("qwen-image-2.1-pro", "2.1 Pro"),
                ("qwen-image-2.1-turbo", "2.1 Turbo，便宜"),
                ("qwen-image-2.0-pro", "2.0 Pro"),
                ("qwen-image-2.0", "2.0 加速版"),
            ]
        case .doubao:
            return [
                ("doubao-seedream-5-5-261028", "Seedream 5.5"),
                ("doubao-seedream-5-0-pro-260628", "Seedream 5.0 Pro"),
                ("doubao-seedream-5-0-flash-260915", "Seedream 5.0 Flash，便宜"),
            ]
        case .flux:
            return [
                ("flux-3-image", "FLUX 3 Image"),
                ("flux-3-image-klein", "FLUX 3 Klein，快"),
                ("flux-kontext-pro", "Kontext Pro，旧版"),
                ("flux-kontext-max", "Kontext Max，旧版"),
            ]
        case .custom:
            return []
        }
    }

    /// 能不能联网拉取型号列表。
    var canListModels: Bool {
        switch self {
        case .openai, .gemini, .grok, .custom: return true
        case .minimax, .qwen, .doubao, .flux: return false
        }
    }

    /// 涂抹区域能不能作为蒙版直接传给接口。不能的会改用"标红参考图"。
    var supportsMask: Bool { self == .openai || self == .custom }

    /// 有没有不带输入图的文生图接口（AIClient.generate）。
    var canGenerate: Bool { self != .gemini }

    /// 这家按什么币种结算。
    var currency: AICurrency {
        switch self {
        case .qwen, .doubao: return .cny
        default: return .usd
        }
    }
}

/// 一家服务商的累计用量。
struct AIProviderStats: Codable, Equatable {
    var requests = 0
    var inputTokens = 0
    var outputTokens = 0
    var images = 0
    /// 能算出价格的那些请求的费用合计，按这家的结算币种。
    var cost = 0.0
    /// 其中有几次请求算不出价格。
    var unpriced = 0
}

/// 发请求时用的一份只读配置。
struct AIEndpoint {
    let provider: AIProvider
    let key: String
    let model: String
    var baseURL: String
    var quality: String
    var hires = true
    /// 要求尽量忠实于输入图（修脸、修跑焦这类必须还是同一个人的任务）。
    var highFidelity = false
}

/// Mac 版的 API Key 存在本机文件里（~/Library/Application Support/穷图/keys.json，只有自己的账户能读写）。
/// Mac 版没有带钥匙串权限的签名，每次重新编译、替换程序后钥匙串里的就读不到了，所以不放钥匙串。
enum MacKeyFile {
    private static var url: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("穷图", isDirectory: true).appendingPathComponent("keys.json")
    }

    private static func load() -> [String: String] {
        guard let data = try? Data(contentsOf: url),
              let dict = try? JSONDecoder().decode([String: String].self, from: data) else { return [:] }
        return dict
    }

    static func get(_ account: String) -> String? {
        load()[account]
    }

    static func set(_ value: String, account: String) {
        var dict = load()
        dict[account] = value.isEmpty ? nil : value
        let fm = FileManager.default
        let dir = url.deletingLastPathComponent()
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        guard let data = try? JSONEncoder().encode(dict) else { return }
        try? data.write(to: url, options: .atomic)
        try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}

/// API Key 存在系统钥匙串里，不进 UserDefaults，也不会跟着备份明文走。（Mac 版存本地文件，见 MacKeyFile）
enum Keychain {
    private static let service = "com.taoo.xiutu.apikey"

    static func get(_ account: String) -> String {
        if Platform.isMac {
            if let value = MacKeyFile.get(account) { return value }
            // 以前存进钥匙串的（第一次装的那一版）：读得到就搬到本地文件里。
            let old = keychainGet(account)
            if !old.isEmpty { MacKeyFile.set(old, account: account) }
            return old
        }
        return keychainGet(account)
    }

    private static func keychainGet(_ account: String) -> String {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data, let value = String(data: data, encoding: .utf8) else { return "" }
        return value
    }

    static func set(_ value: String, account: String) {
        if Platform.isMac {
            MacKeyFile.set(value, account: account)
            return
        }
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(base as CFDictionary)
        guard !value.isEmpty else { return }
        var add = base
        add[kSecValueData as String] = Data(value.utf8)
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        SecItemAdd(add as CFDictionary, nil)
    }
}

@MainActor
@Observable
final class AISettings {
    static let shared = AISettings()

    struct ProviderConfig: Codable, Equatable {
        var model: String
        var baseURL: String
        var fetchedModels: [String] = []
        /// 测试连接有没有通过。nil = 这个开关加进来之前就填好的 Key，算通过。
        var verified: Bool? = nil
    }

    static let qualities: [(id: String, title: String)] = [
        ("auto", "自动"), ("low", "低（省钱）"), ("medium", "中"), ("high", "高"),
    ]

    private(set) var active: AIProvider
    private(set) var quality: String
    /// OpenAI 高清输出：按图片实际大小要结果，更清晰也更贵。
    private(set) var hires = !UserDefaults.standard.bool(forKey: "ai.hiresOff")
    private(set) var configs: [AIProvider: ProviderConfig]
    private(set) var keys: [AIProvider: String]

    private static let storeKey = "ai.settings.v1"

    private struct Stored: Codable {
        var active: AIProvider
        var quality: String
        var configs: [String: ProviderConfig]
    }

    private init() {
        var active: AIProvider = .openai
        var quality = "auto"
        var configs: [AIProvider: ProviderConfig] = [:]
        if let data = UserDefaults.standard.data(forKey: Self.storeKey),
           let stored = try? JSONDecoder().decode(Stored.self, from: data) {
            active = stored.active
            quality = stored.quality
            for (k, v) in stored.configs {
                if let p = AIProvider(rawValue: k) { configs[p] = v }
            }
        }
        var keys: [AIProvider: String] = [:]
        for p in AIProvider.allCases {
            if configs[p] == nil {
                configs[p] = ProviderConfig(model: p.builtinModels.first?.id ?? "", baseURL: p.defaultBaseURL)
            }
            keys[p] = Keychain.get(p.rawValue)
        }
        #if DEBUG
        if let forced = AIProvider(rawValue: ProcessInfo.processInfo.environment["XIUTU_TEST_PROVIDER"] ?? "") { active = forced }
        #endif
        self.active = active
        self.quality = quality
        self.configs = configs
        self.keys = keys
    }

    private func save() {
        var dict: [String: ProviderConfig] = [:]
        for (k, v) in configs { dict[k.rawValue] = v }
        if let data = try? JSONEncoder().encode(Stored(active: active, quality: quality, configs: dict)) {
            UserDefaults.standard.set(data, forKey: Self.storeKey)
        }
    }

    func setActive(_ provider: AIProvider) {
        active = provider
        save()
    }

    // MARK: 用量统计

    /// 各家的累计用量。每次请求成功后由 AIClient 统一记进来，调用处不用管。
    private(set) var usage: [AIProvider: AIProviderStats] = AISettings.loadUsage()

    private static let usageKey = "ai.usage.v1"

    private static func loadUsage() -> [AIProvider: AIProviderStats] {
        var out: [AIProvider: AIProviderStats] = [:]
        let defaults = UserDefaults.standard
        if let data = defaults.data(forKey: usageKey),
           let stored = try? JSONDecoder().decode([String: AIProviderStats].self, from: data) {
            for (k, v) in stored {
                if let p = AIProvider(rawValue: k) { out[p] = v }
            }
        } else if defaults.integer(forKey: "ai.spendCount") > 0 {
            // 旧版只记了一个总数，当时能估价的只有 OpenAI，接着往下累计。
            out[.openai] = AIProviderStats(requests: defaults.integer(forKey: "ai.spendCount"),
                                           images: defaults.integer(forKey: "ai.spendCount"),
                                           cost: defaults.double(forKey: "ai.spendTotal"))
        }
        return out
    }

    private func saveUsage() {
        var dict: [String: AIProviderStats] = [:]
        for (k, v) in usage { dict[k.rawValue] = v }
        if let data = try? JSONEncoder().encode(dict) {
            UserDefaults.standard.set(data, forKey: Self.usageKey)
        }
    }

    func stats(_ provider: AIProvider) -> AIProviderStats { usage[provider] ?? AIProviderStats() }

    func addUsage(_ u: AIUsage) {
        // 接模拟接口的调试运行不记进累计（和正式版共用一份数据）。
        if testOverride != nil { return }
        var s = stats(u.provider)
        s.requests += 1
        s.inputTokens += u.inputText + u.inputImage
        s.outputTokens += u.output
        s.images += u.images
        if let amount = u.amount { s.cost += amount } else { s.unpriced += 1 }
        usage[u.provider] = s
        saveUsage()
    }

    /// provider 为 nil 时全部清零。
    func resetUsage(_ provider: AIProvider? = nil) {
        if let provider { usage[provider] = nil } else { usage = [:] }
        saveUsage()
        UserDefaults.standard.removeObject(forKey: "ai.spendTotal")
        UserDefaults.standard.removeObject(forKey: "ai.spendCount")
    }

    /// 按某个币种结算的几家加起来。
    func usageTotal(_ currency: AICurrency) -> AIProviderStats {
        var total = AIProviderStats()
        for (provider, s) in usage where provider.currency == currency {
            total.requests += s.requests
            total.inputTokens += s.inputTokens
            total.outputTokens += s.outputTokens
            total.images += s.images
            total.cost += s.cost
            total.unpriced += s.unpriced
        }
        return total
    }

    /// 累计估算花费（美元）和总请求数：从上面的统计里算出来，和各家的数字始终对得上。
    var spendTotal: Double { usageTotal(.usd).cost }
    var spendCount: Int { usage.values.reduce(0) { $0 + $1.requests } }

    /// 以前由各个调用处自己累加花费；现在 AIClient 已经统一记了，这里留着只为不改调用处，不再重复累加。
    func addSpend(_ cost: Double) {}

    func resetSpend() { resetUsage() }

    func setHires(_ on: Bool) {
        hires = on
        UserDefaults.standard.set(!on, forKey: "ai.hiresOff")
    }

    func setQuality(_ value: String) {
        quality = value
        save()
    }

    func config(_ provider: AIProvider) -> ProviderConfig {
        configs[provider] ?? ProviderConfig(model: "", baseURL: provider.defaultBaseURL)
    }

    func update(_ provider: AIProvider, _ change: (inout ProviderConfig) -> Void) {
        var c = config(provider)
        change(&c)
        configs[provider] = c
        save()
    }

    func key(_ provider: AIProvider) -> String { keys[provider] ?? "" }

    func setKey(_ value: String, for provider: AIProvider) {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        // Key 换了就要重新测试。
        if trimmed != key(provider) { update(provider) { $0.verified = false } }
        keys[provider] = trimmed
        Keychain.set(trimmed, account: provider.rawValue)
    }

    /// 这家的 Key 有没有通过测试连接。
    func isVerified(_ provider: AIProvider) -> Bool {
        !key(provider).isEmpty && (config(provider).verified ?? true)
    }

    /// 测试这家的连接；通过了才算可用。返回 nil = 通过，否则是没通过的原因。
    @discardableResult
    func verify(_ provider: AIProvider) async -> String? {
        guard let endpoint = probeEndpoint(provider) else { return "还没有填 Key。" }
        do {
            let models = try await AIClient.verify(endpoint)
            // 等结果的这会儿 Key 或地址被改过，这次结果就不算数。
            guard endpoint.key == key(provider), endpoint.baseURL == config(provider).baseURL
                .trimmingCharacters(in: .whitespacesAndNewlines) else { return "Key 或接口地址刚改过，请再测一次。" }
            update(provider) {
                $0.verified = true
                if provider.canListModels { $0.fetchedModels = models }
            }
            return nil
        } catch {
            let status = (error as? AIError)?.status ?? 0
            if status == 401 || status == 403 { update(provider) { $0.verified = false } }
            return error.localizedDescription
        }
    }

    /// 仅调试版：用环境变量把请求指到本地模拟服务器，方便不花钱地测试整条流程。正式版里这段代码不存在。
    private var testOverride: (provider: AIProvider, base: String, key: String)? {
        #if DEBUG
        let env = ProcessInfo.processInfo.environment
        if let base = env["XIUTU_TEST_BASE"], let key = env["XIUTU_TEST_KEY"],
           let provider = AIProvider(rawValue: env["XIUTU_TEST_PROVIDER"] ?? "openai") {
            return (provider, base, key)
        }
        #endif
        return nil
    }

    func isConfigured(_ provider: AIProvider) -> Bool {
        if let test = testOverride, test.provider == provider { return true }
        let c = config(provider)
        return !key(provider).isEmpty && !c.model.isEmpty && !c.baseURL.isEmpty && isVerified(provider)
    }

    /// 内置型号 + 联网拉到的型号 + 当前手填的型号，去重。
    func modelChoices(_ provider: AIProvider) -> [String] {
        var seen = Set<String>()
        var out: [String] = []
        let c = config(provider)
        for id in provider.builtinModels.map(\.id) + c.fetchedModels + [c.model] where !id.isEmpty {
            if seen.insert(id).inserted { out.append(id) }
        }
        return out
    }

    func endpoint(_ provider: AIProvider? = nil) -> AIEndpoint? {
        let p = provider ?? active
        guard isConfigured(p) else { return nil }
        let c = config(p)
        if let test = testOverride, test.provider == p {
            return AIEndpoint(provider: p, key: test.key, model: c.model, baseURL: test.base, quality: quality, hires: hires)
        }
        return AIEndpoint(provider: p, key: key(p), model: c.model,
                          baseURL: c.baseURL.trimmingCharacters(in: .whitespacesAndNewlines), quality: quality, hires: hires)
    }

    /// 只要有 Key 就能用来测连接、拉型号。
    func probeEndpoint(_ provider: AIProvider) -> AIEndpoint? {
        let c = config(provider)
        guard !key(provider).isEmpty, !c.baseURL.isEmpty else { return nil }
        return AIEndpoint(provider: provider, key: key(provider), model: c.model,
                          baseURL: c.baseURL.trimmingCharacters(in: .whitespacesAndNewlines), quality: quality, hires: hires)
    }
}
