import CoreGraphics
import Foundation
import UIKit

/// 智能构图找到的一个取景。
struct SmartCropItem: Identifiable, Equatable {
    let id = UUID()
    var title: String
    /// 构图手法。
    var how: String
    var why: String
    /// AI 给的框（归一化，左上原点）。
    var original: CGRect
    /// 现在的框（换了比例、手动拖过）。
    var rect: CGRect
}

enum SmartCropRatio: String, CaseIterable, Identifiable {
    case free, original, portrait, landscape, square, wide

    var id: String { rawValue }

    var title: String {
        switch self {
        case .free: return "自由"
        case .original: return "原比例"
        case .portrait: return "竖 4:5"
        case .landscape: return "横 3:2"
        case .square: return "方形"
        case .wide: return "宽 16:9"
        }
    }

    /// 宽 / 高；nil = 不限。
    func value(_ size: CGSize) -> CGFloat? {
        switch self {
        case .free: return nil
        case .original: return size.width / max(size.height, 1)
        case .portrait: return 0.8
        case .landscape: return 1.5
        case .square: return 1
        case .wide: return 16.0 / 9
        }
    }
}

/// 智能构图：让能看图的 AI 从一张大图里找出几个好看的取景。只要坐标，画面从原图上裁，不重画。
enum SmartCrop {
    static func prompt(size: CGSize, minimum: CGFloat, hint: String, again: Bool) -> String {
        let least = Int((minimum * 1000).rounded(.up))
        return """
        你是资深图片编辑，负责从一张高像素照片里找出值得单独成片的取景。这张照片原始大小 \(Int(size.width))×\(Int(size.height)) 像素。
        请找出 6 到 8 个最好的裁切取景，按好看程度从高到低排。要求：
        1. 每一个单独看都是一张成立的好照片：主体清楚，边缘干净，留白合理，视线方向留空，不要切在人的关节、手指、脸或头顶上，不要切断重要的东西。
        2. 彼此差别明显：有大场面，也有中景、特写和不起眼但好看的小局部；横、竖、方都要有；不要只是同一个框大一点小一点。
        3. 善用三分法、对称、引导线、框架、前景、留白、重复、色块、光影对比这些手法。
        4. 每个框的宽和高都不小于 \(least)（按下面的千分坐标），整个框在照片里面。
        5. 最好的那一个不一定是最大的。\(hint.isEmpty ? "" : "\n6. 另外：\(hint)")\(again ? "\n这是第二次找，换一些不常规的角度和局部，不要只给最显眼的。" : "")
        坐标用千分比：照片左上角是 (0,0)，右下角是 (1000,1000)，box 依次是 左、上、右、下。
        只输出 JSON，不要别的字：{"crops":[{"title":"不超过6个字的名字","how":"用了什么构图手法，不超过6个字","why":"好在哪，不超过20个字","box":[左,上,右,下]}]}
        """
    }

    /// 从 AI 的回复里读出取景。坐标不对、太小、和前面几乎一样的不要。
    static func parse(_ text: String, minimum: CGFloat) -> [SmartCropItem] {
        guard let json = jsonObject(in: text) else { return [] }
        var list: [[String: Any]] = []
        if let dict = json as? [String: Any] {
            list = dict["crops"] as? [[String: Any]] ?? dict.values.compactMap { $0 as? [[String: Any]] }.first ?? []
        } else if let array = json as? [[String: Any]] {
            list = array
        }
        var out: [SmartCropItem] = []
        for item in list {
            var box = numbers(item["box"])
            if box.count != 4, let yx = Optional(numbers(item["box_2d"])), yx.count == 4 { box = [yx[1], yx[0], yx[3], yx[2]] }
            guard box.count == 4 else { continue }
            // 有的模型会给 0~1 的小数。
            let k: CGFloat = (box.max() ?? 0) <= 1.001 ? 1 : 1000
            let x0 = min(max(min(box[0], box[2]) / k, 0), 1), x1 = min(max(max(box[0], box[2]) / k, 0), 1)
            let y0 = min(max(min(box[1], box[3]) / k, 0), 1), y1 = min(max(max(box[1], box[3]) / k, 0), 1)
            let rect = CGRect(x: x0, y: y0, width: x1 - x0, height: y1 - y0)
            guard rect.width >= minimum * 0.8, rect.height >= minimum * 0.8, rect.width * rect.height < 0.97,
                  !out.contains(where: { overlap($0.rect, rect) > 0.82 }) else { continue }
            out.append(SmartCropItem(title: short(item["title"], 8, "取景 \(out.count + 1)"), how: short(item["how"], 8, ""),
                                     why: short(item["why"], 40, ""), original: rect, rect: rect))
        }
        return out
    }

    /// 读一组框（找脸用）。
    static func boxes(_ text: String, key: String) -> [CGRect] {
        guard let dict = jsonObject(in: text, start: "{\"\(key)\"") as? [String: Any], let list = dict[key] as? [[String: Any]] else { return [] }
        return list.compactMap { item in
            var b = numbers(item["box"])
            if b.count != 4 {
                let yx = numbers(item["box_2d"])
                guard yx.count == 4 else { return nil }
                b = [yx[1], yx[0], yx[3], yx[2]]
            }
            let k: CGFloat = (b.max() ?? 0) <= 1.001 ? 1 : 1000
            let r = CGRect(x: min(b[0], b[2]) / k, y: min(b[1], b[3]) / k, width: abs(b[2] - b[0]) / k, height: abs(b[3] - b[1]) / k)
                .intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
            return r.isNull || r.width < 0.004 || r.height < 0.004 ? nil : r
        }
    }

    private static func short(_ value: Any?, _ limit: Int, _ fallback: String) -> String {
        let text = (value as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? fallback : String(text.prefix(limit))
    }

    private static func numbers(_ value: Any?) -> [CGFloat] {
        (value as? [Any] ?? []).compactMap { ($0 as? NSNumber).map { CGFloat($0.doubleValue) } ?? ($0 as? String).flatMap { Double($0) }.map { CGFloat($0) } }
    }

    /// 回复里可能夹着思考过程或 ``` 代码块：从后往前找能解析的那一段。
    private static func jsonObject(in text: String, start key: String = "{\"crops\"") -> Any? {
        func parse(_ s: Substring) -> Any? { try? JSONSerialization.jsonObject(with: Data(s.utf8)) }
        if let whole = parse(text[...]) { return whole }
        guard let end = text.lastIndex(of: "}") else { return nil }
        var start = text.range(of: key)?.lowerBound ?? text.firstIndex(of: "{")
        while let s = start, s < end {
            if let found = parse(text[s...end]) { return found }
            start = text[text.index(after: s)...].firstIndex(of: "{")
        }
        return nil
    }

    private static func overlap(_ a: CGRect, _ b: CGRect) -> CGFloat {
        let i = a.intersection(b)
        guard !i.isNull else { return 0 }
        let area = i.width * i.height
        return area / (a.width * a.height + b.width * b.height - area)
    }

    /// 把框改成指定比例：以原来的框为中心，面积差不多，不出照片。
    static func fit(_ rect: CGRect, ratio: CGFloat?, size: CGSize) -> CGRect {
        guard let ratio, size.width > 0, size.height > 0 else { return rect }
        // 归一化坐标里的宽高比。
        let a = ratio * size.height / size.width
        let area = rect.width * rect.height
        var h = (area / a).squareRoot(), w = h * a
        let k = min(1, 1 / w, 1 / h)
        w *= k
        h *= k
        return CGRect(x: min(max(rect.midX - w / 2, 0), 1 - w), y: min(max(rect.midY - h / 2, 0), 1 - h), width: w, height: h)
    }
}

// MARK: - 看图的接口

extension AIClient {
    /// 各家能看图、只回文字的型号，前面的不行就换后面的。查官方文档得到（2026-11-26）。
    /// OpenAI：https://developers.openai.com/api/docs/models/all  Gemini：https://ai.google.dev/gemini-api/docs/models/gemini-3.8-flash
    /// Grok：https://docs.x.ai/developers/models  千问：https://www.alibabacloud.com/help/en/model-studio/vision
    /// 豆包：https://docs.volcengine.com/docs/ark/image-understanding  MiniMax：https://platform.minimax.io/docs/api-reference/text-openai-api
    private static func lookModels(_ endpoint: AIEndpoint) -> [String] {
        switch endpoint.provider {
        case .openai: return ["gpt-6.1-terra", "gpt-6-luna", "gpt-5.4-mini"]
        case .custom: return ["gpt-6.1-terra", "gpt-6-luna", endpoint.model]
        case .gemini: return ["gemini-3.8-flash", "gemini-3.5-flash-lite"]
        case .grok: return ["grok-4.3", "grok-4.7"]
        case .qwen: return ["qwen4-max", "qwen3.7-plus"]
        case .doubao: return ["doubao-seed-2-1-pro-260915"]
        case .minimax: return ["MiniMax-M3.1-Flash", "MiniMax-M3"]
        case .flux: return []
        }
    }

    /// 看一张图，回答文字。
    static func look(_ endpoint: AIEndpoint, prompt: String, jpeg: Data) async throws -> String {
        let models = lookModels(endpoint)
        guard !models.isEmpty else { throw AIError(text: "\(endpoint.provider.shortTitle) 只能画图、不能看图，换一家服务商再试。") }
        var last: Error?
        for model in models {
            do {
                return try await look(endpoint, model: model, prompt: prompt, jpeg: jpeg)
            } catch let error as AIError where error.status == 404 || (error.status == 400 && error.raw.lowercased().contains("model"))
                || (error.status == 403 && error.raw.lowercased().contains("model")) {
                // 这个 Key 用不了这个型号：换下一个（被拒的不计费）。
                last = error
            }
        }
        throw last ?? AIError(text: "没有可用的看图型号。")
    }

    private static func look(_ endpoint: AIEndpoint, model: String, prompt: String, jpeg: Data) async throws -> String {
        if endpoint.provider == .gemini {
            var request = URLRequest(url: try url(endpoint, "/interactions"))
            request.httpMethod = "POST"
            request.setValue(endpoint.key, forHTTPHeaderField: "x-goog-api-key")
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue("2026-05-20", forHTTPHeaderField: "Api-Revision")
            let input: [[String: Any]] = [
                ["type": "text", "text": prompt],
                ["type": "image", "mime_type": "image/jpeg", "data": jpeg.base64EncodedString()],
            ]
            request.httpBody = try JSONSerialization.data(withJSONObject: ["model": model, "input": input])
            let json = try await send(request, provider: .gemini)
            var images: [String] = [], texts: [String] = []
            // 只读输出，不把发出去的指令也读进来。
            collect(json["steps"] ?? json["outputs"] ?? json, images: &images, texts: &texts)
            let usage = json["usage"] as? [String: Any]
            noteLook(endpoint, model: model, input: int(usage?["total_input_tokens"]),
                     output: int(usage?["total_output_tokens"]) + int(usage?["total_thought_tokens"]))
            return (json["output_text"] as? String) ?? texts.joined(separator: "\n")
        }
        var endpoint = endpoint
        // 千问看图走 OpenAI 兼容的地址。
        if endpoint.provider == .qwen { endpoint.baseURL = endpoint.baseURL.replacingOccurrences(of: "/api/v1", with: "/compatible-mode/v1") }
        var image: [String: Any] = ["url": "data:image/jpeg;base64,\(jpeg.base64EncodedString())"]
        if endpoint.provider == .openai || endpoint.provider == .doubao || endpoint.provider == .minimax { image["detail"] = "high" }
        var body: [String: Any] = [
            "model": model,
            "messages": [["role": "user", "content": [["type": "text", "text": prompt], ["type": "image_url", "image_url": image]]]],
        ]
        if endpoint.provider == .openai || endpoint.provider == .minimax { body["reasoning_effort"] = "low" }
        if endpoint.provider == .qwen { body["enable_thinking"] = false }
        func attempt() async throws -> [String: Any] {
            try await send(try jsonRequest(endpoint, "/chat/completions", body: body), provider: endpoint.provider)
        }
        let json: [String: Any]
        do {
            json = try await attempt()
        } catch let error as AIError where error.status == 400 && (error.raw.contains("reasoning") || error.raw.contains("detail") || error.raw.contains("thinking")) {
            // 有的型号不认这几个可选参数：去掉再发一次（被拒的那次不计费）。
            body["reasoning_effort"] = nil
            body["enable_thinking"] = nil
            image["detail"] = nil
            body["messages"] = [["role": "user", "content": [["type": "text", "text": prompt], ["type": "image_url", "image_url": image]]]]
            json = try await attempt()
        }
        let usage = json["usage"] as? [String: Any]
        noteLook(endpoint, model: model, input: int(usage?["prompt_tokens"]), output: int(usage?["completion_tokens"]))
        let message = ((json["choices"] as? [[String: Any]])?.first?["message"]) as? [String: Any]
        if let text = message?["content"] as? String { return text }
        // 有的兼容服务把内容拆成一块块的。
        let parts = (message?["content"] as? [[String: Any]] ?? []).compactMap { $0["text"] as? String }
        guard !parts.isEmpty else { throw AIError(text: "\(endpoint.provider.shortTitle) 没有回答。") }
        return parts.joined()
    }
}
