package com.taoo.xiutu.batch

import android.content.Context
import android.graphics.Bitmap
import android.net.Uri
import android.os.Build
import android.provider.MediaStore
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableFloatStateOf
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableLongStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.compose.runtime.mutableDoubleStateOf
import androidx.exifinterface.media.ExifInterface
import com.taoo.xiutu.ai.AIClient
import com.taoo.xiutu.ai.AIEndpoint
import com.taoo.xiutu.ai.AIError
import com.taoo.xiutu.ai.AIRunner
import com.taoo.xiutu.ai.AISettings
import com.taoo.xiutu.core.Img
import com.taoo.xiutu.core.Saver
import com.taoo.xiutu.editor.SaveOptions
import com.taoo.xiutu.gpu.Gpu
import com.taoo.xiutu.history.HistoryStore
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import java.io.File
import java.io.InputStream

/** 统一风格：一批照片全部参考同一张存好的风格图，AI 一张张给出色彩，套回各自的原图。 */
class BatchStyleModel(private val context: Context) {
    enum class Status { PENDING, RUNNING, DONE, FAILED }

    data class Item(
        val id: Int,
        val name: String,
        val uri: Uri,
        val preview: Bitmap? = null,
        val result: Bitmap? = null,
        /** AI 的色彩换算成的颜色对照表。 */
        val cube: FloatArray? = null,
        val status: Status = Status.PENDING,
        val error: String? = null,
    )

    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)

    var style by mutableStateOf(StyleStore.styles.firstOrNull())
    var items by mutableStateOf<List<Item>>(emptyList())
        private set
    var selected by mutableIntStateOf(-1)
    var running by mutableStateOf(false)
        private set
    var started by mutableLongStateOf(0L)
        private set
    var strength by mutableFloatStateOf(1f)
        private set
    var spent by mutableDoubleStateOf(0.0)
        private set
    var error by mutableStateOf<String?>(null)
    var exporting by mutableStateOf(false)
        private set
    var exported by mutableIntStateOf(0)
        private set
    private var nextId = 0
    private var job: Job? = null

    val current get() = items.firstOrNull { it.id == selected }
    val doneCount get() = items.count { it.status == Status.DONE }
    val remaining get() = items.count { it.status != Status.DONE }
    val runningIndex get() = items.indexOfFirst { it.status == Status.RUNNING }

    private fun update(id: Int, f: (Item) -> Item) {
        items = items.map { if (it.id == id) f(it) else it }
    }

    // MARK: 导入

    fun add(uris: List<Uri>) {
        val have = items.map { it.uri }.toSet()
        val fresh = uris.filter { it !in have }.map { Item(nextId++, "照片 $nextId", it) }
        if (fresh.isEmpty()) return
        items = items + fresh
        if (current == null) selected = fresh.first().id
        scope.launch {
            // 一张张读小图，不把一批大图都放在内存里
            for (item in fresh) {
                val image = withContext(Dispatchers.IO) { Img.decode(context, item.uri, PREVIEW_SIDE) }
                if (image != null) {
                    update(item.id) { it.copy(preview = image) }
                } else {
                    items = items.filter { it.id != item.id }
                    if (selected == item.id) selected = items.firstOrNull()?.id ?: -1
                    error = "有照片打不开，已跳过"
                }
            }
        }
    }

    fun remove(id: Int) {
        if (running) return
        items = items.filter { it.id != id }
        if (selected == id) selected = items.firstOrNull()?.id ?: -1
    }

    // MARK: 生成

    /** 从没做完的第一张接着做。 */
    fun start() = run(items.filter { it.status != Status.DONE }.map { it.id })

    /** 这一张不满意，重做。 */
    fun redo(id: Int) {
        if (!running) run(listOf(id))
    }

    private fun run(ids: List<Int>) {
        if (running || ids.isEmpty()) return
        val picked = style ?: run {
            error = "先选一个风格"
            return
        }
        val base = AISettings.endpoint() ?: run {
            error = "还没有设置 ${AISettings.active.shortTitle} 的 API Key。"
            return
        }
        // 只要色彩，AI 图的清晰度用不上，按标准尺寸要，省钱。
        val endpoint = base.copy(hires = false)
        error = null
        running = true
        items = items.map { if (it.id in ids) it.copy(status = Status.PENDING, error = null) else it }
        job = scope.launch {
            val reference = withContext(Dispatchers.IO) { StyleStore.image(picked) }
            if (reference == null) {
                error = "先选一个风格"
                running = false
                return@launch
            }
            var failures = 0
            for (id in ids) {
                val item = items.firstOrNull { it.id == id } ?: break
                update(id) { it.copy(status = Status.RUNNING) }
                started = System.currentTimeMillis()
                try {
                    val cube = process(item.uri, reference, endpoint)
                    AIClient.takeLastUsage()?.cost?.let { spent += it }
                    update(id) { it.copy(cube = cube, status = Status.DONE) }
                    failures = 0
                    renderPreview(id)
                    selected = id
                } catch (e: CancellationException) {
                    throw e
                } catch (e: Throwable) {
                    val message = (e as? AIError)?.text ?: e.message ?: "请求失败。"
                    update(id) { it.copy(status = Status.FAILED, error = message) }
                    error = "${item.name}：$message"
                    failures++
                    // 连着两张都失败，多半是 Key、余额或网络的问题，先停下。
                    if (failures >= 2) break
                }
            }
            settle()
        }
    }

    /** 没做完的那张恢复成"还没做"；原来做好过的还算做好的。 */
    private fun settle() {
        items = items.map { if (it.status == Status.RUNNING) it.copy(status = if (it.cube == null) Status.PENDING else Status.DONE) else it }
        running = false
    }

    fun stop() {
        job?.cancel()
        job = null
        settle()
    }

    fun dispose() {
        scope.cancel()
    }

    private suspend fun process(uri: Uri, reference: Bitmap, endpoint: AIEndpoint): FloatArray {
        val small = withContext(Dispatchers.IO) { Img.decode(context, uri, 1536) } ?: throw AIError("这张照片打不开。")
        AIClient.takeLastUsage()
        val graded = AIRunner.run(endpoint, PROMPT, small, emptyList(), emptyList(), appendGuidance = false, references = listOf(reference))
        return withContext(Dispatchers.Default) { StyleLUT.fit(small, graded) } ?: throw AIError("AI 的结果用不了，可以重做这一张。")
    }

    // MARK: 预览和导出

    private suspend fun renderPreview(id: Int) {
        val item = items.firstOrNull { it.id == id } ?: return
        val cube = item.cube ?: return
        val preview = item.preview ?: return
        val k = strength
        val image = withContext(Dispatchers.Default) { runCatching { StyleLUT.apply(cube, preview, k) }.getOrNull() } ?: return
        update(id) { it.copy(result = image) }
    }

    private var strengthJob: Job? = null

    /** 强度滑块：先改正在看的这张，松手再改其余的。 */
    fun changeStrength(value: Float) {
        strength = value
        val id = selected
        strengthJob?.cancel()
        strengthJob = scope.launch { renderPreview(id) }
    }

    fun finishStrength() {
        val id = selected
        scope.launch { for (item in items) if (item.status == Status.DONE && item.id != id) renderPreview(item.id) }
    }

    /** 手机：全部存进相册。返回存成了几张。 */
    suspend fun saveAll(): Int {
        if (exporting) return 0
        exporting = true
        exported = 0
        val k = strength
        for (item in items.filter { it.status == Status.DONE }) {
            val cube = item.cube ?: continue
            val ok = withContext(Dispatchers.Default) {
                runCatching {
                    val data = render(item.uri, cube, k) ?: return@runCatching false
                    Saver.saveToGallery(context, data, SaveOptions.Format.JPEG)
                    if (HistoryStore.enabled) HistoryStore.add(context, data, "jpg", "统一风格")
                    true
                }.onFailure { it.printStackTrace() }.getOrDefault(false)
            }
            if (ok) exported++
        }
        exporting = false
        return exported
    }

    /** 原图分辨率的成品，保留相机信息（拍摄时间、机型、光圈、位置……）。 */
    private fun render(uri: Uri, cube: FloatArray, strength: Float): ByteArray? {
        val full = Img.decode(context, uri) ?: return null
        val out = StyleLUT.apply(cube, Img.downscale(full, Gpu.run { Gpu.maxTextureSize }), strength)
        return withExif(Img.jpeg(out, 95), uri, out.width, out.height)
    }

    /** 读原文件：相册里的照片要说明"要原始文件"才给位置信息，没给权限就读普通的那份。 */
    private fun open(uri: Uri): InputStream? {
        if (Build.VERSION.SDK_INT >= 29) {
            runCatching { context.contentResolver.openInputStream(MediaStore.setRequireOriginal(uri)) }.getOrNull()?.let { return it }
        }
        return runCatching { context.contentResolver.openInputStream(uri) }.getOrNull()
    }

    private fun withExif(jpeg: ByteArray, uri: Uri, w: Int, h: Int): ByteArray {
        val old = runCatching { open(uri)?.use { ExifInterface(it) } }.getOrNull() ?: return jpeg
        val tmp = File.createTempFile("batch", ".jpg", context.cacheDir)
        return try {
            tmp.writeBytes(jpeg)
            val exif = ExifInterface(tmp)
            for (tag in TAGS) old.getAttribute(tag)?.let { exif.setAttribute(tag, it) }
            // 画面已经转正了
            exif.setAttribute(ExifInterface.TAG_ORIENTATION, "1")
            exif.setAttribute(ExifInterface.TAG_PIXEL_X_DIMENSION, "$w")
            exif.setAttribute(ExifInterface.TAG_PIXEL_Y_DIMENSION, "$h")
            exif.saveAttributes()
            tmp.readBytes()
        } catch (e: Exception) {
            e.printStackTrace()
            jpeg
        } finally {
            tmp.delete()
        }
    }

    companion object {
        const val PREVIEW_SIDE = 1400

        const val PROMPT = "第一张是要处理的照片，第二张是风格参考。把第一张的色彩、白平衡、曝光、反差、影调和肤色处理成和第二张完全一样的风格，" +
            "像同一台相机、同一套直出设置、同一天连着拍的一组照片：黑位和白位的位置一致，暗部和高光的色彩倾向一致，绿色、蓝色、红色各自的颜色走向一致，饱和度一致，肤色一致。" +
            "自然得像相机直出，不要有后期修过的痕迹，不要加暗角、颗粒、柔光、光斑。\n" +
            "只调整颜色和明暗；不要把第二张里的人、物、背景搬过来，不要移动、裁剪、旋转或改变第一张画面里任何东西的形状和位置，结果要和第一张逐像素对齐。"

        /** 照搬过去的相机信息。 */
        private val TAGS = listOf(
            ExifInterface.TAG_MAKE, ExifInterface.TAG_MODEL, ExifInterface.TAG_SOFTWARE, ExifInterface.TAG_ARTIST, ExifInterface.TAG_COPYRIGHT,
            ExifInterface.TAG_IMAGE_DESCRIPTION, ExifInterface.TAG_DATETIME, ExifInterface.TAG_DATETIME_ORIGINAL, ExifInterface.TAG_DATETIME_DIGITIZED,
            ExifInterface.TAG_OFFSET_TIME, ExifInterface.TAG_OFFSET_TIME_ORIGINAL, ExifInterface.TAG_OFFSET_TIME_DIGITIZED,
            ExifInterface.TAG_SUBSEC_TIME, ExifInterface.TAG_SUBSEC_TIME_ORIGINAL, ExifInterface.TAG_SUBSEC_TIME_DIGITIZED,
            ExifInterface.TAG_EXPOSURE_TIME, ExifInterface.TAG_F_NUMBER, ExifInterface.TAG_EXPOSURE_PROGRAM, ExifInterface.TAG_PHOTOGRAPHIC_SENSITIVITY,
            ExifInterface.TAG_SENSITIVITY_TYPE, ExifInterface.TAG_RECOMMENDED_EXPOSURE_INDEX, ExifInterface.TAG_SHUTTER_SPEED_VALUE,
            ExifInterface.TAG_APERTURE_VALUE, ExifInterface.TAG_BRIGHTNESS_VALUE, ExifInterface.TAG_EXPOSURE_BIAS_VALUE, ExifInterface.TAG_MAX_APERTURE_VALUE,
            ExifInterface.TAG_SUBJECT_DISTANCE, ExifInterface.TAG_METERING_MODE, ExifInterface.TAG_LIGHT_SOURCE, ExifInterface.TAG_FLASH,
            ExifInterface.TAG_FOCAL_LENGTH, ExifInterface.TAG_FOCAL_LENGTH_IN_35MM_FILM, ExifInterface.TAG_SENSING_METHOD, ExifInterface.TAG_SCENE_TYPE,
            ExifInterface.TAG_CUSTOM_RENDERED, ExifInterface.TAG_EXPOSURE_MODE, ExifInterface.TAG_WHITE_BALANCE, ExifInterface.TAG_DIGITAL_ZOOM_RATIO,
            ExifInterface.TAG_SCENE_CAPTURE_TYPE, ExifInterface.TAG_CONTRAST, ExifInterface.TAG_SATURATION, ExifInterface.TAG_SHARPNESS,
            ExifInterface.TAG_SUBJECT_DISTANCE_RANGE, ExifInterface.TAG_LENS_MAKE, ExifInterface.TAG_LENS_MODEL, ExifInterface.TAG_LENS_SPECIFICATION,
            ExifInterface.TAG_LENS_SERIAL_NUMBER, ExifInterface.TAG_BODY_SERIAL_NUMBER, ExifInterface.TAG_CAMERA_OWNER_NAME, ExifInterface.TAG_USER_COMMENT,
            ExifInterface.TAG_GPS_VERSION_ID, ExifInterface.TAG_GPS_LATITUDE, ExifInterface.TAG_GPS_LATITUDE_REF, ExifInterface.TAG_GPS_LONGITUDE,
            ExifInterface.TAG_GPS_LONGITUDE_REF, ExifInterface.TAG_GPS_ALTITUDE, ExifInterface.TAG_GPS_ALTITUDE_REF, ExifInterface.TAG_GPS_TIMESTAMP,
            ExifInterface.TAG_GPS_DATESTAMP, ExifInterface.TAG_GPS_SPEED, ExifInterface.TAG_GPS_SPEED_REF, ExifInterface.TAG_GPS_IMG_DIRECTION,
            ExifInterface.TAG_GPS_IMG_DIRECTION_REF, ExifInterface.TAG_GPS_DEST_BEARING, ExifInterface.TAG_GPS_DEST_BEARING_REF,
            ExifInterface.TAG_GPS_PROCESSING_METHOD, ExifInterface.TAG_GPS_H_POSITIONING_ERROR, ExifInterface.TAG_GPS_DOP,
            ExifInterface.TAG_GPS_SATELLITES, ExifInterface.TAG_GPS_STATUS, ExifInterface.TAG_GPS_MEASURE_MODE, ExifInterface.TAG_GPS_MAP_DATUM,
            ExifInterface.TAG_GPS_TRACK, ExifInterface.TAG_GPS_TRACK_REF,
        )
    }
}
