import Foundation
import ImageIO

/// 发给服务商的一次改图请求。
struct AIPayload {
    let prompt: String
    /// 要改的图。OpenAI 用 PNG（尺寸已经补成接口支持的规格），其他家用 JPEG。
    let image: Data
    let imageMime: String
    /// OpenAI 蒙版：透明的地方 = 允许修改的区域。
    let maskPNG: Data?
    /// 给不支持蒙版的服务商用：同一张图，把要改的区域标红。
    let markedJPEG: Data?
    /// OpenAI 的输出尺寸，例如 "1024x1536"。
    let size: String
    /// 额外的参考图（格式和主图相同），排在主图后面。漫画人生的多张照片用它。
    var extraImages: [Data] = []
}

/// 一次请求的实际用量（来自服务商返回的 usage；按张计费的几家记的是张数）。
struct AIUsage {
    let model: String
    let inputText: Int
    let inputImage: Int
    /// 输出 token 总数。
    let output: Int
    var provider: AIProvider = .openai
    /// output 里属于文字 / 思考的那部分（Gemini 这部分和图片分开计价）。
    var outputText = 0
    /// 生成了几张图、发过去几张图。
    var images = 1
    var inputImages = 0
    /// 单张输出图的像素数（按分辨率分档计价的型号用）。
    var outputPixels = 0
    /// 服务商在返回里直接报出的费用（按它的结算币种）。
    var reportedCost: Double? = nil
    /// 走的是不是海外地域的接口（千问、豆包的价目不同）。
    var overseas = false

    /// 这次请求的估算费用，按这家服务商的结算币种；算不出来是 nil。价目都在 AIPricing 里。
    var amount: Double? { AIPricing.cost(self) }

    /// 美元费用：只有按美元结算的服务商才有。App 里别的地方把它当美元显示和累加。
    var cost: Double? { provider.currency == .usd ? amount : nil }

    var summary: String {
        // 按张计费的几家不报输入 token，直接说张数。
        let input = inputText + inputImage
        var text = input > 0 ? "输入 \(input)、输出 \(output) token" : "\(images) 张图"
        if let amount {
            text += "，约 \(provider.currency.symbol)\(String(format: amount < 0.1 ? "%.3f" : "%.2f", amount))"
        }
        return "本次实际用量：" + text
    }
}

struct AIError: LocalizedError {
    let text: String
    /// HTTP 状态码和服务商的原话，用来判断要不要换个参数重试。
    var status = 0
    var raw = ""
    var errorDescription: String? { text }
}

/// 各家图像接口的调用。请求格式依据官方文档（各自的文档地址写在调用处）；我没有真实 Key，只用本地模拟服务器验证过流程。
enum AIClient {
    private static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 600
        config.timeoutIntervalForResource = 900
        config.waitsForConnectivity = false
        return URLSession(configuration: config)
    }()

    private static let usageLock = NSLock()
    private static var lastUsage: AIUsage?

    /// 取走最近一次成功请求的用量（取完清空）。
    static func takeLastUsage() -> AIUsage? {
        usageLock.lock()
        defer { usageLock.unlock() }
        let u = lastUsage
        lastUsage = nil
        return u
    }

    /// 一次请求成功了：记进各家的累计统计。report = false 时不作为"本次用量"报给界面（服务商什么用量都没返回）。
    private static func finish(_ usage: AIUsage, report: Bool = true) {
        usageLock.lock()
        lastUsage = report ? usage : nil
        usageLock.unlock()
        Task { @MainActor in AISettings.shared.addUsage(usage) }
    }

    /// 看图、只回文字的请求：记用量。
    static func noteLook(_ endpoint: AIEndpoint, model: String, input: Int, output: Int) {
        guard input + output > 0 else { return }
        finish(AIUsage(model: model, inputText: input, inputImage: 0, output: output, provider: endpoint.provider,
                       outputText: output, images: 0))
    }

    /// OpenAI 这一类的 usage：input_tokens / output_tokens，外加 input_tokens_details 里的文字和图片拆分。
    private static func record(_ json: [String: Any], endpoint: AIEndpoint, images: Int = 1) {
        let usage = json["usage"] as? [String: Any]
        let details = usage?["input_tokens_details"] as? [String: Any]
        let input = int(usage?["input_tokens"])
        let image = int(details?["image_tokens"])
        let text = details?["text_tokens"] != nil ? int(details?["text_tokens"]) : max(0, input - image)
        let u = AIUsage(model: endpoint.model, inputText: text, inputImage: image, output: int(usage?["output_tokens"]),
                        provider: endpoint.provider, images: max(images, 1))
        finish(u, report: usage != nil)
    }

    static func int(_ value: Any?) -> Int { (value as? NSNumber)?.intValue ?? 0 }

    private static func double(_ value: Any?) -> Double? { (value as? NSNumber)?.doubleValue }

    static func url(_ endpoint: AIEndpoint, _ path: String) throws -> URL {
        var base = endpoint.baseURL
        while base.hasSuffix("/") { base.removeLast() }
        guard let url = URL(string: base + path), url.scheme != nil else {
            throw AIError(text: "接口地址不正确：\(endpoint.baseURL)")
        }
        return url
    }

    static func jsonRequest(_ endpoint: AIEndpoint, _ path: String, body: [String: Any]) throws -> URLRequest {
        var request = URLRequest(url: try url(endpoint, path))
        request.httpMethod = "POST"
        request.setValue("Bearer \(endpoint.key)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return request
    }

    private static func dataURI(_ data: Data, mime: String) -> String {
        "data:\(mime);base64,\(data.base64EncodedString())"
    }

    /// 图片数据的像素尺寸（只读文件头，不解码整张图）。
    private static func pixelSize(_ data: Data) -> (w: Int, h: Int)? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let w = (props[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue,
              let h = (props[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue, w > 0, h > 0 else { return nil }
        return (w, h)
    }

    /// 按输入图的宽高比，算一个总像素接近 area 的输出尺寸，两边都是 16 的倍数。
    /// 输出和输入比例一致，结果贴回原图时才不会被拉变形。
    private static func fitted(_ image: Data, area: Double) -> (w: Int, h: Int) {
        let size = pixelSize(image) ?? (1024, 1024)
        let ratio = min(max(Double(size.w) / Double(size.h), 1.0 / 8), 8)
        func snap(_ v: Double) -> Int { max(16, Int((v / 16).rounded()) * 16) }
        return (snap((area * ratio).squareRoot()), snap((area / ratio).squareRoot()))
    }

    /// "1024x1536" 这样的尺寸拆成宽和高。
    private static func parse(size: String) -> (w: Int, h: Int)? {
        let parts = size.lowercased().split(separator: "x").compactMap { Int($0) }
        return parts.count == 2 && parts[0] > 0 && parts[1] > 0 ? (parts[0], parts[1]) : nil
    }

    /// 把宽高比归到最接近的一个常见比例上。
    private static func nearestRatio(w: Int, h: Int, among list: [(Int, Int)]) -> String {
        let target = log(Double(w) / Double(max(h, 1)))
        let best = list.min { abs(log(Double($0.0) / Double($0.1)) - target) < abs(log(Double($1.0) / Double($1.1)) - target) } ?? (1, 1)
        return "\(best.0):\(best.1)"
    }

    /// 主图 + 额外参考图 + 标红参考图，按这个顺序排好，最多 limit 张（主图和标红图优先留下）。
    private static func inputs(_ payload: AIPayload, limit: Int) -> [(data: Data, mime: String)] {
        var list: [(data: Data, mime: String)] = [(payload.image, payload.imageMime)]
        let marked = payload.markedJPEG.map { [(data: $0, mime: "image/jpeg")] } ?? []
        let room = max(0, limit - 1 - marked.count)
        list += payload.extraImages.prefix(room).map { (data: $0, mime: payload.imageMime) }
        return list + marked
    }

    /// 是不是海外地域的接口地址（千问新加坡、豆包 BytePlus）。
    private static func overseas(_ endpoint: AIEndpoint) -> Bool { isOverseas(endpoint.baseURL) }

    static func isOverseas(_ baseURL: String) -> Bool {
        let base = baseURL.lowercased()
        return base.contains("-intl") || base.contains("ap-southeast") || base.contains("byteplus")
    }

    // MARK: 测试连接

    /// 测试这家的 Key 和接口地址能不能用，不产生费用。通过就返回可选的型号列表，不通过抛出原因。
    ///
    /// 有"列出型号"接口的几家直接调它。没有的几家（MiniMax、千问、豆包、FLUX）往生成接口发一个空请求：
    /// 没有指令也没有图，什么都生成不了；服务器先验 Key 再验参数，所以报"参数不对"说明 Key 被接受了，
    /// 报鉴权失败就是 Key 不对。这个判断方式是按各家文档里的报错格式写的，没有拿真实 Key 试过。
    static func verify(_ endpoint: AIEndpoint) async throws -> [String] {
        if endpoint.provider.canListModels { return try await listModels(endpoint) }
        var request: URLRequest
        switch endpoint.provider {
        case .flux:
            let model = endpoint.model.isEmpty ? (endpoint.provider.builtinModels.first?.id ?? "") : endpoint.model
            request = URLRequest(url: try url(endpoint, "/" + model))
            request.httpMethod = "POST"
            request.setValue(endpoint.key, forHTTPHeaderField: "x-key")
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = Data("{}".utf8)
        case .qwen:
            request = try jsonRequest(endpoint, "/services/aigc/multimodal-generation/generation", body: [:])
        default:
            request = try jsonRequest(endpoint, "/images/generations", body: [:])
        }
        request.timeoutInterval = 30
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw AIError(text: "连不上服务器：\(error.localizedDescription)")
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        let body = (String(data: data.prefix(800), encoding: .utf8) ?? "").lowercased()
        // MiniMax 有的接口鉴权失败也回 200，错误码放在 base_resp 里（1004、2049 是鉴权类）。
        var denied = status == 401 || status == 403
        if let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
           let base = json["base_resp"] as? [String: Any], let code = base["status_code"] as? Int, [1004, 2049].contains(code) {
            denied = true
        }
        let words = ["api key", "apikey", "api_key", "unauthorized", "unauthenticated", "not authenticated",
                     "authentication", "invalid token", "login fail", "access denied", "鉴权", "认证失败"]
        if denied || words.contains(where: { body.contains($0) }) {
            throw AIError(text: "Key 没有通过验证。请检查 Key，以及接口地址的地域和这个 Key 是不是同一个。", status: status, raw: body)
        }
        if status == 404 { throw AIError(text: "接口地址或型号不对（404）。", status: status, raw: body) }
        if status == 429 { throw AIError(text: "Key 被接受了，但现在被限流或额度不足（429）。", status: status, raw: body) }
        if status == 0 || status >= 500 { throw AIError(text: "服务器出错（\(status)），稍后再试。", status: status, raw: body) }
        return endpoint.provider.builtinModels.map(\.id)
    }

    // MARK: 改图

    static func edit(_ endpoint: AIEndpoint, _ payload: AIPayload) async throws -> Data {
        switch endpoint.provider {
        case .openai, .custom:
            return try await editOpenAI(endpoint, payload)
        case .gemini:
            return try await editGemini(endpoint, payload)
        case .minimax:
            return try await editMiniMax(endpoint, payload)
        case .grok:
            return try await editGrok(endpoint, payload)
        case .qwen:
            return try await runQwen(endpoint, prompt: payload.prompt, images: inputs(payload, limit: 3), size: nil)
        case .doubao:
            return try await runDoubao(endpoint, prompt: payload.prompt, images: inputs(payload, limit: 10), size: nil)
        case .flux:
            return try await runFlux(endpoint, prompt: payload.prompt, images: inputs(payload, limit: 4), size: nil)
        }
    }

    /// POST /images/edits，multipart/form-data，返回 data[0].b64_json。
    private static func editOpenAI(_ endpoint: AIEndpoint, _ payload: AIPayload) async throws -> Data {
        var request = URLRequest(url: try url(endpoint, "/images/edits"))
        request.httpMethod = "POST"
        request.setValue("Bearer \(endpoint.key)", forHTTPHeaderField: "Authorization")
        let boundary = "xiutu-\(UUID().uuidString)"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")

        var body = Data()
        func field(_ name: String, _ value: String) {
            body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n".utf8))
        }
        func file(_ name: String, filename: String, mime: String, _ data: Data) {
            body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"; filename=\"\(filename)\"\r\nContent-Type: \(mime)\r\n\r\n".utf8))
            body.append(data)
            body.append(Data("\r\n".utf8))
        }
        field("model", endpoint.model)
        field("prompt", payload.prompt)
        field("size", payload.size)
        field("n", "1")
        // 明确要不透明的结果，避免带蒙版时返回透明的洞。
        if endpoint.provider == .openai { field("background", "opaque") }
        if endpoint.quality != "auto" { field("quality", endpoint.quality) }
        if endpoint.highFidelity, endpoint.provider == .openai { field("input_fidelity", "high") }
        file("image[]", filename: "image.png", mime: payload.imageMime, payload.image)
        for (index, extra) in payload.extraImages.enumerated() {
            file("image[]", filename: "image\(index + 2).png", mime: payload.imageMime, extra)
        }
        if let mask = payload.maskPNG { file("mask", filename: "mask.png", mime: "image/png", mask) }
        body.append(Data("--\(boundary)--\r\n".utf8))
        request.httpBody = body

        let json = try await send(request, provider: endpoint.provider)
        let data = try await firstImage(json)
        record(json, endpoint: endpoint)
        return data
    }

    /// OpenAI 这一类返回里的第一张图：data[0].b64_json，或者 data[0].url。
    private static func firstImage(_ json: [String: Any]) async throws -> Data {
        guard let first = (json["data"] as? [[String: Any]])?.first else {
            throw AIError(text: "服务商没有返回图片。")
        }
        if let b64 = first["b64_json"] as? String, let data = Data(base64Encoded: b64, options: .ignoreUnknownCharacters) {
            return data
        }
        // 一些兼容服务只给下载地址。
        if let link = first["url"] as? String { return try await download(link) }
        throw AIError(text: "看不懂服务商返回的图片格式。")
    }

    /// 把结果图下载回来。也认 data: 开头的内嵌图。
    private static func download(_ link: String) async throws -> Data {
        if link.hasPrefix("data:"), let comma = link.firstIndex(of: ","),
           let data = Data(base64Encoded: String(link[link.index(after: comma)...]), options: .ignoreUnknownCharacters) {
            return data
        }
        guard let url = URL(string: link), url.scheme == "https" || url.scheme == "http" else {
            throw AIError(text: "看不懂服务商返回的图片地址。")
        }
        do {
            let (data, response) = try await session.data(from: url)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 200
            guard (200..<300).contains(status), !data.isEmpty else {
                throw AIError(text: "结果图下载失败（HTTP \(status)）。", status: status)
            }
            return data
        } catch let error as AIError {
            throw error
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as URLError where error.code == .cancelled {
            throw CancellationError()
        } catch {
            throw AIError(text: "结果图下载失败：\(error.localizedDescription)")
        }
    }

    /// POST /interactions，输入是一组 text / image 内容块，输出在 steps 里的 image 块。
    /// usage 的字段见 https://ai.google.dev/api/interactions-api
    private static func editGemini(_ endpoint: AIEndpoint, _ payload: AIPayload) async throws -> Data {
        var request = URLRequest(url: try url(endpoint, "/interactions"))
        request.httpMethod = "POST"
        request.setValue(endpoint.key, forHTTPHeaderField: "x-goog-api-key")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("2026-05-20", forHTTPHeaderField: "Api-Revision")

        var input: [[String: Any]] = [
            ["type": "image", "mime_type": payload.imageMime, "data": payload.image.base64EncodedString()],
        ]
        for extra in payload.extraImages {
            input.append(["type": "image", "mime_type": payload.imageMime, "data": extra.base64EncodedString()])
        }
        if let marked = payload.markedJPEG {
            input.append(["type": "image", "mime_type": "image/jpeg", "data": marked.base64EncodedString()])
        }
        input.append(["type": "text", "text": payload.prompt])
        request.httpBody = try JSONSerialization.data(withJSONObject: ["model": endpoint.model, "input": input])

        let json = try await send(request, provider: endpoint.provider)
        var images: [String] = []
        var texts: [String] = []
        collect(json, images: &images, texts: &texts)
        if let last = images.last, let data = Data(base64Encoded: last, options: .ignoreUnknownCharacters) {
            recordGemini(json, endpoint: endpoint)
            return data
        }
        let said = texts.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        throw AIError(text: said.isEmpty ? "Gemini 没有返回图片，可能被内容审核拦截了。" : "Gemini 没有返回图片（可能是内容审核，或它认为做不到）。它的回复原文：\(said.prefix(300))")
    }

    /// Gemini 的 usage：total_input_tokens / total_output_tokens / total_thought_tokens，外加按模态的拆分。
    private static func recordGemini(_ json: [String: Any], endpoint: AIEndpoint) {
        let usage = json["usage"] as? [String: Any]
        func tokens(_ key: String, modality: String) -> Int? {
            guard let list = usage?[key] as? [[String: Any]] else { return nil }
            return list.filter { ($0["modality"] as? String) == modality }.reduce(0) { $0 + int($1["tokens"]) }
        }
        let input = int(usage?["total_input_tokens"])
        let output = int(usage?["total_output_tokens"])
        let thought = int(usage?["total_thought_tokens"])
        let inputImage = tokens("input_tokens_by_modality", modality: "image") ?? 0
        // 没给拆分时，输出全当成图片 token。
        let outputImage = tokens("output_tokens_by_modality", modality: "image") ?? output
        let u = AIUsage(model: endpoint.model, inputText: max(0, input - inputImage), inputImage: inputImage,
                        output: output + thought, provider: .gemini,
                        outputText: max(0, output - outputImage) + thought)
        finish(u, report: usage != nil)
    }

    /// 在返回的 JSON 里找出所有图片块和文字块，不依赖具体层级。
    static func collect(_ value: Any, images: inout [String], texts: inout [String]) {
        if let dict = value as? [String: Any] {
            let type = dict["type"] as? String
            if type == "image", let data = dict["data"] as? String {
                images.append(data)
            } else if type == "text", let text = dict["text"] as? String {
                texts.append(text)
            } else if let inline = (dict["inlineData"] ?? dict["inline_data"]) as? [String: Any],
                      let data = inline["data"] as? String {
                images.append(data)
            }
            for (key, child) in dict where key != "data" {
                collect(child, images: &images, texts: &texts)
            }
        } else if let array = value as? [Any] {
            for child in array { collect(child, images: &images, texts: &texts) }
        }
    }

    /// POST /images/edits，JSON，参考图用 data URI，返回 data[0].b64_json。
    /// https://platform.minimax.io/docs/api-reference/image-generation-h3-edits
    private static func editMiniMax(_ endpoint: AIEndpoint, _ payload: AIPayload) async throws -> Data {
        var images: [[String: Any]] = [
            ["image_url": dataURI(payload.image, mime: payload.imageMime)],
        ]
        for extra in payload.extraImages {
            images.append(["image_url": dataURI(extra, mime: payload.imageMime)])
        }
        if let marked = payload.markedJPEG {
            images.append(["image_url": dataURI(marked, mime: "image/jpeg")])
        }
        let body: [String: Any] = [
            "model": endpoint.model,
            "prompt": payload.prompt,
            "images": images,
            "size": "auto",
            "area": "2K",
            "n": 1,
            "response_format": "b64_json",
            "output_format": "jpeg",
        ]
        let json = try await send(try jsonRequest(endpoint, "/images/edits", body: body), provider: endpoint.provider)
        let data = try await miniMaxImage(json)
        record(json, endpoint: endpoint)
        return data
    }

    private static func miniMaxImage(_ json: [String: Any]) async throws -> Data {
        guard let first = (json["data"] as? [[String: Any]])?.first else {
            throw AIError(text: "服务商没有返回图片。")
        }
        if let error = first["error"] as? [String: Any] {
            throw AIError(text: explain(status: 200, message: error["message"] as? String ?? "", code: "\(error["code"] ?? "")", provider: .minimax))
        }
        return try await firstImage(json)
    }

    /// xAI Grok：POST /images/edits，JSON（不是 multipart）。图片放在 image.url 里，可以是 data URI；多张图用 images。
    /// 返回 data[0].b64_json，usage 里的 cost_in_usd_ticks 是这次的实际费用（1 美元 = 10^10 ticks）。
    /// https://docs.x.ai/developers/model-capabilities/images/editing
    /// https://docs.x.ai/developers/rest-api-reference/inference/images
    private static func editGrok(_ endpoint: AIEndpoint, _ payload: AIPayload) async throws -> Data {
        let list = inputs(payload, limit: 3).map { ["url": dataURI($0.data, mime: $0.mime), "type": "image_url"] }
        var body: [String: Any] = [
            "model": endpoint.model,
            "prompt": payload.prompt,
            "n": 1,
            "response_format": "b64_json",
        ]
        if list.count == 1 { body["image"] = list[0] } else { body["images"] = list }

        func attempt(resolution: String?) async throws -> Data {
            var body = body
            if let resolution { body["resolution"] = resolution }
            let json = try await send(try jsonRequest(endpoint, "/images/edits", body: body), provider: .grok)
            let data = try await firstImage(json)
            recordGrok(json, endpoint: endpoint, inputImages: list.count)
            return data
        }
        guard endpoint.hires else { return try await attempt(resolution: nil) }
        do {
            return try await attempt(resolution: "2k")
        } catch let error as AIError where error.status == 400 && error.raw.lowercased().contains("resolution") {
            // 这个型号不出 2k：按默认分辨率再发一次（被拒的那次不计费）。
            return try await attempt(resolution: nil)
        }
    }

    private static func recordGrok(_ json: [String: Any], endpoint: AIEndpoint, inputImages: Int) {
        let usage = json["usage"] as? [String: Any]
        let details = usage?["input_tokens_details"] as? [String: Any]
        let outDetails = usage?["output_tokens_details"] as? [String: Any]
        let input = int(usage?["input_tokens"])
        let image = int(details?["image_tokens"])
        let output = int(usage?["output_tokens"])
        let ticks = double(usage?["cost_in_usd_ticks"])
        let u = AIUsage(model: endpoint.model, inputText: max(0, input - image), inputImage: image, output: output,
                        provider: .grok,
                        outputText: outDetails == nil ? 0 : max(0, output - int(outDetails?["image_tokens"])),
                        images: max((json["data"] as? [Any])?.count ?? 1, 1), inputImages: inputImages,
                        reportedCost: ticks.map { $0 / 10_000_000_000 })
        finish(u)
    }

    /// 通义千问（阿里云百炼 DashScope 同步接口）：POST /services/aigc/multimodal-generation/generation。
    /// 一条 user 消息，content 里是 1–3 张 {"image": data URI} 加一个 {"text": 指令}；不带图就是文生图。
    /// 返回 output.choices[0].message.content[].image（下载地址，24 小时有效）。按张计费，usage 里是张数和尺寸。
    /// https://help.aliyun.com/zh/model-studio/qwen-image-generation-and-editing-api-reference （3.0 / 2.1）
    /// https://help.aliyun.com/zh/model-studio/qwen-image-edit-api （2.0）
    private static func runQwen(_ endpoint: AIEndpoint, prompt: String, images: [(data: Data, mime: String)],
                                size: (w: Int, h: Int)?) async throws -> Data {
        var content: [[String: Any]] = images.map { ["image": dataURI($0.data, mime: $0.mime)] }
        content.append(["text": prompt])
        // 总像素要在 512×512 到 2048×2048 之间。高清时接近上限，否则 1K 左右。
        let target = size ?? images.first.map { fitted($0.data, area: endpoint.hires ? 4_000_000 : 1_050_000) }
        var parameters: [String: Any] = ["n": 1, "watermark": false]
        if let target { parameters["size"] = "\(target.w)*\(target.h)" }
        let body: [String: Any] = [
            "model": endpoint.model,
            "input": ["messages": [["role": "user", "content": content]]],
            "parameters": parameters,
        ]
        let json = try await send(try jsonRequest(endpoint, "/services/aigc/multimodal-generation/generation", body: body),
                                  provider: .qwen)
        let choices = (json["output"] as? [String: Any])?["choices"] as? [[String: Any]] ?? []
        let blocks = (choices.first?["message"] as? [String: Any])?["content"] as? [[String: Any]] ?? []
        guard let link = blocks.compactMap({ $0["image"] as? String }).first else {
            throw AIError(text: "千问没有返回图片。")
        }
        let data = try await download(link)

        let usage = json["usage"] as? [String: Any]
        // 3.0 系列给的是 output_* / input_image_count，2.x 给的是 image_count / width / height。
        let w = int(usage?["output_width"] ?? usage?["width"])
        let h = int(usage?["output_height"] ?? usage?["height"])
        let pixels = w * h > 0 ? w * h : pixelSize(data).map { $0.w * $0.h } ?? 0
        let u = AIUsage(model: endpoint.model, inputText: 0, inputImage: 0, output: 0, provider: .qwen,
                        images: max(int(usage?["output_image_count"] ?? usage?["image_count"]), 1),
                        inputImages: usage?["input_image_count"] != nil ? int(usage?["input_image_count"]) : images.count,
                        outputPixels: pixels, overseas: overseas(endpoint))
        finish(u)
        return data
    }

    /// 豆包 Seedream（火山方舟）：POST /images/generations。带 image（data URI，一张或一组）就是按参考图改，不带就是文生图。
    /// 返回 data[0].b64_json；usage 里有 generated_images / output_tokens。水印默认是开的，要显式关掉。
    /// https://docs.volcengine.com/docs/ark/image-generation-api
    private static func runDoubao(_ endpoint: AIEndpoint, prompt: String, images: [(data: Data, mime: String)],
                                  size: (w: Int, h: Int)?) async throws -> Data {
        // 4.5 和 5.0 lite 最少要 3,686,400 像素；其他型号最少 921,600。高清时统一给 2K 档（约 400 万像素），各型号都收。
        let needsLarge = endpoint.model.contains("seedream-4-5") || endpoint.model.contains("seedream-5-0-lite")
        let area: Double = endpoint.hires || needsLarge ? 4_000_000 : 2_400_000
        let target = size ?? images.first.map { fitted($0.data, area: area) } ?? (2048, 2048)
        var body: [String: Any] = [
            "model": endpoint.model,
            "prompt": prompt,
            "size": "\(target.w)x\(target.h)",
            "response_format": "b64_json",
            "watermark": false,
        ]
        let list = images.map { dataURI($0.data, mime: $0.mime) }
        if list.count == 1 { body["image"] = list[0] } else if list.count > 1 { body["image"] = list }

        let json = try await send(try jsonRequest(endpoint, "/images/generations", body: body), provider: .doubao)
        let first = (json["data"] as? [[String: Any]])?.first
        if let error = first?["error"] as? [String: Any] {
            throw AIError(text: explain(status: 200, message: error["message"] as? String ?? "", code: "\(error["code"] ?? "")", provider: .doubao))
        }
        let data = try await firstImage(json)

        let usage = json["usage"] as? [String: Any]
        let made = parse(size: first?["size"] as? String ?? "") ?? pixelSize(data) ?? target
        let u = AIUsage(model: endpoint.model, inputText: 0, inputImage: 0, output: int(usage?["output_tokens"]),
                        provider: .doubao, images: max(int(usage?["generated_images"]), 1),
                        inputImages: usage?["input_images"] != nil ? int(usage?["input_images"]) : list.count,
                        outputPixels: made.w * made.h, overseas: overseas(endpoint))
        finish(u)
        return data
    }

    /// FLUX（Black Forest Labs）：POST /{型号}，用 x-key 头鉴权，返回 polling_url；之后轮询它，直到 status 是 Ready，
    /// 结果在 result.sample（下载地址，10 分钟内有效）。返回里的 cost 是实际扣的 credit（1 credit = $0.01）。
    /// FLUX 3 用 images 数组（纯 base64），Kontext / FLUX.2 用 input_image、input_image_2……
    /// https://docs.bfl.ml/api-reference/utility/generate-an-image-with-flux-3
    /// https://docs.bfl.ml/kontext/kontext_image_editing
    /// https://docs.bfl.ml/api_integration/integration_guidelines
    private static func runFlux(_ endpoint: AIEndpoint, prompt: String, images: [(data: Data, mime: String)],
                                size: (w: Int, h: Int)?) async throws -> Data {
        let model = endpoint.model
        let encoded = images.map { $0.data.base64EncodedString() }
        var body: [String: Any] = ["prompt": prompt]
        if model.hasPrefix("flux-3") {
            if !encoded.isEmpty { body["images"] = encoded }
            // match_input（只有 flux-3-image 有）：输出和输入图一样大，超过 400 万像素会缩到 400 万。
            if encoded.isEmpty {
                body["resolution"] = "1k"
                if let size { body["aspect_ratio"] = nearestRatio(w: size.w, h: size.h, among: [(1, 1), (4, 3), (3, 4), (3, 2), (2, 3), (16, 9), (9, 16)]) }
            } else if !endpoint.hires {
                body["resolution"] = "1k"
            } else {
                body["resolution"] = model == "flux-3-image" ? "match_input" : "2k"
            }
        } else {
            for (index, image) in encoded.enumerated() {
                body[index == 0 ? "input_image" : "input_image_\(index + 1)"] = image
            }
            body["output_format"] = "jpeg"
            if model.contains("kontext") {
                // Kontext 不传比例就出 1:1，支持 3:7 到 7:3。
                let dims = images.first.flatMap { pixelSize($0.data) } ?? size ?? (1, 1)
                body["aspect_ratio"] = nearestRatio(w: dims.w, h: dims.h, among: [
                    (1, 1), (5, 4), (4, 5), (4, 3), (3, 4), (3, 2), (2, 3), (16, 9), (9, 16), (2, 1), (1, 2), (7, 3), (3, 7),
                ])
            }
        }

        func request(_ url: URL, body: [String: Any]?) throws -> URLRequest {
            var request = URLRequest(url: url)
            request.setValue(endpoint.key, forHTTPHeaderField: "x-key")
            request.setValue("application/json", forHTTPHeaderField: "accept")
            if let body {
                request.httpMethod = "POST"
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                request.httpBody = try JSONSerialization.data(withJSONObject: body)
            }
            return request
        }

        let submitted = try await send(try request(try url(endpoint, "/" + model), body: body), provider: .flux)
        guard let link = submitted["polling_url"] as? String, let poll = URL(string: link), let host = poll.host else {
            throw AIError(text: "FLUX 没有返回查询结果的地址。")
        }
        // Key 只发给和接口地址同一家的主机，不跟着返回里随便给的地址走。
        let base = URL(string: endpoint.baseURL)?.host ?? ""
        guard host == base || (base.hasSuffix("bfl.ai") && host.hasSuffix(".bfl.ai")) else {
            throw AIError(text: "FLUX 返回的查询地址不属于这家服务，已停止。")
        }
        var credits = double(submitted["cost"])
        let deadline = Date().addingTimeInterval(300)
        while true {
            // 被取消时 sleep 会直接抛出 CancellationError。
            try await Task.sleep(nanoseconds: 1_000_000_000)
            let json = try await send(try request(poll, body: nil), provider: .flux)
            let status = json["status"] as? String ?? ""
            switch status {
            case "Ready":
                guard let sample = (json["result"] as? [String: Any])?["sample"] as? String else {
                    throw AIError(text: "FLUX 没有返回图片。")
                }
                if let settled = double(json["cost"]) { credits = settled }
                let data = try await download(sample)
                let made = pixelSize(data)
                finish(AIUsage(model: model, inputText: 0, inputImage: 0, output: 0, provider: .flux,
                               images: 1, inputImages: images.count, outputPixels: (made?.w ?? 0) * (made?.h ?? 0),
                               reportedCost: credits.map { $0 * 0.01 }))
                return data
            case "Pending", "Reasoning", "Generating", "":
                guard Date() < deadline else { throw AIError(text: "等了太久没有结果，请稍后再试。") }
            default:
                // Request Moderated / Content Moderated / Error / Task not found / No Card Generated
                var details = ""
                if let dict = json["details"] as? [String: Any] {
                    if let reasons = dict["Moderation Reasons"] as? [Any] {
                        details = reasons.map { "\($0)" }.joined(separator: ", ")
                    } else if let data = try? JSONSerialization.data(withJSONObject: dict) {
                        details = String(data: data, encoding: .utf8) ?? ""
                    }
                }
                throw AIError(text: explain(status: 200, message: "\(status) \(details)".trimmingCharacters(in: .whitespaces),
                                            code: status.contains("Moderated") ? "moderation" : "task_failed", provider: .flux))
            }
        }
    }

    // MARK: 文生图

    /// 不带输入图，只按文字生成一张图（生成贴纸用）。Gemini 没有单独的文生图接口。
    /// transparent = true 时要一张透明背景的 PNG，只有 OpenAI 认。size 形如 "1024x1024"。
    static func generate(_ endpoint: AIEndpoint, prompt: String, size: String, transparent: Bool) async throws -> Data {
        let wanted = parse(size: size)
        switch endpoint.provider {
        case .gemini:
            throw AIError(text: "\(endpoint.provider.shortTitle) 没有单独的文生图接口。")
        case .openai, .custom:
            // POST /images/generations，JSON，返回 data[0].b64_json。
            var body: [String: Any] = ["model": endpoint.model, "prompt": prompt, "size": size, "n": 1]
            if transparent {
                body["background"] = "transparent"
                body["output_format"] = "png"
            }
            if endpoint.quality != "auto" { body["quality"] = endpoint.quality }
            let json = try await send(try jsonRequest(endpoint, "/images/generations", body: body), provider: endpoint.provider)
            let data = try await firstImage(json)
            record(json, endpoint: endpoint)
            return data
        case .minimax:
            // https://platform.minimax.io/docs/api-reference/image-generation-h3-generations
            let body: [String: Any] = ["model": endpoint.model, "prompt": prompt, "size": size, "n": 1,
                                       "response_format": "b64_json"]
            let json = try await send(try jsonRequest(endpoint, "/images/generations", body: body), provider: .minimax)
            let data = try await miniMaxImage(json)
            record(json, endpoint: endpoint)
            return data
        case .grok:
            // https://docs.x.ai/developers/rest-api-reference/inference/images
            let dims = wanted ?? (1, 1)
            let body: [String: Any] = [
                "model": endpoint.model, "prompt": prompt, "n": 1, "response_format": "b64_json",
                "aspect_ratio": nearestRatio(w: dims.w, h: dims.h, among: [(1, 1), (4, 3), (3, 4), (3, 2), (2, 3), (16, 9), (9, 16)]),
            ]
            let json = try await send(try jsonRequest(endpoint, "/images/generations", body: body), provider: .grok)
            let data = try await firstImage(json)
            recordGrok(json, endpoint: endpoint, inputImages: 0)
            return data
        case .qwen:
            return try await runQwen(endpoint, prompt: prompt, images: [], size: wanted ?? (1024, 1024))
        case .doubao:
            // 文生图也有最小像素的要求：不够的放大到 2K 档。
            var target = wanted ?? (2048, 2048)
            let least = endpoint.model.contains("seedream-4-5") || endpoint.model.contains("seedream-5-0-lite") ? 3_686_400 : 921_600
            if target.w * target.h < least {
                let k = (Double(least) / Double(target.w * target.h)).squareRoot() * 1.07
                target = (Int((Double(target.w) * k / 16).rounded(.up)) * 16, Int((Double(target.h) * k / 16).rounded(.up)) * 16)
            }
            return try await runDoubao(endpoint, prompt: prompt, images: [], size: target)
        case .flux:
            return try await runFlux(endpoint, prompt: prompt, images: [], size: wanted ?? (1024, 1024))
        }
    }

    // MARK: 型号列表

    static func listModels(_ endpoint: AIEndpoint) async throws -> [String] {
        switch endpoint.provider {
        case .openai, .custom:
            var request = URLRequest(url: try url(endpoint, "/models"))
            request.setValue("Bearer \(endpoint.key)", forHTTPHeaderField: "Authorization")
            let json = try await send(request, provider: endpoint.provider)
            let ids = (json["data"] as? [[String: Any]] ?? []).compactMap { $0["id"] as? String }
            let filtered = endpoint.provider == .openai ? ids.filter { $0.contains("image") } : ids
            return filtered.sorted(by: >)
        case .gemini:
            var request = URLRequest(url: try url(endpoint, "/models?pageSize=1000"))
            request.setValue(endpoint.key, forHTTPHeaderField: "x-goog-api-key")
            let json = try await send(request, provider: endpoint.provider)
            let names = (json["models"] as? [[String: Any]] ?? []).compactMap { $0["name"] as? String }
            return names
                .map { $0.hasPrefix("models/") ? String($0.dropFirst(7)) : $0 }
                .filter { $0.contains("image") || $0.contains("banana") }
                .sorted(by: >)
        case .grok:
            // GET /image-generation-models，返回 models[].id。
            // https://docs.x.ai/developers/rest-api-reference/inference/models
            var request = URLRequest(url: try url(endpoint, "/image-generation-models"))
            request.setValue("Bearer \(endpoint.key)", forHTTPHeaderField: "Authorization")
            let json = try await send(request, provider: .grok)
            return (json["models"] as? [[String: Any]] ?? []).compactMap { $0["id"] as? String }.sorted(by: >)
        case .minimax, .qwen, .doubao, .flux:
            return endpoint.provider.builtinModels.map(\.id)
        }
    }

    // MARK: 通用

    static func send(_ request: URLRequest, provider: AIProvider) async throws -> [String: Any] {
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as URLError where error.code == .cancelled {
            throw CancellationError()
        } catch let error as URLError where error.code == .timedOut {
            throw AIError(text: "等了太久没有结果，请稍后再试。")
        } catch {
            throw AIError(text: "连不上服务器：\(error.localizedDescription)")
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        guard (200..<300).contains(status) else {
            // 各家报错的写法不一样：
            // OpenAI / 豆包 / MiniMax：{"error": {"message", "code", "param"}}
            // xAI：{"code": "...", "error": "原因"}        千问：{"code": "...", "message": "..."}
            // FLUX：{"detail": "..."} 或 {"detail": [{"msg": "..."}]}
            let error = json?["error"] as? [String: Any]
            var message = error?["message"] as? String ?? json?["error"] as? String ?? json?["message"] as? String ?? ""
            if message.isEmpty, let detail = json?["detail"] {
                if let list = detail as? [[String: Any]] {
                    message = list.compactMap { $0["msg"] as? String }.joined(separator: "；")
                } else {
                    message = "\(detail)"
                }
            }
            if message.isEmpty { message = String(data: data.prefix(300), encoding: .utf8) ?? "" }
            let code = "\(error?["code"] ?? error?["status"] ?? error?["type"] ?? json?["code"] ?? "")"
            let details = (error?["moderation_details"] ?? json?["moderation_details"]) as? [String: Any]
            throw AIError(text: explain(status: status, message: message, code: code, provider: provider,
                                        param: error?["param"] as? String, moderation: details),
                          status: status, raw: message + " " + (error?["param"] as? String ?? ""))
        }
        guard let json else { throw AIError(text: "服务器返回的内容不是 JSON。") }
        return json
    }

    private static let moderationCategories: [(key: String, name: String)] = [
        ("sexual", "色情或性暗示内容"), ("nud", "裸露内容"), ("minor", "涉及未成年人"), ("violence", "暴力内容"),
        ("self", "自残相关内容"), ("hate", "仇恨内容"), ("harass", "骚扰内容"), ("illicit", "违法内容"),
        ("public", "涉及公众人物"), ("likeness", "真人肖像"), ("copyright", "版权内容"), ("deception", "误导性内容"),
    ]

    /// 把服务商的报错翻成中文原因，英文原话附在最后的小字里。
    private static func explain(status: Int, message: String, code: String, provider: AIProvider,
                                param: String? = nil, moderation: [String: Any]? = nil) -> String {
        let lower = (message + " " + code).lowercased()
        let name = provider.shortTitle
        func has(_ words: String...) -> Bool { words.contains { lower.contains($0) } }
        var reason: String

        // 千问的审核错误码是 DataInspectionFailed / data_inspection_failed，FLUX 的是 Request / Content Moderated。
        if has("moderation", "moderated", "safety", "policy", "sensitive", "prohibited", "inspection", "1026", "1027") {
            reason = "\(name) 的内容审核拒绝了这次请求。"
            if code.contains("1026") { reason += "被拒的是指令文字。" }
            if code.contains("1027") { reason += "被拒的是生成出来的图片。" }
            if has("request moderated") { reason += "被拒的是发过去的图片或指令。" }
            if has("content moderated") { reason += "被拒的是生成出来的图片。" }
            if let stage = moderation?["moderation_stage"] as? String {
                if stage == "input" { reason += "被拒的是发过去的图片或指令。" }
                if stage == "output" { reason += "被拒的是生成出来的图片。" }
            }
            let raw = ((moderation?["categories"] as? [Any])?.map { "\($0)" } ?? []).joined(separator: " ").lowercased() + " " + lower
            let hits = moderationCategories.filter { raw.contains($0.key) }.map(\.name)
            if !hits.isEmpty { reason += "判定类别：\(hits.joined(separator: "、"))。" }
            reason += "可以换个说法、只涂抹要改的局部，或者换一家服务商再试。"
        } else if has("invalid_api_key", "invalidapikey", "incorrect api key", "api key not valid", "invalid api key", "invalid api-key", "not authenticated", "2049") || status == 401 {
            reason = "API Key 不正确，或者已经失效。请到设置里重新粘贴。"
        } else if has("must be verified", "verification", "verify your organization") {
            reason = "这个型号要求先在 \(name) 后台完成账户（组织）认证，认证通过后才能调用。"
        } else if has("insufficient_quota", "billing", "balance", "credit", "quota", "spend_limit", "usage_limit", "arrearage", "overdue", "1008", "2053") || status == 402 {
            reason = "账户余额或额度不足，需要到 \(name) 后台充值或提高限额。"
        } else if has("model_not_found", "modelnotfound", "does not exist", "do not have access", "not found", "unknown model", "2068") || status == 404 {
            reason = "型号不存在，或者你的账户没有权限使用这个型号。请在设置里换一个型号，或检查接口地址。"
        } else if status == 403 || has("permission", "forbidden", "not allowed", "accessdenied", "unsupported_country") {
            reason = "没有权限：这个 Key 不能调用该接口，或者所在地区不被支持。"
        } else if status == 429 || has("rate limit", "rate_limit", "ratelimit", "throttling", "slow_down", "too many requests", "1002") {
            reason = "请求太频繁，被限流了。等一会儿再试。"
        } else if status == 413 || has("too large", "exceeds", "maximum", "file size") {
            reason = "发过去的图片太大，超过了服务商的限制。"
        } else if has("unsupported", "invalid image", "invalid_image", "format", "dimension", "aspect ratio", "size") && status == 400 {
            reason = "图片的格式或尺寸不被这个型号接受。"
        } else if status == 400 || status == 422 || has("invalid", "2013") {
            reason = "请求里有参数不被这个型号接受" + (param.map { "（\($0)）" } ?? "") + "。可以换一个型号试试，或者把下面的原文发给开发者。"
        } else if status >= 500 || has("overloaded", "unavailable", "server_error") {
            reason = "\(name) 的服务器出错或者正忙，不是你的问题。稍后再试。"
        } else if has("task not found") {
            reason = "\(name) 找不到这次任务，可能已经过期。再试一次。"
        } else {
            reason = "\(name) 拒绝了这次请求。"
        }
        let detail = message.trimmingCharacters(in: .whitespacesAndNewlines)
        let tag = status == 200 || status == 0 ? "" : "（HTTP \(status)）"
        return detail.isEmpty ? reason + tag : "\(reason)\(tag)\n原文：\(detail.prefix(240))"
    }
}
