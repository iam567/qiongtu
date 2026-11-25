package com.taoo.xiutu.ai

import android.graphics.BitmapFactory
import android.os.Handler
import android.os.Looper
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.delay
import kotlinx.coroutines.suspendCancellableCoroutine
import kotlinx.coroutines.withContext
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonArray
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.doubleOrNull
import kotlinx.serialization.json.put
import okhttp3.Call
import okhttp3.Callback
import okhttp3.HttpUrl
import okhttp3.HttpUrl.Companion.toHttpUrlOrNull
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.MultipartBody
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.RequestBody.Companion.toRequestBody
import okhttp3.Response
import java.io.IOException
import java.io.InterruptedIOException
import java.util.Base64
import java.util.Locale
import java.util.UUID
import java.util.concurrent.TimeUnit
import kotlin.coroutines.resume
import kotlin.coroutines.resumeWithException
import kotlin.math.abs
import kotlin.math.ceil
import kotlin.math.ln
import kotlin.math.roundToInt
import kotlin.math.sqrt

/** 发给服务商的一次改图请求。 */
data class AIPayload(
    val prompt: String,
    /** 要改的图。OpenAI 用 PNG，其他家用 JPEG。 */
    val image: ByteArray,
    val imageMime: String,
    /** OpenAI 蒙版：透明的地方 = 允许修改的区域。 */
    val maskPNG: ByteArray?,
    /** 给不支持蒙版的服务商用：同一张图，把要改的区域标红。 */
    val markedJPEG: ByteArray?,
    /** 输出尺寸，例如 "1024x1536"。 */
    val size: String,
    /** 额外的参考图。 */
    val extraImages: List<ByteArray> = emptyList(),
)

/** 一次请求的实际用量（来自服务商返回的 usage；按张计费的几家记的是张数）。 */
data class AIUsage(
    val model: String,
    val inputText: Int,
    val inputImage: Int,
    /** 输出 token 总数。 */
    val output: Int,
    val provider: AIProvider = AIProvider.OPENAI,
    /** output 里属于文字 / 思考的那部分（Gemini 这部分和图片分开计价）。 */
    val outputText: Int = 0,
    /** 生成了几张图、发过去几张图。 */
    val images: Int = 1,
    val inputImages: Int = 0,
    /** 单张输出图的像素数（按分辨率分档计价的型号用）。 */
    val outputPixels: Int = 0,
    /** 服务商在返回里直接报出的费用（按它的结算币种）。 */
    val reportedCost: Double? = null,
    /** 走的是不是海外地域的接口（千问、豆包的价目不同）。 */
    val overseas: Boolean = false,
) {
    /** 估算费用，按这家服务商的结算币种；算不出来是 null。 */
    val amount: Double? get() = AIPricing.cost(this)

    /** 美元费用：只有按美元结算的服务商才有。 */
    val cost: Double? get() = if (provider.currency == AICurrency.USD) amount else null

    val summary: String
        get() {
            // 按张计费的几家不报输入 token，直接说张数
            val input = inputText + inputImage
            var text = if (input > 0) "输入 $input、输出 $output token" else "$images 张图"
            amount?.let { a ->
                text += "，约 ${provider.currency.symbol}${String.format(Locale.US, if (a < 0.1) "%.3f" else "%.2f", a)}"
            }
            return "本次实际用量：$text"
        }
}

class AIError(val text: String, val status: Int = 0, val raw: String = "") : Exception(text)

/** 各家图像接口的调用。请求格式和 iOS 版 AIClient.swift 一致。 */
object AIClient {
    private val client: OkHttpClient = OkHttpClient.Builder()
        .connectTimeout(600, TimeUnit.SECONDS)
        .readTimeout(600, TimeUnit.SECONDS)
        .writeTimeout(600, TimeUnit.SECONDS)
        .callTimeout(900, TimeUnit.SECONDS)
        .build()

    /** 测试连接用：30 秒没动静就算失败。 */
    private val probeClient: OkHttpClient = client.newBuilder()
        .connectTimeout(30, TimeUnit.SECONDS)
        .readTimeout(30, TimeUnit.SECONDS)
        .writeTimeout(30, TimeUnit.SECONDS)
        .build()

    private val json = Json { ignoreUnknownKeys = true }
    private val jsonType = "application/json".toMediaType()
    private val mainHandler = Handler(Looper.getMainLooper())

    private val usageLock = Any()
    private var lastUsage: AIUsage? = null

    /** 取走最近一次成功请求的用量（取完清空）。 */
    fun takeLastUsage(): AIUsage? = synchronized(usageLock) {
        val u = lastUsage
        lastUsage = null
        u
    }

    /** 一次请求成功了：记进各家的累计统计。report = false 时不作为"本次用量"报给界面。 */
    private fun finish(usage: AIUsage, report: Boolean = true) {
        synchronized(usageLock) { lastUsage = if (report) usage else null }
        mainHandler.post { AISettings.addUsage(usage) }
    }

    /** 看图、只回文字的请求：记用量。 */
    private fun noteLook(endpoint: AIEndpoint, model: String, input: Int, output: Int) {
        if (input + output <= 0) return
        finish(AIUsage(model, input, 0, output, provider = endpoint.provider, outputText = output, images = 0))
    }

    // JSON 小工具

    private val JsonElement?.obj: JsonObject? get() = this as? JsonObject
    private val JsonElement?.arr: JsonArray? get() = this as? JsonArray
    private val JsonElement?.str: String? get() = (this as? JsonPrimitive)?.takeIf { it.isString }?.content

    private fun int(v: JsonElement?): Int = (v as? JsonPrimitive)?.takeIf { !it.isString }?.doubleOrNull?.toInt() ?: 0
    private fun double(v: JsonElement?): Double? = (v as? JsonPrimitive)?.takeIf { !it.isString }?.doubleOrNull

    /** 和 Swift 的 "\(value)" 一样，把任意值转成文字。 */
    private fun describe(v: JsonElement?): String = when (v) {
        null -> ""
        is JsonNull -> "<null>"
        is JsonPrimitive -> v.content
        else -> v.toString()
    }

    /** 第一个不为 null 的值（相当于 Swift 的 a ?? b ?? c）。 */
    private fun firstOf(vararg values: JsonElement?): JsonElement? = values.firstOrNull { it != null }

    private fun b64(data: ByteArray): String = Base64.getEncoder().encodeToString(data)

    /** 宽松解码 base64：忽略换行等无关字符。 */
    private fun unb64(text: String): ByteArray? =
        runCatching { Base64.getMimeDecoder().decode(text) }.getOrNull()?.takeIf { it.isNotEmpty() }

    private fun dataURI(data: ByteArray, mime: String) = "data:$mime;base64,${b64(data)}"

    /** OpenAI 这一类的 usage：input_tokens / output_tokens，外加 input_tokens_details 里的文字和图片拆分。 */
    private fun record(json: JsonObject, endpoint: AIEndpoint, images: Int = 1) {
        val usage = json["usage"].obj
        val details = usage?.get("input_tokens_details").obj
        val input = int(usage?.get("input_tokens"))
        val image = int(details?.get("image_tokens"))
        val text = if (details?.get("text_tokens") != null) int(details["text_tokens"]) else maxOf(0, input - image)
        val u = AIUsage(endpoint.model, text, image, int(usage?.get("output_tokens")), provider = endpoint.provider, images = maxOf(images, 1))
        finish(u, report = usage != null)
    }

    private fun url(endpoint: AIEndpoint, path: String): HttpUrl {
        val base = endpoint.baseURL.trimEnd('/')
        return (base + path).toHttpUrlOrNull() ?: throw AIError("接口地址不正确：${endpoint.baseURL}")
    }

    /** Key 只能是可见的 ASCII 字符，否则 OkHttp 会在报错里带出头部内容。 */
    private fun checkKey(endpoint: AIEndpoint) {
        if (endpoint.key.any { it.code !in 0x21..0x7e }) throw AIError("API Key 里有无法识别的字符，请到设置里重新粘贴。")
    }

    private fun jsonRequest(endpoint: AIEndpoint, path: String, body: JsonObject): Request {
        checkKey(endpoint)
        return Request.Builder().url(url(endpoint, path))
            .header("Authorization", "Bearer ${endpoint.key}")
            .post(body.toString().toRequestBody(jsonType))
            .build()
    }

    /** 图片数据的像素尺寸（只读文件头，不解码整张图）。 */
    private fun pixelSize(data: ByteArray): Pair<Int, Int>? {
        val o = BitmapFactory.Options().apply { inJustDecodeBounds = true }
        BitmapFactory.decodeByteArray(data, 0, data.size, o)
        return if (o.outWidth > 0 && o.outHeight > 0) o.outWidth to o.outHeight else null
    }

    /** 按输入图的宽高比，算一个总像素接近 area 的输出尺寸，两边都是 16 的倍数。 */
    private fun fitted(image: ByteArray, area: Double): Pair<Int, Int> {
        val size = pixelSize(image) ?: (1024 to 1024)
        val ratio = (size.first.toDouble() / size.second).coerceIn(1.0 / 8, 8.0)
        fun snap(v: Double) = maxOf(16, (v / 16).roundToInt() * 16)
        return snap(sqrt(area * ratio)) to snap(sqrt(area / ratio))
    }

    /** "1024x1536" 这样的尺寸拆成宽和高。 */
    private fun parse(size: String): Pair<Int, Int>? {
        val parts = size.lowercase().split("x").mapNotNull { it.toIntOrNull() }
        return if (parts.size == 2 && parts[0] > 0 && parts[1] > 0) parts[0] to parts[1] else null
    }

    /** 把宽高比归到最接近的一个常见比例上。 */
    private fun nearestRatio(w: Int, h: Int, among: List<Pair<Int, Int>>): String {
        val target = ln(w.toDouble() / maxOf(h, 1))
        val best = among.minByOrNull { abs(ln(it.first.toDouble() / it.second) - target) } ?: (1 to 1)
        return "${best.first}:${best.second}"
    }

    private val commonRatios = listOf(1 to 1, 4 to 3, 3 to 4, 3 to 2, 2 to 3, 16 to 9, 9 to 16)

    private class Input(val data: ByteArray, val mime: String)

    /** 主图 + 额外参考图 + 标红参考图，按这个顺序排好，最多 limit 张（主图和标红图优先留下）。 */
    private fun inputs(payload: AIPayload, limit: Int): List<Input> {
        val list = mutableListOf(Input(payload.image, payload.imageMime))
        val marked = payload.markedJPEG?.let { listOf(Input(it, "image/jpeg")) } ?: emptyList()
        val room = maxOf(0, limit - 1 - marked.size)
        list += payload.extraImages.take(room).map { Input(it, payload.imageMime) }
        return list + marked
    }

    private fun overseas(endpoint: AIEndpoint) = isOverseas(endpoint.baseURL)

    /** 是不是海外地域的接口地址（千问新加坡、豆包 BytePlus）。 */
    fun isOverseas(baseURL: String): Boolean {
        val base = baseURL.lowercase()
        return base.contains("-intl") || base.contains("ap-southeast") || base.contains("byteplus")
    }

    // 网络

    private suspend fun execute(request: Request, http: OkHttpClient): Pair<Int, ByteArray> =
        suspendCancellableCoroutine { cont ->
            val call = http.newCall(request)
            cont.invokeOnCancellation { call.cancel() }
            call.enqueue(object : Callback {
                override fun onFailure(call: Call, e: IOException) {
                    if (cont.isActive) cont.resumeWithException(e)
                }

                override fun onResponse(call: Call, response: Response) {
                    try {
                        val body = response.body?.bytes() ?: ByteArray(0)
                        if (cont.isActive) cont.resume(response.code to body)
                    } catch (e: IOException) {
                        if (cont.isActive) cont.resumeWithException(e)
                    } finally {
                        response.close()
                    }
                }
            })
        }

    private suspend fun transport(request: Request, http: OkHttpClient = client): Pair<Int, ByteArray> = try {
        execute(request, http)
    } catch (e: CancellationException) {
        throw e
    } catch (e: InterruptedIOException) {
        throw AIError("等了太久没有结果，请稍后再试。")
    } catch (e: IOException) {
        throw AIError("连不上服务器：${e.localizedMessage ?: e.javaClass.simpleName}")
    }

    private fun parseObject(data: ByteArray): JsonObject? =
        runCatching { json.parseToJsonElement(String(data, Charsets.UTF_8)) }.getOrNull() as? JsonObject

    // 测试连接

    /**
     * 测试这家的 Key 和接口地址能不能用，不产生费用。通过就返回可选的型号列表，不通过抛出原因。
     * 有"列出型号"接口的几家直接调它；没有的几家往生成接口发一个空请求，按报错判断 Key 有没有被接受。
     */
    suspend fun verify(endpoint: AIEndpoint): List<String> = withContext(Dispatchers.IO) {
        if (endpoint.provider.canListModels) return@withContext listModels(endpoint)
        checkKey(endpoint)
        val request = when (endpoint.provider) {
            AIProvider.FLUX -> {
                val model = endpoint.model.ifEmpty { endpoint.provider.builtinModels.firstOrNull()?.id ?: "" }
                Request.Builder().url(url(endpoint, "/$model"))
                    .header("x-key", endpoint.key)
                    .post("{}".toRequestBody(jsonType))
                    .build()
            }
            AIProvider.QWEN -> jsonRequest(endpoint, "/services/aigc/multimodal-generation/generation", JsonObject(emptyMap()))
            else -> jsonRequest(endpoint, "/images/generations", JsonObject(emptyMap()))
        }
        val (status, data) = try {
            execute(request, probeClient)
        } catch (e: CancellationException) {
            throw e
        } catch (e: IOException) {
            throw AIError("连不上服务器：${e.localizedMessage ?: e.javaClass.simpleName}")
        }
        val body = String(data.copyOf(minOf(data.size, 800)), Charsets.UTF_8).lowercase()
        // MiniMax 有的接口鉴权失败也回 200，错误码放在 base_resp 里（1004、2049 是鉴权类）
        var denied = status == 401 || status == 403
        val code = parseObject(data)?.get("base_resp").obj?.get("status_code")
        if (code != null && int(code) in listOf(1004, 2049) && (code as? JsonPrimitive)?.isString == false) denied = true
        val words = listOf(
            "api key", "apikey", "api_key", "unauthorized", "unauthenticated", "not authenticated",
            "authentication", "invalid token", "login fail", "access denied", "鉴权", "认证失败",
        )
        if (denied || words.any { body.contains(it) }) {
            throw AIError("Key 没有通过验证。请检查 Key，以及接口地址的地域和这个 Key 是不是同一个。", status, body)
        }
        if (status == 404) throw AIError("接口地址或型号不对（404）。", status, body)
        if (status == 429) throw AIError("Key 被接受了，但现在被限流或额度不足（429）。", status, body)
        if (status == 0 || status >= 500) throw AIError("服务器出错（$status），稍后再试。", status, body)
        endpoint.provider.builtinModels.map { it.id }
    }

    // 改图

    /** 改图，返回图片字节。 */
    suspend fun edit(endpoint: AIEndpoint, payload: AIPayload): ByteArray = withContext(Dispatchers.IO) {
        when (endpoint.provider) {
            AIProvider.OPENAI, AIProvider.CUSTOM -> editOpenAI(endpoint, payload)
            AIProvider.GEMINI -> editGemini(endpoint, payload)
            AIProvider.MINIMAX -> editMiniMax(endpoint, payload)
            AIProvider.GROK -> editGrok(endpoint, payload)
            AIProvider.QWEN -> runQwen(endpoint, payload.prompt, inputs(payload, 3), null)
            AIProvider.DOUBAO -> runDoubao(endpoint, payload.prompt, inputs(payload, 10), null)
            AIProvider.FLUX -> runFlux(endpoint, payload.prompt, inputs(payload, 4), null)
        }
    }

    /** POST /images/edits，multipart/form-data，返回 data[0].b64_json。 */
    private suspend fun editOpenAI(endpoint: AIEndpoint, payload: AIPayload): ByteArray {
        checkKey(endpoint)
        val form = MultipartBody.Builder("xiutu-${UUID.randomUUID()}").setType(MultipartBody.FORM)
            .addFormDataPart("model", endpoint.model)
            .addFormDataPart("prompt", payload.prompt)
            .addFormDataPart("size", payload.size)
            .addFormDataPart("n", "1")
        // 明确要不透明的结果，避免带蒙版时返回透明的洞
        if (endpoint.provider == AIProvider.OPENAI) form.addFormDataPart("background", "opaque")
        if (endpoint.quality != "auto") form.addFormDataPart("quality", endpoint.quality)
        if (endpoint.highFidelity && endpoint.provider == AIProvider.OPENAI) form.addFormDataPart("input_fidelity", "high")
        val mime = payload.imageMime.toMediaType()
        form.addFormDataPart("image[]", "image.png", payload.image.toRequestBody(mime))
        payload.extraImages.forEachIndexed { i, extra ->
            form.addFormDataPart("image[]", "image${i + 2}.png", extra.toRequestBody(mime))
        }
        payload.maskPNG?.let { form.addFormDataPart("mask", "mask.png", it.toRequestBody("image/png".toMediaType())) }
        val request = Request.Builder().url(url(endpoint, "/images/edits"))
            .header("Authorization", "Bearer ${endpoint.key}")
            .post(form.build())
            .build()
        val json = send(request, endpoint.provider)
        val data = firstImage(json)
        record(json, endpoint)
        return data
    }

    /** OpenAI 这一类返回里的第一张图：data[0].b64_json，或者 data[0].url。 */
    private suspend fun firstImage(json: JsonObject): ByteArray {
        val first = json["data"].arr?.firstOrNull().obj ?: throw AIError("服务商没有返回图片。")
        first["b64_json"].str?.let { b -> unb64(b)?.let { return it } }
        // 一些兼容服务只给下载地址
        first["url"].str?.let { return download(it) }
        throw AIError("看不懂服务商返回的图片格式。")
    }

    /** 把结果图下载回来。也认 data: 开头的内嵌图。 */
    private suspend fun download(link: String): ByteArray {
        if (link.startsWith("data:")) {
            val comma = link.indexOf(',')
            if (comma >= 0) unb64(link.substring(comma + 1))?.let { return it }
        }
        val u = link.toHttpUrlOrNull() ?: throw AIError("看不懂服务商返回的图片地址。")
        val (status, data) = try {
            execute(Request.Builder().url(u).get().build(), client)
        } catch (e: CancellationException) {
            throw e
        } catch (e: IOException) {
            throw AIError("结果图下载失败：${e.localizedMessage ?: e.javaClass.simpleName}")
        }
        if (status !in 200..299 || data.isEmpty()) throw AIError("结果图下载失败（HTTP $status）。", status)
        return data
    }

    /** Gemini：POST /interactions，输入是一组 text / image 内容块，输出在 steps 里的 image 块。 */
    private suspend fun editGemini(endpoint: AIEndpoint, payload: AIPayload): ByteArray {
        checkKey(endpoint)
        val input = buildJsonArray {
            add(buildJsonObject { put("type", "image"); put("mime_type", payload.imageMime); put("data", b64(payload.image)) })
            for (extra in payload.extraImages) {
                add(buildJsonObject { put("type", "image"); put("mime_type", payload.imageMime); put("data", b64(extra)) })
            }
            payload.markedJPEG?.let { m ->
                add(buildJsonObject { put("type", "image"); put("mime_type", "image/jpeg"); put("data", b64(m)) })
            }
            add(buildJsonObject { put("type", "text"); put("text", payload.prompt) })
        }
        val body = buildJsonObject { put("model", endpoint.model); put("input", input) }
        val request = Request.Builder().url(url(endpoint, "/interactions"))
            .header("x-goog-api-key", endpoint.key)
            .header("Api-Revision", "2026-05-20")
            .post(body.toString().toRequestBody(jsonType))
            .build()
        val json = send(request, endpoint.provider)
        val images = mutableListOf<String>()
        val texts = mutableListOf<String>()
        collect(json, images, texts)
        images.lastOrNull()?.let { unb64(it) }?.let {
            recordGemini(json, endpoint)
            return it
        }
        val said = texts.joinToString(" ").trim()
        throw AIError(
            if (said.isEmpty()) "Gemini 没有返回图片，可能被内容审核拦截了。"
            else "Gemini 没有返回图片（可能是内容审核，或它认为做不到）。它的回复原文：${said.take(300)}"
        )
    }

    /** Gemini 的 usage：total_input_tokens / total_output_tokens / total_thought_tokens，外加按模态的拆分。 */
    private fun recordGemini(json: JsonObject, endpoint: AIEndpoint) {
        val usage = json["usage"].obj
        fun tokens(key: String, modality: String): Int? {
            val list = usage?.get(key).arr ?: return null
            return list.mapNotNull { it.obj }.filter { it["modality"].str == modality }.sumOf { int(it["tokens"]) }
        }
        val input = int(usage?.get("total_input_tokens"))
        val output = int(usage?.get("total_output_tokens"))
        val thought = int(usage?.get("total_thought_tokens"))
        val inputImage = tokens("input_tokens_by_modality", "image") ?: 0
        // 没给拆分时，输出全当成图片 token
        val outputImage = tokens("output_tokens_by_modality", "image") ?: output
        val u = AIUsage(
            endpoint.model, maxOf(0, input - inputImage), inputImage, output + thought, provider = AIProvider.GEMINI,
            outputText = maxOf(0, output - outputImage) + thought,
        )
        finish(u, report = usage != null)
    }

    /** 在返回的 JSON 里找出所有图片块和文字块，不依赖具体层级。 */
    private fun collect(value: JsonElement, images: MutableList<String>, texts: MutableList<String>) {
        when (value) {
            is JsonObject -> {
                val type = value["type"].str
                val data = value["data"].str
                val text = value["text"].str
                val inline = (value["inlineData"] ?: value["inline_data"]).obj
                if (type == "image" && data != null) images += data
                else if (type == "text" && text != null) texts += text
                else inline?.get("data").str?.let { images += it }
                for ((k, child) in value) if (k != "data") collect(child, images, texts)
            }
            is JsonArray -> value.forEach { collect(it, images, texts) }
            else -> {}
        }
    }

    /** MiniMax：POST /images/edits，JSON，参考图用 data URI，返回 data[0].b64_json。 */
    private suspend fun editMiniMax(endpoint: AIEndpoint, payload: AIPayload): ByteArray {
        val images = buildJsonArray {
            add(buildJsonObject { put("image_url", dataURI(payload.image, payload.imageMime)) })
            for (extra in payload.extraImages) add(buildJsonObject { put("image_url", dataURI(extra, payload.imageMime)) })
            payload.markedJPEG?.let { m -> add(buildJsonObject { put("image_url", dataURI(m, "image/jpeg")) }) }
        }
        val body = buildJsonObject {
            put("model", endpoint.model)
            put("prompt", payload.prompt)
            put("images", images)
            put("size", "auto")
            put("area", "2K")
            put("n", 1)
            put("response_format", "b64_json")
            put("output_format", "jpeg")
        }
        val json = send(jsonRequest(endpoint, "/images/edits", body), endpoint.provider)
        val data = miniMaxImage(json)
        record(json, endpoint)
        return data
    }

    private suspend fun miniMaxImage(json: JsonObject): ByteArray {
        val first = json["data"].arr?.firstOrNull().obj ?: throw AIError("服务商没有返回图片。")
        first["error"].obj?.let { e ->
            throw AIError(explain(200, e["message"].str ?: "", describe(e["code"]), AIProvider.MINIMAX))
        }
        return firstImage(json)
    }

    /** xAI Grok：POST /images/edits，JSON。图片放在 image.url 里（data URI）；多张图用 images。 */
    private suspend fun editGrok(endpoint: AIEndpoint, payload: AIPayload): ByteArray {
        val list = inputs(payload, 3).map { buildJsonObject { put("url", dataURI(it.data, it.mime)); put("type", "image_url") } }
        val base = buildMap<String, JsonElement> {
            put("model", JsonPrimitive(endpoint.model))
            put("prompt", JsonPrimitive(payload.prompt))
            put("n", JsonPrimitive(1))
            put("response_format", JsonPrimitive("b64_json"))
            if (list.size == 1) put("image", list[0]) else put("images", JsonArray(list))
        }

        suspend fun attempt(resolution: String?): ByteArray {
            val body = JsonObject(if (resolution != null) base + ("resolution" to JsonPrimitive(resolution)) else base)
            val json = send(jsonRequest(endpoint, "/images/edits", body), AIProvider.GROK)
            val data = firstImage(json)
            recordGrok(json, endpoint, list.size)
            return data
        }
        if (!endpoint.hires) return attempt(null)
        return try {
            attempt("2k")
        } catch (e: AIError) {
            // 这个型号不出 2k：按默认分辨率再发一次（被拒的那次不计费）
            if (e.status == 400 && e.raw.lowercase().contains("resolution")) attempt(null) else throw e
        }
    }

    private fun recordGrok(json: JsonObject, endpoint: AIEndpoint, inputImages: Int) {
        val usage = json["usage"].obj
        val details = usage?.get("input_tokens_details").obj
        val outDetails = usage?.get("output_tokens_details").obj
        val input = int(usage?.get("input_tokens"))
        val image = int(details?.get("image_tokens"))
        val output = int(usage?.get("output_tokens"))
        val ticks = double(usage?.get("cost_in_usd_ticks"))
        val u = AIUsage(
            endpoint.model, maxOf(0, input - image), image, output, provider = AIProvider.GROK,
            outputText = if (outDetails == null) 0 else maxOf(0, output - int(outDetails["image_tokens"])),
            images = maxOf(json["data"].arr?.size ?: 1, 1), inputImages = inputImages,
            reportedCost = ticks?.let { it / 10_000_000_000.0 },
        )
        finish(u)
    }

    /**
     * 通义千问（DashScope 同步接口）：POST /services/aigc/multimodal-generation/generation。
     * 返回 output.choices[0].message.content[].image（下载地址）。按张计费。
     */
    private suspend fun runQwen(endpoint: AIEndpoint, prompt: String, images: List<Input>, size: Pair<Int, Int>?): ByteArray {
        val content = buildJsonArray {
            for (img in images) add(buildJsonObject { put("image", dataURI(img.data, img.mime)) })
            add(buildJsonObject { put("text", prompt) })
        }
        // 总像素要在 512×512 到 2048×2048 之间。高清时接近上限，否则 1K 左右
        val target = size ?: images.firstOrNull()?.let { fitted(it.data, if (endpoint.hires) 4_000_000.0 else 1_050_000.0) }
        val parameters = buildJsonObject {
            put("n", 1)
            put("watermark", false)
            if (target != null) put("size", "${target.first}*${target.second}")
        }
        val body = buildJsonObject {
            put("model", endpoint.model)
            put("input", buildJsonObject {
                put("messages", buildJsonArray { add(buildJsonObject { put("role", "user"); put("content", content) }) })
            })
            put("parameters", parameters)
        }
        val json = send(jsonRequest(endpoint, "/services/aigc/multimodal-generation/generation", body), AIProvider.QWEN)
        val choices = json["output"].obj?.get("choices").arr
        val blocks = choices?.firstOrNull().obj?.get("message").obj?.get("content").arr
        val link = blocks?.firstNotNullOfOrNull { it.obj?.get("image").str } ?: throw AIError("千问没有返回图片。")
        val data = download(link)

        val usage = json["usage"].obj
        // 3.0 系列给的是 output_* / input_image_count，2.x 给的是 image_count / width / height
        val w = int(firstOf(usage?.get("output_width"), usage?.get("width")))
        val h = int(firstOf(usage?.get("output_height"), usage?.get("height")))
        val pixels = if (w * h > 0) w * h else pixelSize(data)?.let { it.first * it.second } ?: 0
        val u = AIUsage(
            endpoint.model, 0, 0, 0, provider = AIProvider.QWEN,
            images = maxOf(int(firstOf(usage?.get("output_image_count"), usage?.get("image_count"))), 1),
            inputImages = if (usage?.get("input_image_count") != null) int(usage["input_image_count"]) else images.size,
            outputPixels = pixels, overseas = overseas(endpoint),
        )
        finish(u)
        return data
    }

    /** 豆包 Seedream（火山方舟）：POST /images/generations。带 image 就是按参考图改，不带就是文生图。 */
    private suspend fun runDoubao(endpoint: AIEndpoint, prompt: String, images: List<Input>, size: Pair<Int, Int>?): ByteArray {
        // 4.5 和 5.0 lite 最少要 3,686,400 像素；其他型号最少 921,600。高清时统一给 2K 档
        val needsLarge = endpoint.model.contains("seedream-4-5") || endpoint.model.contains("seedream-5-0-lite")
        val area = if (endpoint.hires || needsLarge) 4_000_000.0 else 2_400_000.0
        val target = size ?: images.firstOrNull()?.let { fitted(it.data, area) } ?: (2048 to 2048)
        val list = images.map { dataURI(it.data, it.mime) }
        val body = buildJsonObject {
            put("model", endpoint.model)
            put("prompt", prompt)
            put("size", "${target.first}x${target.second}")
            put("response_format", "b64_json")
            put("watermark", false)
            if (list.size == 1) put("image", list[0])
            else if (list.size > 1) put("image", JsonArray(list.map { JsonPrimitive(it) }))
        }
        val json = send(jsonRequest(endpoint, "/images/generations", body), AIProvider.DOUBAO)
        val first = json["data"].arr?.firstOrNull().obj
        first?.get("error").obj?.let { e ->
            throw AIError(explain(200, e["message"].str ?: "", describe(e["code"]), AIProvider.DOUBAO))
        }
        val data = firstImage(json)

        val usage = json["usage"].obj
        val made = parse(first?.get("size").str ?: "") ?: pixelSize(data) ?: target
        val u = AIUsage(
            endpoint.model, 0, 0, int(usage?.get("output_tokens")), provider = AIProvider.DOUBAO,
            images = maxOf(int(usage?.get("generated_images")), 1),
            inputImages = if (usage?.get("input_images") != null) int(usage["input_images"]) else list.size,
            outputPixels = made.first * made.second, overseas = overseas(endpoint),
        )
        finish(u)
        return data
    }

    /**
     * FLUX（Black Forest Labs）：POST /{型号}，用 x-key 头鉴权，返回 polling_url；轮询到 status = Ready，
     * 结果在 result.sample（下载地址）。返回里的 cost 是实际扣的 credit（1 credit = $0.01）。
     */
    private suspend fun runFlux(endpoint: AIEndpoint, prompt: String, images: List<Input>, size: Pair<Int, Int>?): ByteArray {
        checkKey(endpoint)
        val model = endpoint.model
        val encoded = images.map { b64(it.data) }
        val body = buildJsonObject {
            put("prompt", prompt)
            if (model.startsWith("flux-3")) {
                if (encoded.isNotEmpty()) put("images", JsonArray(encoded.map { JsonPrimitive(it) }))
                // match_input（只有 flux-3-image 有）：输出和输入图一样大
                if (encoded.isEmpty()) {
                    put("resolution", "1k")
                    if (size != null) put("aspect_ratio", nearestRatio(size.first, size.second, commonRatios))
                } else if (!endpoint.hires) {
                    put("resolution", "1k")
                } else {
                    put("resolution", if (model == "flux-3-image") "match_input" else "2k")
                }
            } else {
                encoded.forEachIndexed { i, img -> put(if (i == 0) "input_image" else "input_image_${i + 1}", img) }
                put("output_format", "jpeg")
                if (model.contains("kontext")) {
                    // Kontext 不传比例就出 1:1，支持 3:7 到 7:3
                    val dims = images.firstOrNull()?.let { pixelSize(it.data) } ?: size ?: (1 to 1)
                    put("aspect_ratio", nearestRatio(dims.first, dims.second, listOf(
                        1 to 1, 5 to 4, 4 to 5, 4 to 3, 3 to 4, 3 to 2, 2 to 3, 16 to 9, 9 to 16, 2 to 1, 1 to 2, 7 to 3, 3 to 7,
                    )))
                }
            }
        }

        fun request(u: HttpUrl, body: JsonObject?): Request {
            val b = Request.Builder().url(u).header("x-key", endpoint.key).header("accept", "application/json")
            if (body != null) b.post(body.toString().toRequestBody(jsonType)) else b.get()
            return b.build()
        }

        val submitted = send(request(url(endpoint, "/$model"), body), AIProvider.FLUX)
        val poll = submitted["polling_url"].str?.toHttpUrlOrNull() ?: throw AIError("FLUX 没有返回查询结果的地址。")
        // Key 只发给和接口地址同一家的主机，不跟着返回里随便给的地址走
        val host = poll.host
        val base = endpoint.baseURL.toHttpUrlOrNull()?.host ?: ""
        if (!(host == base || (base.endsWith("bfl.ai") && host.endsWith(".bfl.ai")))) {
            throw AIError("FLUX 返回的查询地址不属于这家服务，已停止。")
        }
        var credits = double(submitted["cost"])
        val deadline = System.currentTimeMillis() + 300_000
        while (true) {
            // 被取消时 delay 会直接抛出 CancellationException
            delay(1000)
            val json = send(request(poll, null), AIProvider.FLUX)
            when (val status = json["status"].str ?: "") {
                "Ready" -> {
                    val sample = json["result"].obj?.get("sample").str ?: throw AIError("FLUX 没有返回图片。")
                    double(json["cost"])?.let { credits = it }
                    val data = download(sample)
                    val made = pixelSize(data)
                    finish(AIUsage(
                        model, 0, 0, 0, provider = AIProvider.FLUX, images = 1, inputImages = images.size,
                        outputPixels = (made?.first ?: 0) * (made?.second ?: 0), reportedCost = credits?.let { it * 0.01 },
                    ))
                    return data
                }
                "Pending", "Reasoning", "Generating", "" -> {
                    if (System.currentTimeMillis() >= deadline) throw AIError("等了太久没有结果，请稍后再试。")
                }
                else -> {
                    // Request Moderated / Content Moderated / Error / Task not found / No Card Generated
                    var details = ""
                    json["details"].obj?.let { d ->
                        val reasons = d["Moderation Reasons"].arr
                        details = reasons?.joinToString(", ") { describe(it) } ?: d.toString()
                    }
                    throw AIError(explain(200, "$status $details".trim(), if (status.contains("Moderated")) "moderation" else "task_failed", AIProvider.FLUX))
                }
            }
        }
    }

    // 文生图

    /**
     * 不带输入图，只按文字生成一张图（生成贴纸用）。Gemini 没有单独的文生图接口。
     * transparent = true 时要透明背景的 PNG，只有 OpenAI 认。size 形如 "1024x1024"。
     */
    suspend fun generate(endpoint: AIEndpoint, prompt: String, size: String, transparent: Boolean): ByteArray = withContext(Dispatchers.IO) {
        val wanted = parse(size)
        when (endpoint.provider) {
            AIProvider.GEMINI -> throw AIError("${endpoint.provider.shortTitle} 没有单独的文生图接口。")
            AIProvider.OPENAI, AIProvider.CUSTOM -> {
                val body = buildJsonObject {
                    put("model", endpoint.model); put("prompt", prompt); put("size", size); put("n", 1)
                    if (transparent) {
                        put("background", "transparent")
                        put("output_format", "png")
                    }
                    if (endpoint.quality != "auto") put("quality", endpoint.quality)
                }
                val json = send(jsonRequest(endpoint, "/images/generations", body), endpoint.provider)
                val data = firstImage(json)
                record(json, endpoint)
                data
            }
            AIProvider.MINIMAX -> {
                val body = buildJsonObject {
                    put("model", endpoint.model); put("prompt", prompt); put("size", size); put("n", 1)
                    put("response_format", "b64_json")
                }
                val json = send(jsonRequest(endpoint, "/images/generations", body), AIProvider.MINIMAX)
                val data = miniMaxImage(json)
                record(json, endpoint)
                data
            }
            AIProvider.GROK -> {
                val dims = wanted ?: (1 to 1)
                val body = buildJsonObject {
                    put("model", endpoint.model); put("prompt", prompt); put("n", 1); put("response_format", "b64_json")
                    put("aspect_ratio", nearestRatio(dims.first, dims.second, commonRatios))
                }
                val json = send(jsonRequest(endpoint, "/images/generations", body), AIProvider.GROK)
                val data = firstImage(json)
                recordGrok(json, endpoint, 0)
                data
            }
            AIProvider.QWEN -> runQwen(endpoint, prompt, emptyList(), wanted ?: (1024 to 1024))
            AIProvider.DOUBAO -> {
                // 文生图也有最小像素的要求：不够的放大到 2K 档
                var target = wanted ?: (2048 to 2048)
                val least = if (endpoint.model.contains("seedream-4-5") || endpoint.model.contains("seedream-5-0-lite")) 3_686_400 else 921_600
                if (target.first * target.second < least) {
                    val k = sqrt(least.toDouble() / (target.first * target.second)) * 1.07
                    target = ceil(target.first * k / 16).toInt() * 16 to ceil(target.second * k / 16).toInt() * 16
                }
                runDoubao(endpoint, prompt, emptyList(), target)
            }
            AIProvider.FLUX -> runFlux(endpoint, prompt, emptyList(), wanted ?: (1024 to 1024))
        }
    }

    // 型号列表

    suspend fun listModels(endpoint: AIEndpoint): List<String> = withContext(Dispatchers.IO) {
        checkKey(endpoint)
        when (endpoint.provider) {
            AIProvider.OPENAI, AIProvider.CUSTOM -> {
                val request = Request.Builder().url(url(endpoint, "/models")).header("Authorization", "Bearer ${endpoint.key}").build()
                val json = send(request, endpoint.provider)
                val ids = json["data"].arr.orEmpty().mapNotNull { it.obj?.get("id").str }
                val filtered = if (endpoint.provider == AIProvider.OPENAI) ids.filter { it.contains("image") } else ids
                filtered.sortedDescending()
            }
            AIProvider.GEMINI -> {
                val request = Request.Builder().url(url(endpoint, "/models?pageSize=1000")).header("x-goog-api-key", endpoint.key).build()
                val json = send(request, endpoint.provider)
                json["models"].arr.orEmpty().mapNotNull { it.obj?.get("name").str }
                    .map { it.removePrefix("models/") }
                    .filter { it.contains("image") || it.contains("banana") }
                    .sortedDescending()
            }
            AIProvider.GROK -> {
                // GET /image-generation-models，返回 models[].id
                val request = Request.Builder().url(url(endpoint, "/image-generation-models")).header("Authorization", "Bearer ${endpoint.key}").build()
                val json = send(request, AIProvider.GROK)
                json["models"].arr.orEmpty().mapNotNull { it.obj?.get("id").str }.sortedDescending()
            }
            AIProvider.MINIMAX, AIProvider.QWEN, AIProvider.DOUBAO, AIProvider.FLUX -> endpoint.provider.builtinModels.map { it.id }
        }
    }

    // 看图

    /**
     * 各家能看图、只回文字的型号，前面的不行就换后面的。查官方文档得到（2026-11-26），和 iOS 一致。
     */
    private fun lookModels(endpoint: AIEndpoint): List<String> = when (endpoint.provider) {
        AIProvider.OPENAI -> listOf("gpt-6.1-terra", "gpt-6-luna", "gpt-5.4-mini")
        AIProvider.CUSTOM -> listOf("gpt-6.1-terra", "gpt-6-luna", endpoint.model)
        AIProvider.GEMINI -> listOf("gemini-3.8-flash", "gemini-3.5-flash-lite")
        AIProvider.GROK -> listOf("grok-4.3", "grok-4.7")
        AIProvider.QWEN -> listOf("qwen4-max", "qwen3.7-plus")
        AIProvider.DOUBAO -> listOf("doubao-seed-2-1-pro-260915")
        AIProvider.MINIMAX -> listOf("MiniMax-M3.1-Flash", "MiniMax-M3")
        AIProvider.FLUX -> emptyList()
    }

    /** 看一张图，回答文字。 */
    suspend fun look(endpoint: AIEndpoint, prompt: String, jpeg: ByteArray): String = withContext(Dispatchers.IO) {
        val models = lookModels(endpoint)
        if (models.isEmpty()) throw AIError("${endpoint.provider.shortTitle} 只能画图、不能看图，换一家服务商再试。")
        var last: AIError? = null
        for (model in models) {
            try {
                return@withContext look(endpoint, model, prompt, jpeg)
            } catch (e: AIError) {
                // 这个 Key 用不了这个型号：换下一个（被拒的不计费）。
                val aboutModel = e.raw.lowercase().contains("model")
                if (e.status == 404 || ((e.status == 400 || e.status == 403) && aboutModel)) last = e else throw e
            }
        }
        throw last ?: AIError("没有可用的看图型号。")
    }

    private suspend fun look(endpoint0: AIEndpoint, model: String, prompt: String, jpeg: ByteArray): String {
        if (endpoint0.provider == AIProvider.GEMINI) {
            checkKey(endpoint0)
            val input = buildJsonArray {
                add(buildJsonObject { put("type", "text"); put("text", prompt) })
                add(buildJsonObject { put("type", "image"); put("mime_type", "image/jpeg"); put("data", b64(jpeg)) })
            }
            val request = Request.Builder().url(url(endpoint0, "/interactions"))
                .header("x-goog-api-key", endpoint0.key)
                .header("Api-Revision", "2026-05-20")
                .post(buildJsonObject { put("model", model); put("input", input) }.toString().toRequestBody(jsonType))
                .build()
            val json = send(request, AIProvider.GEMINI)
            val images = mutableListOf<String>()
            val texts = mutableListOf<String>()
            // 只读输出，不把发出去的指令也读进来。
            collect(json["steps"] ?: json["outputs"] ?: json, images, texts)
            val usage = json["usage"].obj
            noteLook(
                endpoint0, model, int(usage?.get("total_input_tokens")),
                int(usage?.get("total_output_tokens")) + int(usage?.get("total_thought_tokens")),
            )
            return json["output_text"].str ?: texts.joinToString("\n")
        }
        // 千问看图走 OpenAI 兼容的地址。
        val endpoint = if (endpoint0.provider == AIProvider.QWEN) {
            endpoint0.copy(baseURL = endpoint0.baseURL.replace("/api/v1", "/compatible-mode/v1"))
        } else endpoint0
        fun body(options: Boolean) = buildJsonObject {
            put("model", model)
            put("messages", buildJsonArray {
                add(buildJsonObject {
                    put("role", "user")
                    put("content", buildJsonArray {
                        add(buildJsonObject { put("type", "text"); put("text", prompt) })
                        add(buildJsonObject {
                            put("type", "image_url")
                            put("image_url", buildJsonObject {
                                put("url", dataURI(jpeg, "image/jpeg"))
                                if (options && endpoint.provider in listOf(AIProvider.OPENAI, AIProvider.DOUBAO, AIProvider.MINIMAX)) put("detail", "high")
                            })
                        })
                    })
                })
            })
            if (options) {
                if (endpoint.provider == AIProvider.OPENAI || endpoint.provider == AIProvider.MINIMAX) put("reasoning_effort", "low")
                if (endpoint.provider == AIProvider.QWEN) put("enable_thinking", false)
            }
        }
        suspend fun attempt(options: Boolean) = send(jsonRequest(endpoint, "/chat/completions", body(options)), endpoint.provider)
        val json = try {
            attempt(true)
        } catch (e: AIError) {
            // 有的型号不认这几个可选参数：去掉再发一次（被拒的那次不计费）。
            if (e.status == 400 && listOf("reasoning", "detail", "thinking").any { e.raw.contains(it) }) attempt(false) else throw e
        }
        val usage = json["usage"].obj
        noteLook(endpoint, model, int(usage?.get("prompt_tokens")), int(usage?.get("completion_tokens")))
        val message = json["choices"].arr?.firstOrNull().obj?.get("message").obj
        message?.get("content").str?.let { return it }
        // 有的兼容服务把内容拆成一块块的。
        val parts = message?.get("content").arr.orEmpty().mapNotNull { it.obj?.get("text").str }
        if (parts.isEmpty()) throw AIError("${endpoint.provider.shortTitle} 没有回答。")
        return parts.joinToString("")
    }

    // 通用

    private suspend fun send(request: Request, provider: AIProvider): JsonObject {
        val (status, data) = transport(request)
        val json = parseObject(data)
        if (status !in 200..299) {
            // 各家报错的写法不一样：
            // OpenAI / 豆包 / MiniMax：{"error": {"message", "code", "param"}}
            // xAI：{"code": "...", "error": "原因"}        千问：{"code": "...", "message": "..."}
            // FLUX：{"detail": "..."} 或 {"detail": [{"msg": "..."}]}
            val error = json?.get("error").obj
            var message = error?.get("message").str ?: json?.get("error").str ?: json?.get("message").str ?: ""
            if (message.isEmpty()) {
                val detail = json?.get("detail")
                if (detail != null) {
                    message = (detail as? JsonArray)?.mapNotNull { it.obj?.get("msg").str }?.joinToString("；") ?: describe(detail)
                }
            }
            if (message.isEmpty()) message = String(data.copyOf(minOf(data.size, 300)), Charsets.UTF_8)
            val code = describe(firstOf(error?.get("code"), error?.get("status"), error?.get("type"), json?.get("code")))
            val moderation = (error?.get("moderation_details") ?: json?.get("moderation_details")).obj
            val param = error?.get("param").str
            throw AIError(
                explain(status, message, code, provider, param, moderation),
                status, message + " " + (param ?: ""),
            )
        }
        return json ?: throw AIError("服务器返回的内容不是 JSON。")
    }

    private val moderationCategories = listOf(
        "sexual" to "色情或性暗示内容", "nud" to "裸露内容", "minor" to "涉及未成年人", "violence" to "暴力内容",
        "self" to "自残相关内容", "hate" to "仇恨内容", "harass" to "骚扰内容", "illicit" to "违法内容",
        "public" to "涉及公众人物", "likeness" to "真人肖像", "copyright" to "版权内容", "deception" to "误导性内容",
    )

    /** 把服务商的报错翻成中文原因，英文原话附在最后。 */
    private fun explain(
        status: Int, message: String, code: String, provider: AIProvider,
        param: String? = null, moderation: JsonObject? = null,
    ): String {
        val lower = "$message $code".lowercase()
        val name = provider.shortTitle
        fun has(vararg words: String) = words.any { lower.contains(it) }
        var reason: String

        if (has("moderation", "moderated", "safety", "policy", "sensitive", "prohibited", "inspection", "1026", "1027")) {
            reason = "$name 的内容审核拒绝了这次请求。"
            if (code.contains("1026")) reason += "被拒的是指令文字。"
            if (code.contains("1027")) reason += "被拒的是生成出来的图片。"
            if (has("request moderated")) reason += "被拒的是发过去的图片或指令。"
            if (has("content moderated")) reason += "被拒的是生成出来的图片。"
            when (moderation?.get("moderation_stage").str) {
                "input" -> reason += "被拒的是发过去的图片或指令。"
                "output" -> reason += "被拒的是生成出来的图片。"
            }
            val cats = moderation?.get("categories").arr?.joinToString(" ") { describe(it) } ?: ""
            val raw = cats.lowercase() + " " + lower
            val hits = moderationCategories.filter { raw.contains(it.first) }.map { it.second }
            if (hits.isNotEmpty()) reason += "判定类别：${hits.joinToString("、")}。"
            reason += "可以换个说法、只涂抹要改的局部，或者换一家服务商再试。"
        } else if (has("invalid_api_key", "invalidapikey", "incorrect api key", "api key not valid", "invalid api key", "invalid api-key", "not authenticated", "2049") || status == 401) {
            reason = "API Key 不正确，或者已经失效。请到设置里重新粘贴。"
        } else if (has("must be verified", "verification", "verify your organization")) {
            reason = "这个型号要求先在 $name 后台完成账户（组织）认证，认证通过后才能调用。"
        } else if (has("insufficient_quota", "billing", "balance", "credit", "quota", "spend_limit", "usage_limit", "arrearage", "overdue", "1008", "2053") || status == 402) {
            reason = "账户余额或额度不足，需要到 $name 后台充值或提高限额。"
        } else if (has("model_not_found", "modelnotfound", "does not exist", "do not have access", "not found", "unknown model", "2068") || status == 404) {
            reason = "型号不存在，或者你的账户没有权限使用这个型号。请在设置里换一个型号，或检查接口地址。"
        } else if (status == 403 || has("permission", "forbidden", "not allowed", "accessdenied", "unsupported_country")) {
            reason = "没有权限：这个 Key 不能调用该接口，或者所在地区不被支持。"
        } else if (status == 429 || has("rate limit", "rate_limit", "ratelimit", "throttling", "slow_down", "too many requests", "1002")) {
            reason = "请求太频繁，被限流了。等一会儿再试。"
        } else if (status == 413 || has("too large", "exceeds", "maximum", "file size")) {
            reason = "发过去的图片太大，超过了服务商的限制。"
        } else if (has("unsupported", "invalid image", "invalid_image", "format", "dimension", "aspect ratio", "size") && status == 400) {
            reason = "图片的格式或尺寸不被这个型号接受。"
        } else if (status == 400 || status == 422 || has("invalid", "2013")) {
            reason = "请求里有参数不被这个型号接受" + (param?.let { "（$it）" } ?: "") + "。可以换一个型号试试，或者把下面的原文发给开发者。"
        } else if (status >= 500 || has("overloaded", "unavailable", "server_error")) {
            reason = "$name 的服务器出错或者正忙，不是你的问题。稍后再试。"
        } else if (has("task not found")) {
            reason = "$name 找不到这次任务，可能已经过期。再试一次。"
        } else {
            reason = "$name 拒绝了这次请求。"
        }
        val detail = message.trim()
        val tag = if (status == 200 || status == 0) "" else "（HTTP $status）"
        return if (detail.isEmpty()) reason + tag else "$reason$tag\n原文：${detail.take(240)}"
    }
}
