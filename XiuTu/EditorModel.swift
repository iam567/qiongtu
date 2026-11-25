import CoreImage
import Photos
import SwiftUI
import UIKit

enum CropAspect: String, CaseIterable, Identifiable {
    case free, original, r1x1, r3x4, r4x3, r9x16, r16x9, r2x3, r3x2

    var id: String { rawValue }

    var title: String {
        switch self {
        case .free: return "自由"
        case .original: return "原始"
        case .r1x1: return "1:1"
        case .r3x4: return "3:4"
        case .r4x3: return "4:3"
        case .r9x16: return "9:16"
        case .r16x9: return "16:9"
        case .r2x3: return "2:3"
        case .r3x2: return "3:2"
        }
    }

    /// 宽 / 高。free 和 original 没有固定值。
    var ratio: CGFloat? {
        switch self {
        case .free, .original: return nil
        case .r1x1: return 1
        case .r3x4: return 3.0 / 4
        case .r4x3: return 4.0 / 3
        case .r9x16: return 9.0 / 16
        case .r16x9: return 16.0 / 9
        case .r2x3: return 2.0 / 3
        case .r3x2: return 3.0 / 2
        }
    }
}

/// 编辑器的全部状态。
///
/// 思路：已确认的编辑存成一串和分辨率无关的操作（ops）。
/// 屏幕预览 = 操作作用在缩小的代理图上；保存 = 同一串操作作用在原图上。
/// 所以撤销只是去掉最后一个操作，原图始终不动。
@MainActor
@Observable
final class EditorModel {
    // 状态
    var isLoading = true
    var isBusy = false
    var errorText: String?
    var displayImage: UIImage?
    var comparing = false
    var tool: Tool?
    private(set) var ops: [EditOp] = []
    /// 撤销 / 重做存的是整串操作的快照，所以原地改动历史中间的某一步（比如重新编辑图层）也能撤销。
    private var undoStates: [[EditOp]] = []
    /// 每改动一次编辑步骤就加一，用来判断"保存之后有没有再改过"。
    private(set) var revision = 0
    private var redoStates: [[EditOp]] = []

    // 调色
    var adjust = AdjustParams()
    var adjustGroup: AdjustGroup = .light
    var adjustKey: AdjustKey = .brightness

    // 滤镜
    var lookID: String?
    var lookIntensity: CGFloat = 1
    var lookCategory: LookCategory = .camera
    var lookThumbs: [String: UIImage] = [:]
    var lookThumbOriginal: UIImage?

    // 裁剪
    var crop = CropParams()
    var cropAspect: CropAspect = .free

    // 马赛克
    var mosaic = MosaicParams()
    var mosaicStyle: MosaicStyle = .pixel
    var mosaicStrength: CGFloat = 0.45
    var brushSize: CGFloat = 36
    var erasing = false

    // 文字 / 贴纸
    var overlayItems: [OverlayItem] = []
    var selectedOverlayID: UUID?

    // AI 修图
    var aiGroup: AIPresetGroup = .fix
    var aiPrompt = ""
    var aiStrokes: [MosaicStroke] = []
    var aiBrush: CGFloat = 44
    var aiErasing = false
    var aiRunning = false
    var aiStarted = Date()
    var aiError: String?
    var aiHasResult = false

    var aiStrength: CGFloat = 1
    /// 柔化：压 AI 结果过头的锐化。整张重画的结果默认 30。
    var aiSoften: CGFloat = 0
    /// 同一条指令点了几次"再生成一次"；每次在指令后面加不同的变化要求，避免出来的图都一样。
    /// 换衣服：点了哪一款、颜色、裙摆、照着换的图；patch = 涂抹补换没换干净的地方。
    /// 用户点的、AI 指出来的脸（画布大小没变就一直用）。
    @ObservationIgnored var describedFaces: [Int: String] = [:]
    @ObservationIgnored var forcedFaces: [FaceInfo] = []
    @ObservationIgnored var forcedFacesSize: CGSize?
    var faceRescuing = false
    var faceRescueError: String?
    var outfitPick: Outfit?
    var outfitColor = ""
    var outfitSkirt: OutfitSkirt = .normal
    var outfitReference: UIImage?
    var outfitPatch = false
    var bodyToneState = BodyToneState()
    var smartCropState = SmartCropState()
    @ObservationIgnored var smartCropTask: Task<Void, Never>?
    /// 整张重画时贴回原图的脸：开关，以及这次对上的脸。
    var aiKeepFace = true
    var aiFaces: [FaceKeep] = []
    /// 只在变了的地方用 AI 的像素（美体、去路人）：开关，以及这次能不能用。
    var aiChangedOnly = true
    var aiCanKeepRest = false
    @ObservationIgnored private var aiArea: CGImage?
    @ObservationIgnored private var aiCore: CGImage?
    /// 这次结果是换衣服（结果面板上的说法不一样）。
    var aiResultOutfit = false
    @ObservationIgnored private var aiShift: CGVector = .zero
    /// 这条指令只该动身体的哪一块。
    var aiPart: BodyPart?
    @ObservationIgnored private var aiMono = false
    /// 这次先拿下来、出来以后再盖回去的滤镜和调色，以及没盖它们的底图。
    @ObservationIgnored private var aiLift: [EditOp] = []
    @ObservationIgnored private var aiBase: CIImage?
    @ObservationIgnored private var aiRegenRound = 0
    @ObservationIgnored private var aiLastPrompt = ""
    /// 大师风格：除了色彩，也按大师的习惯重新构图（默认开）。
    var aiMasterCompose = true
    /// 最近点的那个快捷指令的名字（大师构图按名字找取景方式）。
    var aiPresetTitle = ""
    /// 当前结果是图层 AI 融合来的（不能"再生成一次"）。
    private(set) var aiResultFused = false
    /// 当前指令是不是"没涂抹就自动只处理头部"的那一类（修跑焦）。
    var aiFaceCrop = false
    /// 美发类指令：没涂抹时自动找到人脸，把头和头发这一大块发给 AI（比修跑焦的范围大，长发也能包住）。
    var aiHairCrop = false
    /// 构图时输出的画幅；原比例 = 跟原图一样。
    var aiReframe: AIReframe = .original
    /// 当前这次结果是不是换了画幅。
    private(set) var aiResultReframed = false
    /// 只采用 AI 的光影和颜色、细节保留原图。结果出来后可以在面板上切换，不用重新生成。
    var aiToneOnly = false
    /// 最近一次请求的实际用量说明。
    var aiUsageText: String?
    /// 进 AI 修图 / 美颜时先拿下来的装饰（文字、贴纸、形状、图层）：AI 只处理照片，确认后再放回最上面。
    @ObservationIgnored var liftedFloating: [EditOp] = []
    @ObservationIgnored private var liftedSaved: (CIImage?, UIImage?) = (nil, nil)
    /// 当前这次 AI 是怎么发起的（存进历史，套用步骤时用）。
    @ObservationIgnored var aiPendingRecipe: AIRecipe?
    /// 正在套用别的图的处理步骤：显示的进度，比如"3/7 大师 · 滨田英明"。
    var recipeStatus: String?
    @ObservationIgnored var recipeTask: Task<Void, Never>?

    // 手动美体（液化）
    var liquify = LiquifyParams()
    var liquifyBrush: CGFloat = 70
    var liquifyStrength: CGFloat = 0.6
    var liquifyRestore = false
    /// 固定背景：推的时候只有人变形。
    var liquifyLock = false
    var liquifyLockBusy = false
    var liquifyNote: String?
    @ObservationIgnored private var personMask: CGImage?
    /// 提前补好的"没有人的背景"，实时预览时直接用。
    @ObservationIgnored private var personPlate: CGImage?
    @ObservationIgnored private var liquifyGrid: LiquifyGrid?
    @ObservationIgnored private var liquifyLast: CGPoint?
    @ObservationIgnored private var liquifyRadius: CGFloat = 0
    @ObservationIgnored private var liquifyStroke = 0

    // 涂鸦 / 标记、边框 / 背景、拼图、图层：状态和实现分别在 EditorModel+Doodle / +Frame / +Collage / +Layers 里。
    var doodleState = DoodleState()
    var frameState = FrameState()
    var collageState = CollageState()
    var layerState = LayerState()
    /// 面部重塑：状态和实现在 EditorModel+Reshape 里。
    var reshapeState = ReshapeState()
    /// 美妆、皮肤：状态和实现在 EditorModel+Makeup / +Skin 里。
    var makeupState = MakeupState()
    var skinState = SkinState()
    /// 美体塑形（一键美体、各部位塑形、增高 / 瘦身 / 缩放）：状态和实现在 EditorModel+Shape 里。
    var shapeState = ShapeState()

    /// 滤镜里的"拍立得"：状态和实现在 EditorModel+Instant 里。
    var instantState = InstantState()
    /// 特效：状态和实现在 EditorModel+Effect 里。
    var effectState = EffectState()

    /// 重新打开历史里的某一步来改（装饰类工具）时记下的东西；nil = 这次是新加一步。
    private struct Reopened {
        var prefix: [EditOp]
        var suffix: [EditOp]
        /// 打开之前的底图，取消时换回去。
        var preview: CIImage?
        var image: UIImage?
        /// 打开时文字 / 贴纸原来的样子，用来判断有没有改过。
        var overlay: [OverlayItem] = []
    }
    @ObservationIgnored private var reopened: Reopened?

    /// 大师风格按钮上的缩略图：用当前这张照片在本机模拟出大致的色调。
    var masterThumbs: [String: UIImage] = [:]
    @ObservationIgnored private var masterThumbsStarted = false

    // 美颜
    enum BeautyMode { case ai, manual }
    var beautyMode: BeautyMode = .ai
    var beauty = BeautyParams()
    var beautyKey: BeautyKey = .smooth
    var beautyPreset: String?
    var beautyStyle: String?
    var faces: [FaceInfo] = []
    var faceIndex = 0
    var detectingFaces = false
    /// 画布要放大到的区域（归一化坐标）。
    var focusRect: CGRect?

    // 放大后的高清贴片：只渲染屏幕上看得到的那一块。
    var detailImage: UIImage?
    var detailRect: CGRect?
    @ObservationIgnored private var viewport: CGRect?
    @ObservationIgnored private var viewportPixels: CGFloat = 0
    @ObservationIgnored private var detailTask: Task<Void, Never>?

    @ObservationIgnored private var aiResult: CGImage?
    @ObservationIgnored private var aiTask: Task<Void, Never>?
    @ObservationIgnored private var aiFrame: CGRect?
    @ObservationIgnored private var aiEllipse: CGRect?

    /// 这次进美颜后已经生成过的结果，按"第几张脸 + 风格"记住，再点同一个风格直接切换，不重新调用接口。
    private struct CachedFace {
        let image: CGImage
        let frame: CGRect
        let ellipse: CGRect
    }
    @ObservationIgnored private var faceCache: [String: CachedFace] = [:]
    @ObservationIgnored private var pendingFaceKey: String?
    private(set) var cachedFaceKeys: Set<String> = []

    /// 原图（全分辨率）、编辑用的代理图（长边最多 5120）、当前已确认状态的预览（长边最多 1600）。
    @ObservationIgnored private(set) var source: CIImage?
    @ObservationIgnored private(set) var proxy: CIImage?
    @ObservationIgnored private(set) var basePreview: CIImage?
    @ObservationIgnored private(set) var baseUIImage: UIImage?
    @ObservationIgnored private var originalUIImage: UIImage?
    @ObservationIgnored private var maskSet: MosaicMaskSet?
    @ObservationIgnored private var generation = 0
    /// 草稿箱：这次编辑要不要自动存草稿（单独编辑图层时不存）。
    @ObservationIgnored var draftEnabled = false
    /// 原图文件的数据，写草稿时一起存；nil = 已经写过了或者没有。
    @ObservationIgnored private var draftOriginal: Data?
    @ObservationIgnored private var draftTask: Task<Void, Never>?
    @ObservationIgnored private let live = LiveRenderer()

    var canUndo: Bool { !undoStates.isEmpty && tool == nil }
    var canRedo: Bool { !redoStates.isEmpty && tool == nil }
    /// 有没有能重做的（不管有没有开着工具）。
    var redoAvailable: Bool { !redoStates.isEmpty }
    var hasEdits: Bool { !ops.isEmpty }
    /// 打开之后有没有动过（单独编辑图层内容时，一开始就可能带着已有的步骤）。
    var hasChanges: Bool { !undoStates.isEmpty }

    /// 画布上实际显示的图：按住对比按钮时显示修改前的样子。
    var shownImage: UIImage? {
        guard comparing else { return displayImage }
        return (tool == nil ? originalUIImage : baseUIImage) ?? displayImage
    }

    // MARK: 加载

    func load(assetID: String) async {
        guard let asset = PhotoLibrary.asset(id: assetID),
              let data = await PhotoLibrary.data(for: asset) else {
            errorText = "无法读取这张图片"
            isLoading = false
            return
        }
        await load(data: data)
    }

    /// 从文件打开（RAW 冲洗好的图走这里）。
    func load(fileURL: URL) async {
        guard let data = try? Data(contentsOf: fileURL) else {
            errorText = "无法读取这张图片"
            isLoading = false
            return
        }
        await load(data: data)
    }

    private func load(data: Data) async {
        draftOriginal = data
        let loaded = await Task.detached(priority: .userInitiated) { () -> (CIImage, CIImage, CIImage, UIImage)? in
            guard let full = CIImage(data: data, options: [.applyOrientationProperty: true]) else { return nil }
            guard let proxy = Renderer.shared.rasterize(full, maxDimension: 5120),
                  let preview = Renderer.shared.rasterize(proxy.ci, maxDimension: 1600) else { return nil }
            return (full, proxy.ci, preview.ci, UIImage(cgImage: preview.cg))
        }.value
        guard let loaded else {
            errorText = "这张图片的格式暂不支持"
            isLoading = false
            return
        }
        source = loaded.0
        proxy = loaded.1
        basePreview = loaded.2
        baseUIImage = loaded.3
        originalUIImage = loaded.3
        displayImage = loaded.3
        isLoading = false
    }

    /// 从一张已经在内存里的图开始，并带上已有的修改步骤（单独编辑图层内容时用）。
    func load(image: CIImage, ops initial: [EditOp]) async {
        let loaded = await Task.detached(priority: .userInitiated) { () -> (CIImage, CIImage, UIImage)? in
            guard let proxy = Renderer.shared.rasterize(image, maxDimension: 5120),
                  let preview = Renderer.shared.rasterize(proxy.ci, maxDimension: 1600) else { return nil }
            return (proxy.ci, preview.ci, UIImage(cgImage: preview.cg))
        }.value
        guard let loaded else {
            errorText = "这张图片的格式暂不支持"
            isLoading = false
            return
        }
        source = image
        proxy = loaded.0
        basePreview = loaded.1
        baseUIImage = loaded.2
        originalUIImage = loaded.2
        displayImage = loaded.2
        ops = initial
        isLoading = false
        if !initial.isEmpty { await rebuildBase() }
    }

    func rebuildBase() async {
        guard let proxy else { return }
        let ops = self.ops
        generation += 1
        let gen = generation
        isBusy = true
        let result = await Task.detached(priority: .userInitiated) { () -> (CIImage, UIImage)? in
            let out = EditOp.apply(ops, to: proxy)
            guard let r = Renderer.shared.rasterize(out, maxDimension: 1600) else { return nil }
            return (r.ci, UIImage(cgImage: r.cg))
        }.value
        guard gen == generation else { return }
        if let result {
            basePreview = result.0
            baseUIImage = result.1
            displayImage = result.1
            masterThumbs = [:]
            masterThumbsStarted = false
        }
        isBusy = false
        refreshDetail()
        saveDraft()
    }

    // MARK: 草稿箱

    /// 从草稿接着编辑：原图当底，草稿里的画面作为第一步（撤销一步就回到原图）。
    func loadDraft() async {
        let loaded = await Task.detached(priority: .userInitiated) { DraftStore.shared.load() }.value
        guard let loaded else {
            errorText = "草稿读不出来了"
            isLoading = false
            return
        }
        await load(data: loaded.original)
        guard source != nil else { return }
        // 原图已经在草稿里，不用再写一遍。
        draftOriginal = nil
        recordUndo()
        ops = [.ai(AIEdit(result: loaded.snapshot, strokes: [], reframed: true))]
        await rebuildBase()
    }

    /// 停手一小会儿后，把当前画面（包括还没确认的 AI 结果）存进草稿箱。
    func saveDraft() {
        #if DEBUG
        // 接模拟接口的调试运行不动草稿（和正式版共用一份数据）。
        if ProcessInfo.processInfo.environment["XIUTU_TEST_BASE"] != nil { return }
        #endif
        guard draftEnabled, let proxy else { return }
        var all = ops
        if tool == .ai, let pending = pendingOps() {
            all = aiStack(pending) + liftedFloating
        }
        guard !all.isEmpty else { return }
        let original = draftOriginal
        let token = DraftStore.shared.token
        draftTask?.cancel()
        draftTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 600_000_000)
            guard !Task.isCancelled else { return }
            let wrote = await Task.detached(priority: .utility) { () -> Bool in
                let out = EditOp.apply(all, to: proxy)
                guard let r = Renderer.shared.rasterize(out, maxDimension: 4096) else { return false }
                let quality = CIImageRepresentationOption(rawValue: kCGImageDestinationLossyCompressionQuality as String)
                guard let data = Renderer.shared.context.heifRepresentation(
                    of: r.ci, format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!, options: [quality: 0.9]) else { return false }
                DraftStore.shared.write(original: original, snapshot: data, token: token)
                return true
            }.value
            if wrote, original != nil { self?.draftOriginal = nil }
        }
    }

    /// 正常离开编辑器：不用草稿了。
    func discardDraft() {
        draftTask?.cancel()
        draftTask = nil
        guard draftEnabled else { return }
        DraftStore.shared.clear()
    }

    // MARK: 工具进出

    /// liftDecorations = false：不拿下末尾的装饰（图层融合的结果里已经画进了图层，再拿下放回会画两遍）。
    func begin(_ t: Tool, liftDecorations: Bool = true) {
        guard let base = basePreview, !isBusy else { return }
        comparing = false
        switch t {
        case .adjust:
            adjust = AdjustParams()
            adjustGroup = .light
            adjustKey = .brightness
        case .filter:
            lookID = nil
            lookIntensity = 1
            makeLookThumbs(base)
            beginInstant()
        case .crop:
            crop = CropParams()
            cropAspect = .free
        case .mosaic:
            mosaic = MosaicParams()
            erasing = false
            maskSet = MosaicMaskSet(width: Int(base.extent.width), height: Int(base.extent.height))
        case .text, .sticker, .graphic:
            overlayItems = []
            selectedOverlayID = nil
        case .ai:
            resetAI()
            maskSet = MosaicMaskSet(width: Int(base.extent.width), height: Int(base.extent.height))
        case .liquify:
            liquify = LiquifyParams()
            liquifyRestore = false
            liquifyLock = false
            liquifyLockBusy = false
            liquifyNote = nil
            personMask = nil
            personPlate = nil
            liquifyStroke = 0
            liquifyLast = nil
            liquifyGrid = LiquifyGrid(imageSize: base.extent.size)
        case .doodle, .mark:
            beginDoodle(t)
        case .frame, .backdrop:
            beginFrame(t)
        case .collage:
            beginCollage()
        case .layers:
            beginLayers()
        case .reshape:
            beginReshape()
        case .makeup:
            beginMakeup()
        case .skin:
            beginSkin()
        case .shape:
            beginShape()
        case .smartCrop:
            beginSmartCrop()
        case .bodyTone:
            beginBodyTone()
        case .effect:
            beginEffect()
        case .beauty:
            resetAI()
            beauty = BeautyParams()
            beautyKey = .smooth
            beautyPreset = nil
            beautyStyle = nil
            faces = []
            faceIndex = 0
            focusRect = nil
            faceCache = [:]
            faceStates = [:]
            editedFaces = []
            cachedFaceKeys = []
            pendingFaceKey = nil
            detectFaces()
        }
        tool = t
        refreshDetail()
        if liftDecorations, t == .ai || t == .beauty { liftFloating() }
    }

    /// 进 AI 修图 / 美颜：末尾的装饰先拿下来，底图换成只有照片的样子；确认后装饰放回最上面。
    private func liftFloating() {
        let split = EditOp.splitFloating(ops)
        guard !split.floating.isEmpty, reopened == nil, let proxy else { return }
        liftedFloating = split.floating
        liftedSaved = (basePreview, baseUIImage)
        let photo = split.photo
        Task { [weak self] in
            let r = await Task.detached(priority: .userInitiated) {
                Renderer.shared.rasterize(EditOp.apply(photo, to: proxy), maxDimension: 1600)
            }.value
            guard let self, !self.liftedFloating.isEmpty, let r else { return }
            self.basePreview = r.ci
            self.baseUIImage = UIImage(cgImage: r.cg)
            // 预设的缩略图也换成没有装饰的照片。
            self.masterThumbs = [:]
            self.masterThumbsStarted = false
            if self.tool == .ai { self.prepareMasterThumbs() }
            if self.tool == .ai, self.aiHasResult { self.renderAI() } else { self.displayImage = self.baseUIImage }
        }
    }

    private func resetAI() {
        aiTask?.cancel()
        aiTask = nil
        aiStrokes = []
        aiErasing = false
        aiRunning = false
        aiError = nil
        aiUsageText = nil
        aiResult = nil
        aiHasResult = false
        aiFrame = nil
        aiEllipse = nil
        aiStrength = 1
        aiSoften = 0
        aiResultFused = false
        aiToneOnly = false
        aiPendingRecipe = nil
        aiFaces = []
        aiMono = false
        aiCanKeepRest = false
        aiArea = nil
        aiCore = nil
        aiResultOutfit = false
        outfitPick = nil
        outfitReference = nil
        outfitPatch = false
        aiShift = .zero
        aiLift = []
        aiBase = nil
    }

    /// 图层融合完：结果放进 AI 修图的结果面板，可以调强度和柔化，点 ✓ 才算数。
    func showFusedResult(_ image: CGImage) {
        begin(.ai, liftDecorations: false)
        guard tool == .ai else { return }
        aiResult = image
        aiHasResult = true
        aiResultFused = true
        aiSoften = 0
        renderAI()
    }

    /// 从滤镜里点了一位大师：转到 AI 修图，带上这位大师的指令并直接开始生成。
    func startMaster(_ preset: AIPreset) {
        startAIPreset(preset, group: .master)
    }

    /// 从别的工具（调色、滤镜）里点了一个要用 AI 的功能：
    /// 当前工具里已经调好的先保留成一步，再转到 AI 修图、带上这条指令并直接开始生成。
    func startAIPreset(_ preset: AIPreset, group: AIPresetGroup = .fix) {
        guard !aiRunning, !isBusy else { return }
        commitTool { [self] in
            beginAI(group: group, prompt: preset.prompt)
            guard tool == .ai else { return }
            aiPresetTitle = preset.title
            aiFaceCrop = preset.faceCrop
            aiHairCrop = preset.hairCrop
            aiToneOnly = preset.toneOnly
            aiPart = preset.part
            runAI()
        }
    }

    func pickOutfit(_ outfit: Outfit?) {
        aiError = nil
        outfitPick = outfit
        if let outfit, !outfit.colors.contains(outfitColor) { outfitColor = outfit.colors.first ?? "" }
        if outfit?.skirt != true { outfitSkirt = .normal }
    }

    func runOutfit(prompt: String, title: String) {
        aiError = nil
        aiPrompt = prompt
        aiPresetTitle = title
        aiFaceCrop = false
        aiHairCrop = false
        aiToneOnly = false
        aiPart = nil
        runAI()
    }

    /// 没换干净的地方：涂一下只补那一块。
    func runOutfitPatch() {
        guard aiHasRegion else {
            aiError = "先涂抹没换干净的地方。"
            return
        }
        runOutfit(prompt: OutfitCatalog.patchPrompt, title: "补换")
    }

    /// 结果大体满意、只差一小块：先把结果定下来，再进补换。
    func startOutfitPatch() {
        guard !aiRunning, !isBusy else { return }
        commitTool { [self] in
            beginAI(group: .outfit)
            outfitPatch = tool == .ai
        }
    }

    /// 美体里在"AI 美体"和"手动美体"之间切换。已经做出来的修改先保留成一步，再换过去。
    func switchBody(manual: Bool) {
        guard let t = tool, !aiRunning, !isBusy else { return }
        if manual ? t == .liquify : t == .ai { return }
        commitTool { [self] in
            if manual { begin(.liquify) } else { beginAI(group: .body) }
        }
    }

    /// 直接显示一张已经搭好的预览图（新工具的实时预览用）。
    func showLive(_ image: CIImage) {
        submit(.direct(image))
    }

    /// 大师风格缩略图：第一次需要时在后台算一遍。
    func prepareMasterThumbs() {
        guard !masterThumbsStarted, let base = basePreview else { return }
        masterThumbsStarted = true
        Task.detached(priority: .userInitiated) { [weak self] in
            let small = Renderer.shared.downscaled(Self.centerCrop(base, aspect: 68.0 / 84.0), maxDimension: 260)
            guard let raster = Renderer.shared.rasterize(small, maxDimension: 260) else { return }
            var thumbs: [String: UIImage] = [:]
            for (title, look) in MasterPreview.looks {
                if let cg = Renderer.shared.cgImage(look.apply(to: raster.ci, intensity: 1)) {
                    thumbs[title] = UIImage(cgImage: cg)
                }
            }
            for preset in CreativeKind.all {
                if let out = CreativePreview.render(preset.title, raster.ci), let cg = Renderer.shared.cgImage(out) {
                    thumbs[preset.title] = UIImage(cgImage: cg)
                }
            }
            await self?.setMasterThumbs(thumbs)
        }
    }

    private func setMasterThumbs(_ thumbs: [String: UIImage]) {
        masterThumbs = thumbs
    }

    /// 居中裁成指定的宽高比，原点移回 (0,0)。
    nonisolated static func centerCrop(_ image: CIImage, aspect: CGFloat) -> CIImage {
        let e = image.extent
        var w = e.width, h = e.height
        if w / h > aspect { w = h * aspect } else { h = w / aspect }
        let r = CGRect(x: e.midX - w / 2, y: e.midY - h / 2, width: w, height: h).integral
        return image.cropped(to: r).transformed(by: CGAffineTransform(translationX: -r.minX, y: -r.minY))
    }

    func beginAI(group: AIPresetGroup, prompt: String = "") {
        begin(.ai)
        guard tool == .ai else { return }
        aiGroup = group
        aiPrompt = prompt
        aiReframe = .original
        aiFaceCrop = false
        aiHairCrop = false
        aiToneOnly = false
        aiPart = nil
    }

    func cancelTool() {
        if !liftedFloating.isEmpty {
            liftedFloating = []
            if let preview = liftedSaved.0 { basePreview = preview }
            if let image = liftedSaved.1 { baseUIImage = image }
        }
        if tool == .smartCrop { cancelSmartCrop() }
        resetAI()
        focusRect = nil
        tool = nil
        comparing = false
        maskSet = nil
        if let r = reopened {
            // 刚才是把历史里的一步重新打开在改：底图换回成品的样子。
            reopened = nil
            if let preview = r.preview { basePreview = preview }
            if let image = r.image { baseUIImage = image }
        }
        displayImage = baseUIImage
        refreshDetail()
    }

    // MARK: 重新打开装饰

    private struct ReopenPlan {
        var prefix: [EditOp]
        var suffix: [EditOp]
        var op: EditOp
    }

    /// 再进这个工具时，历史里有没有该接着改的那一步。
    private func reopenPlan(for t: Tool) -> ReopenPlan? {
        // AI 整张重画过之后，前面那些步骤已经画死在结果里，不能再单独改。
        let barrier = ops.lastIndex { $0.bakesInput } ?? -1
        if t == .text || t == .sticker || t == .graphic {
            // 后面没有动过画布大小的文字 / 贴纸：全部拿出来放到最上面一起改，改的时候看到的就是成品的样子。
            let floor = max(barrier, ops.lastIndex { $0.changesCanvas } ?? -1)
            var items: [OverlayItem] = []
            var rest: [EditOp] = []
            for (i, op) in ops.enumerated() {
                if i > floor, case .overlay(let list) = op { items += list } else { rest.append(op) }
            }
            if !items.isEmpty { return ReopenPlan(prefix: rest, suffix: [], op: .overlay(items)) }
        }
        // 其余的回到那一步当时的画面上改，改完后面的步骤照旧套上去。
        guard let i = ops.lastIndex(where: { $0.reopens(with: t) }), i > barrier else { return nil }
        return ReopenPlan(prefix: Array(ops[..<i]), suffix: Array(ops[(i + 1)...]), op: ops[i])
    }

    /// 打开工具。装饰类工具（文字、贴纸、涂鸦、标记、马赛克、边框、背景）如果历史里已经有这一类的步骤，
    /// 就把那一步重新打开接着改，而不是另起一步。ready 在工具真正打开之后调用。
    func open(_ t: Tool, selecting id: UUID? = nil, then ready: (() -> Void)? = nil) {
        guard tool == nil, !isBusy, !isLoading else { return }
        guard let plan = reopenPlan(for: t), let proxy else {
            begin(t)
            ready?()
            return
        }
        isBusy = true
        Task {
            let prefix = plan.prefix
            let result = await Task.detached(priority: .userInitiated) { () -> (CIImage, UIImage)? in
                let out = EditOp.apply(prefix, to: proxy)
                guard let r = Renderer.shared.rasterize(out, maxDimension: 1600) else { return nil }
                return (r.ci, UIImage(cgImage: r.cg))
            }.value
            isBusy = false
            guard tool == nil, let result else { return }
            reopened = Reopened(prefix: plan.prefix, suffix: plan.suffix, preview: basePreview, image: baseUIImage)
            basePreview = result.0
            baseUIImage = result.1
            displayImage = result.1
            begin(t)
            guard tool == t else {
                cancelTool()
                return
            }
            switch plan.op {
            case .overlay(let items):
                overlayItems = items
                reopened?.overlay = items
                selectedOverlayID = id
            case .mosaic(let params):
                mosaic = params
                maskSet?.rebuild(params.strokes)
                renderMosaic()
            case .doodle(let params):
                reopenDoodle(params)
            case .frame(let params):
                reopenFrame(params)
            case .backdrop(let params):
                reopenBackdrop(params)
            case .effect(let params):
                reopenEffect(params)
            default:
                break
            }
            ready?()
        }
    }

    /// 没开工具时点了画面：点中了还能改的文字、贴纸、涂鸦、标记或马赛克，就直接把它打开。
    func tapDecoration(at point: CGPoint) {
        guard tool == nil, !isBusy, let size = baseUIImage?.size, size.width > 0, size.height > 0 else { return }
        // 只有后面没被 AI 重画、画布也没变过的那些，位置才和现在的画面对得上。
        let floor = max(ops.lastIndex { $0.bakesInput } ?? -1, ops.lastIndex { $0.changesCanvas } ?? -1)
        let ratio = size.height / size.width
        // 以画面宽度为单位量距离。
        func local(_ p: CGPoint) -> CGPoint { CGPoint(x: p.x, y: p.y * ratio) }
        let tap = local(point)
        func hits(_ points: [CGPoint], width: CGFloat) -> Bool {
            let reach = max(width * max(1, ratio) / 2, 0.035)
            let list = points.map(local)
            guard let first = list.first else { return false }
            if list.count == 2 {
                // 形状（箭头、方框、圆圈……）：点在它占的那一块里就算。
                let box = CGRect(x: min(list[0].x, list[1].x), y: min(list[0].y, list[1].y),
                                 width: abs(list[0].x - list[1].x), height: abs(list[0].y - list[1].y))
                return box.insetBy(dx: -reach, dy: -reach).contains(tap)
            }
            var previous = first
            for p in list {
                let vx = p.x - previous.x, vy = p.y - previous.y
                let wx = tap.x - previous.x, wy = tap.y - previous.y
                let len = vx * vx + vy * vy
                let t = len > 0 ? min(max((wx * vx + wy * vy) / len, 0), 1) : 0
                if hypot(wx - vx * t, wy - vy * t) <= reach { return true }
                previous = p
            }
            return false
        }
        for i in ops.indices.reversed() where i > floor {
            switch ops[i] {
            case .overlay(let items):
                for item in items.reversed() {
                    guard let r = OverlayRenderer.render(item, imageWidth: 600, maxPixel: 1200) else { continue }
                    let w = r.image.size.width / r.k / 600, h = r.image.size.height / r.k / 600
                    let dx = tap.x - item.center.x, dy = tap.y - item.center.y * ratio
                    let c = cos(item.rotation), s = sin(item.rotation)
                    let lx = dx * c + dy * s, ly = -dx * s + dy * c
                    if abs(lx) <= w / 2 + 0.015, abs(ly) <= h / 2 + 0.015 {
                        open(item.isGraphic ? .graphic : (item.isSticker ? .sticker : .text), selecting: item.id)
                        return
                    }
                }
            case .doodle(let params):
                if let stroke = params.strokes.last(where: { $0.brush != .eraser && hits($0.points, width: $0.width) }) {
                    open(stroke.brush.isShape ? .mark : .doodle)
                    return
                }
            case .mosaic(let params):
                if params.strokes.contains(where: { !$0.erase && hits($0.points, width: $0.width) }) {
                    open(.mosaic)
                    return
                }
            default:
                break
            }
        }
    }

    /// 确认当前工具。next 不为空时，确认完（或者本来就没改什么）接着执行它，用来从一个工具直接换到另一个。
    func commitTool(then next: (() -> Void)? = nil) {
        guard let t = tool else {
            next?()
            return
        }
        var op: EditOp?
        var extra: [EditOp] = []
        switch t {
        case .adjust:
            if !adjust.isIdentity { op = .adjust(adjust) }
        case .filter:
            if let id = lookID, lookIntensity > 0 {
                op = .look(id: id, intensity: lookIntensity)
            } else {
                op = instantOp()
            }
        case .crop:
            if !crop.isIdentity { op = .crop(crop) }
        case .mosaic:
            if mosaic.hasPaint { op = .mosaic(mosaic) }
        case .text, .sticker, .graphic:
            let items = overlayItems.filter { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            if !items.isEmpty { op = .overlay(items) }
        case .ai:
            if !aiRunning, let edit = currentAIEdit { op = .ai(edit) }
        case .liquify:
            if !liquify.isIdentity { op = .liquify(liquify) }
        case .doodle, .mark:
            op = doodleOp()
        case .frame, .backdrop:
            op = frameOp(t)
        case .collage:
            op = collageOp()
        case .layers:
            commitLayers(then: next)
            return
        case .reshape:
            op = reshapeOp()
        case .makeup:
            op = makeupOp()
        case .skin:
            op = skinOp()
        case .shape:
            op = shapeOp()
        case .smartCrop:
            cancelSmartCrop()
            op = smartCropOp()
        case .bodyTone:
            op = bodyToneOp()
        case .effect:
            op = effectOp()
        case .beauty:
            // 每张脸的 AI 美颜和手动美颜各算一步，撤销时可以分开撤。
            if !aiRunning {
                let list = faceOps()
                op = list.first
                extra = Array(list.dropFirst())
            }
        }
        comparing = false
        if let r = reopened {
            // 重新打开的那一步：文字 / 贴纸没改过就什么都不动；否则把改好的放回去，什么都没剩就等于删掉这一步。
            if case .overlay(let items)? = op, items == r.overlay {
                cancelTool()
                next?()
                return
            }
            var newOps = r.prefix
            if let op { newOps.append(op) }
            newOps.append(contentsOf: r.suffix)
            reopened = nil
            replaceOps(newOps, then: next)
            return
        }
        guard let op else {
            cancelTool()
            next?()
            return
        }
        recordUndo()
        if !liftedFloating.isEmpty || (t == .ai && !aiLift.isEmpty) {
            // AI 的结果放在照片这一层，装饰仍然浮在最上面。
            ops = aiStack([op] + extra) + liftedFloating
            liftedFloating = []
        } else {
            ops.append(op)
            ops.append(contentsOf: extra)
        }
        Task {
            await rebuildBase()
            tool = nil
            maskSet = nil
            focusRect = nil
            resetAI()
            next?()
        }
    }

    /// 直接在历史末尾加一步（套用别的图的处理步骤时用）。
    func appendOp(_ op: EditOp) async {
        recordUndo()
        ops.append(op)
        await rebuildBase()
    }

    /// 改动 ops 之前先记一笔。
    func recordUndo() {
        undoStates.append(ops)
        redoStates.removeAll()
        revision += 1
    }

    /// 把整串操作换成新的一串（图层工具原地修改历史中间的那一步时用），然后关掉当前工具。
    func replaceOps(_ newOps: [EditOp], then next: (() -> Void)? = nil) {
        recordUndo()
        ops = newOps
        comparing = false
        Task {
            await rebuildBase()
            tool = nil
            maskSet = nil
            focusRect = nil
            resetAI()
            next?()
        }
    }

    func undo() {
        guard canUndo, let previous = undoStates.popLast() else { return }
        redoStates.append(ops)
        ops = previous
        revision += 1
        Task { await rebuildBase() }
    }

    /// 历史记录面板：从打开时到现在的每一个状态（能撤销的 + 现在的 + 能重做的）。
    var historyStates: [[EditOp]] { undoStates + [ops] + redoStates.reversed() }
    /// 现在停在第几个状态。
    var historyIndex: Int { undoStates.count }

    /// 一下子跳到历史记录里的某个状态（相当于连续撤销 / 重做）。
    func jumpHistory(to index: Int) {
        let all = historyStates
        guard tool == nil, all.indices.contains(index), index != historyIndex else { return }
        undoStates = Array(all[..<index])
        ops = all[index]
        redoStates = Array(all[(index + 1)...].reversed())
        revision += 1
        Task { await rebuildBase() }
    }

    func redo() {
        guard canRedo, let next = redoStates.popLast() else { return }
        undoStates.append(ops)
        ops = next
        revision += 1
        Task { await rebuildBase() }
    }

    // MARK: 高清贴片

    func setViewport(_ rect: CGRect?, pixels: CGFloat) {
        viewport = rect
        viewportPixels = pixels
        refreshDetail()
    }

    /// 现有的步骤加上这次 AI 的步骤：拿下来的滤镜、调色排在它后面，浮在最上面的装饰不算在内。
    private func aiStack(_ pending: [EditOp]) -> [EditOp] {
        let photo = liftedFloating.isEmpty ? ops : EditOp.splitFloating(ops).photo
        guard tool == .ai, !aiLift.isEmpty, !pending.isEmpty else { return photo + pending }
        return EditOp.splitColor(photo).base + pending + aiLift
    }

    /// 当前工具里还没确认的修改，写成编辑步骤。返回 nil 表示这种状态下不显示高清贴片。
    private func pendingOps() -> [EditOp]? {
        switch tool {
        case .none:
            return []
        case .some(.adjust):
            return adjust.isIdentity ? [] : [.adjust(adjust)]
        case .some(.filter):
            if let id = lookID, lookIntensity > 0 { return [.look(id: id, intensity: lookIntensity)] }
            if let op = instantOp() { return [op] }
            return []
        case .some(.mosaic):
            return mosaic.hasPaint ? [.mosaic(mosaic)] : []
        case .some(.ai):
            if aiRunning { return nil }
            if let edit = currentAIEdit { return [.ai(edit)] }
            return aiHasRegion ? nil : []
        case .some(.liquify):
            return liquify.isIdentity ? [] : [.liquify(liquify)]
        case .some(.beauty):
            return faceOps()
        case .some(.doodle), .some(.mark):
            return doodlePendingOps()
        case .some(.frame):
            return framePendingOps(.frame)
        case .some(.backdrop):
            return framePendingOps(.backdrop)
        case .some(.reshape):
            return reshapePendingOps()
        case .some(.makeup):
            return makeupPendingOps()
        case .some(.skin):
            return skinPendingOps()
        case .some(.bodyTone):
            return bodyToneState.showMask || bodyToneState.flash ? nil : bodyToneOp().map { [$0] } ?? []
        case .some(.effect):
            return effectPendingOps()
        default:
            return nil
        }
    }

    /// 画面有变化时先撤掉旧贴片，停手一小会儿后按当前看到的区域重新渲染一张清晰的。
    private func refreshDetail() {
        detailTask?.cancel()
        if detailImage != nil { detailImage = nil }
        guard let rect = viewport, let proxy, !isBusy, !isLoading, let pending = pendingOps() else { return }
        let all = reopened.map { $0.prefix + pending }
            ?? aiStack(pending)
        let pixels = viewportPixels
        detailTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 220_000_000)
            guard !Task.isCancelled else { return }
            let image = await Task.detached(priority: .userInitiated) { () -> UIImage? in
                let out = EditOp.apply(all, to: proxy)
                let e = out.extent
                let r = CGRect(x: rect.minX * e.width, y: (1 - rect.maxY) * e.height,
                               width: rect.width * e.width, height: rect.height * e.height).integral.intersection(e)
                guard r.width >= 2, r.height >= 2 else { return nil }
                var piece = out.cropped(to: r).transformed(by: CGAffineTransform(translationX: -r.minX, y: -r.minY))
                let scale = min(1, max(pixels, 1) / r.width)
                if scale < 1 {
                    piece = piece.applyingFilter("CILanczosScaleTransform", parameters: [
                        kCIInputScaleKey: scale, kCIInputAspectRatioKey: 1.0,
                    ]).cropped(to: CGRect(x: 0, y: 0, width: max(1, (r.width * scale).rounded(.down)),
                                          height: max(1, (r.height * scale).rounded(.down))))
                }
                guard let cg = Renderer.shared.cgImage(piece) else { return nil }
                return UIImage(cgImage: cg)
            }.value
            guard let self, !Task.isCancelled, let image else { return }
            self.detailRect = rect
            self.detailImage = image
        }
    }

    func submit(_ job: LiveJob) {
        refreshDetail()
        live.submit(job) { [weak self] image in
            guard let self, self.tool != nil else { return }
            self.displayImage = image
        }
    }

    // MARK: 滤镜

    func selectLook(_ id: String?) {
        clearInstant()
        lookID = id
        lookIntensity = 1
        renderLook()
    }

    func renderLook() {
        guard let base = basePreview else { return }
        submit(.look(base, lookID, lookIntensity))
    }

    private func makeLookThumbs(_ base: CIImage) {
        lookThumbs = [:]
        lookThumbOriginal = nil
        Task.detached(priority: .userInitiated) { [weak self] in
            guard let small = Renderer.shared.rasterize(base, maxDimension: 220) else { return }
            var thumbs: [String: UIImage] = [:]
            for look in FilmLook.all {
                if let cg = Renderer.shared.cgImage(look.apply(to: small.ci, intensity: 1)) {
                    thumbs[look.id] = UIImage(cgImage: cg)
                }
            }
            await self?.setLookThumbs(thumbs, original: UIImage(cgImage: small.cg))
        }
    }

    private func setLookThumbs(_ thumbs: [String: UIImage], original: UIImage) {
        lookThumbs = thumbs
        lookThumbOriginal = original
    }

    // MARK: 裁剪

    /// 当前锁定的比例，换算成归一化坐标下的 宽/高；nil = 自由。
    var cropLockedAspect: CGFloat? {
        guard let size = displayImage?.size, size.width > 0, size.height > 0 else { return nil }
        switch cropAspect {
        case .free: return nil
        case .original: return 1
        default:
            guard let ratio = cropAspect.ratio else { return nil }
            return ratio * size.height / size.width
        }
    }

    func setCropAspect(_ aspect: CropAspect) {
        cropAspect = aspect
        guard let a = cropLockedAspect else { return }
        let w: CGFloat = a >= 1 ? 1 : a
        let h: CGFloat = a >= 1 ? 1 / a : 1
        crop.rect = CGRect(x: (1 - w) / 2, y: (1 - h) / 2, width: w, height: h)
    }

    func cropRotate() {
        crop.rotateClockwise()
        cropAspect = .free
        renderCrop()
    }

    func cropFlipHorizontal() {
        crop.flipHorizontal()
        renderCrop()
    }

    func cropFlipVertical() {
        crop.flipVertical()
        renderCrop()
    }

    func setStraighten(_ degrees: CGFloat) {
        crop.straighten = abs(degrees) < 0.3 ? 0 : degrees
        renderCrop()
    }

    func resetCrop() {
        crop = CropParams()
        cropAspect = .free
        renderCrop()
    }

    private func renderCrop() {
        guard let base = basePreview else { return }
        submit(.crop(base, crop))
    }

    // MARK: 马赛克

    func strokeBegan(at point: CGPoint, displayScale: CGFloat) {
        if tool == .doodle || tool == .mark {
            doodleStrokeBegan(at: point, displayScale: displayScale)
            return
        }
        if tool == .liquify {
            guard displayScale > 0 else { return }
            liquifyStroke += 1
            liquifyLast = point
            liquifyRadius = liquifyBrush / 2 / displayScale
            return
        }
        if tool == .ai {
            guard displayScale > 0, !aiRunning, !aiHasResult else { return }
            let stroke = AIRegion.stroke(points: [point], width: aiBrush / displayScale, erase: aiErasing)
            aiStrokes.append(stroke)
            maskSet?.add(points: [point], stroke: stroke)
            renderAI()
            return
        }
        guard tool == .mosaic, displayScale > 0 else { return }
        let stroke = MosaicStroke(points: [point], width: brushSize / displayScale, erase: erasing,
                                  style: mosaicStyle, strength: mosaicStrength)
        mosaic.strokes.append(stroke)
        maskSet?.add(points: [point], stroke: stroke)
        renderMosaic()
    }

    func strokeMoved(to point: CGPoint) {
        if tool == .doodle || tool == .mark {
            doodleStrokeMoved(to: point)
            return
        }
        if tool == .liquify {
            guard let last = liquifyLast, let grid = liquifyGrid, let base = basePreview else { return }
            let segment = LiquifySegment(from: last, to: point, radius: liquifyRadius, strength: liquifyStrength,
                                         restore: liquifyRestore, stroke: liquifyStroke)
            liquify.segments.append(segment)
            grid.add(segment)
            liquifyLast = point
            submit(.liquify(base, grid.snapshot(), liquify.lockMask, personPlate))
            return
        }
        if tool == .ai {
            guard !aiRunning, !aiHasResult, let last = aiStrokes.indices.last,
                  let previous = aiStrokes[last].points.last else { return }
            aiStrokes[last].points.append(point)
            maskSet?.add(points: [previous, point], stroke: aiStrokes[last])
            renderAI()
            return
        }
        guard tool == .mosaic, let last = mosaic.strokes.indices.last,
              let previous = mosaic.strokes[last].points.last else { return }
        mosaic.strokes[last].points.append(point)
        maskSet?.add(points: [previous, point], stroke: mosaic.strokes[last])
        renderMosaic()
    }

    func strokeEnded() {
        if tool == .doodle || tool == .mark { doodleStrokeEnded() }
    }

    func strokeCancelled() {
        undoStroke()
    }

    func undoStroke() {
        if tool == .doodle || tool == .mark {
            doodleUndoStroke()
            return
        }
        if tool == .liquify {
            guard let last = liquify.segments.last?.stroke, let grid = liquifyGrid, let base = basePreview else { return }
            liquify.segments.removeAll { $0.stroke == last }
            grid.replay(liquify.segments)
            liquifyLast = nil
            submit(.liquify(base, grid.snapshot(), liquify.lockMask, personPlate))
            return
        }
        if tool == .ai {
            guard !aiRunning, !aiHasResult, !aiStrokes.isEmpty else { return }
            aiStrokes.removeLast()
            maskSet?.rebuild(aiStrokes)
            renderAI()
            return
        }
        guard tool == .mosaic, !mosaic.strokes.isEmpty else { return }
        mosaic.strokes.removeLast()
        maskSet?.rebuild(mosaic.strokes)
        renderMosaic()
    }

    private func renderMosaic() {
        guard let base = basePreview, let maskSet else { return }
        submit(.mosaic(base, maskSet.snapshot()))
    }

    /// 开关"固定背景"。第一次打开时在本机识别一次人像。
    func setLiquifyLock(_ on: Bool) {
        guard tool == .liquify, !liquifyLockBusy else { return }
        liquifyNote = nil
        func apply(_ mask: CGImage?) {
            liquifyLock = mask != nil
            liquify.lockMask = mask
            if let grid = liquifyGrid, let base = basePreview {
                submit(.liquify(base, grid.snapshot(), liquify.lockMask, personPlate))
            }
        }
        guard on else { return apply(nil) }
        if let personMask { return apply(personMask) }
        guard let cg = baseUIImage?.cgImage, let base = basePreview else { return }
        liquifyLockBusy = true
        Task { [weak self] in
            let found = await Task.detached(priority: .userInitiated) { () -> (CGImage?, CGImage?) in
                guard let mask = PersonSegmenter.mask(for: cg) else { return (nil, nil) }
                return (mask, Renderer.shared.cgImage(LiquifyGrid.backgroundPlate(base, lock: mask)))
            }.value
            let mask = found.0
            guard let self, self.tool == .liquify else { return }
            self.liquifyLockBusy = false
            self.personMask = mask
            self.personPlate = found.1
            if mask == nil { self.liquifyNote = "这张图里没有识别到人物，没法固定背景。" }
            apply(mask)
        }
    }

    func resetLiquify() {
        guard tool == .liquify, let grid = liquifyGrid, let base = basePreview else { return }
        liquify = LiquifyParams(lockMask: liquify.lockMask)
        grid.reset()
        submit(.liquify(base, grid.snapshot(), liquify.lockMask, personPlate))
    }

    // MARK: AI 修图

    var aiHasRegion: Bool { aiStrokes.contains { !$0.erase } }

    func clearAIRegion() {
        guard !aiRunning, !aiHasResult else { return }
        aiStrokes = []
        maskSet?.rebuild([])
        renderAI()
    }

    /// 当前这次 AI 结果对应的编辑步骤；还没有结果时是 nil。
    private var currentAIEdit: AIEdit? {
        guard let result = aiResult else { return nil }
        // "只取光影色彩"只属于 AI 修图；美颜要的就是 AI 改过的脸，不能套这个模式。
        // 柔化只给整张重画的结果用；美颜只换脸部那一块，不柔化。
        let soften = tool == .ai && aiFrame == nil && !aiHasRegion ? aiSoften : 0
        var recipe = tool == .ai && !aiResultFused ? aiPendingRecipe : nil
        recipe?.strength = aiStrength
        recipe?.toneOnly = aiToneOnly
        recipe?.soften = soften
        recipe?.keepFace = aiKeepFace
        recipe?.changedOnly = aiChangedOnly
        if aiResultReframed {
            return AIEdit(result: result, strokes: [], reframed: true, soften: soften, faces: aiKeepFace ? aiFaces : [],
                          mono: aiMono, recipe: recipe)
        }
        return AIEdit(result: result, strokes: aiStrokes, frame: aiFrame, ellipse: aiEllipse, strength: aiStrength,
                      toneOnly: aiToneOnly && tool == .ai, soften: soften,
                      faces: aiKeepFace && tool == .ai ? aiFaces : [],
                      changedOnly: aiCanKeepRest && aiChangedOnly && tool == .ai, area: aiArea, core: aiCore, shift: aiShift,
                      mono: aiMono, recipe: recipe)
    }

    func renderAI() {
        guard let base = basePreview else { return }
        if tool == .beauty {
            let layers = faceLayers()
            submit(.beauty(base, layers.edits, layers.beauties))
        } else if let edit = currentAIEdit {
            if !aiLift.isEmpty, let under = aiBase {
                submit(.direct(EditOp.apply(aiLift, to: edit.apply(to: under))))
            } else {
                submit(.aiResult(base, edit))
            }
        } else {
            submit(.aiRegion(base, aiHasRegion ? maskSet?.snapshot().first?.image : nil))
        }
    }

    func setAIToneOnly(_ on: Bool) {
        aiToneOnly = on
        renderAI()
    }

    func setAIChangedOnly(_ on: Bool) {
        aiChangedOnly = on
        renderAI()
    }

    func setAIKeepFace(_ on: Bool) {
        aiKeepFace = on
        renderAI()
    }

    func setAISoften(_ value: CGFloat) {
        aiSoften = min(max(value, 0), 1)
        renderAI()
    }

    func setAIStrength(_ value: CGFloat) {
        aiStrength = min(max(value, 0), 1)
        renderAI()
    }

    /// 把当前画面和指令发给选中的服务商。
    func runAI() {
        let base = aiPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard tool == .ai, !aiRunning else { return }
        guard !base.isEmpty else {
            aiError = "先写一句要怎么改，或者点上面的快捷指令。"
            return
        }
        // 结果出来后再点同一条：算重新生成，加上这一轮的变化要求。
        aiRegenRound = aiHasResult && base == aiLastPrompt ? aiRegenRound + 1 : 0
        aiLastPrompt = base
        // 记下怎么发起的：涂抹出来的和原图位置绑定，不能套到别的照片上。
        aiPendingRecipe = aiHasRegion || base.contains("涂抹区域") ? nil
            : AIRecipe(group: aiGroup.rawValue, prompt: base, presetTitle: aiPresetTitle, masterCompose: aiMasterCompose,
                       faceCrop: aiFaceCrop, hairCrop: aiHairCrop, reframe: aiReframe.rawValue)
        aiEllipse = nil
        aiResultReframed = false
        if aiGroup == .master, aiMasterCompose, MasterCompose.prompt(base, title: aiPresetTitle, hasPerson: true) != nil,
           let cg = baseUIImage?.cgImage {
            // 大师构图：整张交给 AI 重新取景，不看涂抹；结果和原图对不齐，按换过构图处理。
            // 先在本机看看照片里有没有人：没人的场景照用场景版指令，免得 AI 照着"人物居中"之类的描述加个人进去。
            let round = aiRegenRound, title = aiPresetTitle
            aiFrame = nil
            aiToneOnly = false
            aiError = nil
            aiRunning = true
            aiStarted = Date()
            Task { [weak self] in
                let hasPerson = await Task.detached(priority: .userInitiated) { MasterCompose.hasPerson(in: cg) }.value
                guard let self, self.tool == .ai, self.aiRunning else { return }
                self.aiRunning = false
                guard let recomposed = MasterCompose.prompt(base, title: title, hasPerson: hasPerson) else { return }
                let prompt = round > 0
                    ? recomposed + AIVariation.clause(for: .master, round: round, recompose: true, hasPerson: hasPerson) : recomposed
                self.launchAI(prompt: prompt, strokes: [], crop: nil, guidance: false, identity: hasPerson, recomposed: true)
            }
            return
        }
        let prompt = aiRegenRound > 0 ? base + AIVariation.clause(for: aiGroup, round: aiRegenRound) : base
        if aiGroup == .compose, aiReframe != .original {
            // 换画幅：整张交给 AI 重新构图，不看涂抹。
            aiFrame = nil
            aiToneOnly = false
            launchAI(prompt: prompt, strokes: [], crop: nil, guidance: false, reframe: aiReframe)
            return
        }
        if prompt.contains("涂抹区域"), !aiHasRegion {
            aiError = "先在图上涂抹要去掉的东西，再点发送。"
            return
        }
        // 换衣服（点的款式，或者自己写的要换衣服）：只发人这一块，背景、脸、头都用原图。
        let typed = aiPresetTitle.isEmpty && aiGroup != .outfit && AIIntent.changesClothes(base)
        if !aiHasRegion, aiGroup == .outfit || typed, let cg = baseUIImage?.cgImage {
            let text = prompt.contains(OutfitCatalog.keep) ? prompt : prompt + "。" + OutfitCatalog.clean + OutfitCatalog.keep
            // 点款式的看选的裙摆；自己写的看说没说裙摆要溢出去。
            let overflow = aiPresetTitle.isEmpty ? ["溢出", "铺满", "铺开", "拖尾", "大裙摆", "巨大"].contains { base.contains($0) } : outfitSkirt == .overflow && outfitPick != nil
            let references = aiGroup == .outfit ? [outfitReference].compactMap { $0 } : []
            aiFrame = nil
            aiToneOnly = false
            aiError = nil
            aiRunning = true
            aiStarted = Date()
            Task { [weak self] in
                let crop = overflow ? nil : await Task.detached(priority: .userInitiated) { OutfitMask.crop(cg) }.value
                guard let self, self.tool == .ai, self.aiRunning else { return }
                self.aiRunning = false
                self.launchAI(prompt: text, strokes: [], crop: crop, guidance: false, references: references, outfit: true, overflow: overflow)
            }
            return
        }
        if aiHairCrop, !aiHasRegion, let cg = baseUIImage?.cgImage {
            // 美发：找到脸，把头、头发连同肩膀这一块发出去；找不到脸就发整张图。
            aiError = nil
            aiRunning = true
            aiStarted = Date()
            Task { [weak self] in
                let found = await Task.detached(priority: .userInitiated) { FaceDetector.detect(in: cg) }.value
                guard let self, self.tool == .ai, self.aiRunning else { return }
                self.aiRunning = false
                guard let face = found.first else {
                    self.aiFrame = nil
                    self.launchAI(prompt: prompt, strokes: [], crop: nil, guidance: true, identity: true)
                    return
                }
                let size = self.pixelSize()
                let bw = face.box.width * size.width, bh = face.box.height * size.height
                let side = max(bw, bh) * 5.2
                // 往下偏一些：长发、披肩发主要在脸的下面和两侧。
                let cx = face.box.midX * size.width, cy = face.box.midY * size.height + bh * 0.6
                let frame = CGRect(x: cx - side / 2, y: cy - side / 2, width: side, height: side)
                    .intersection(CGRect(origin: .zero, size: size))
                // 这一块几乎占满全图时直接发整张，省得贴回去多一道接缝。
                if frame.width * frame.height > size.width * size.height * 0.8 {
                    self.aiFrame = nil
                    self.launchAI(prompt: prompt, strokes: [], crop: nil, guidance: true, identity: true)
                    return
                }
                self.aiFrame = CGRect(x: frame.minX / size.width, y: frame.minY / size.height,
                                      width: frame.width / size.width, height: frame.height / size.height)
                // 贴回的范围比发出去的小一圈：羽化要完全落在发出去的这一块里面，否则边上会露出一条硬边。
                let inner = frame.insetBy(dx: frame.width * 0.11, dy: frame.height * 0.11)
                self.aiEllipse = CGRect(x: inner.minX / size.width, y: inner.minY / size.height,
                                        width: inner.width / size.width, height: inner.height / size.height)
                self.launchAI(prompt: prompt, strokes: [], crop: self.aiFrame, guidance: false, identity: true)
            }
            return
        }
        if aiFaceCrop, !aiHasRegion, let cg = baseUIImage?.cgImage {
            // 先在本机找脸，只把头部这一块发出去；找不到脸再退回整张图。
            aiError = nil
            aiRunning = true
            aiStarted = Date()
            Task { [weak self] in
                let found = await Task.detached(priority: .userInitiated) { FaceDetector.detect(in: cg) }.value
                guard let self, self.tool == .ai, self.aiRunning else { return }
                self.aiRunning = false
                guard let face = found.first else {
                    self.aiFrame = nil
                    self.launchAI(prompt: prompt, strokes: [], crop: nil, guidance: false, identity: true)
                    return
                }
                let size = self.pixelSize()
                let bw = face.box.width * size.width, bh = face.box.height * size.height
                let cx = face.box.midX * size.width, cy = face.box.midY * size.height - bh * 0.1
                self.aiFrame = self.faceFrame(face, factor: 2.6)
                // 贴回的范围包住整个头和头发，边缘羽化。
                self.aiEllipse = CGRect(x: (cx - bw * 0.95) / size.width, y: (cy - bh * 1.1) / size.height,
                                        width: bw * 1.9 / size.width, height: bh * 2.2 / size.height)
                self.launchAI(prompt: prompt, strokes: [], crop: self.aiFrame, guidance: false, identity: true)
            }
            return
        }
        guard aiHasRegion, let crop = regionCrop() else {
            aiFrame = nil
            launchAI(prompt: prompt, strokes: [], crop: nil, guidance: true, identity: aiFaceCrop)
            return
        }
        // 涂了区域：只把这一块（带一圈周围环境）裁出来发给 AI，结果也只贴回涂抹的范围。
        aiFrame = crop
        if AIIntent.replacesContent(prompt) {
            // 去掉/替换：涂抹范围当蒙版，让 AI 把里面的东西重画。
            launchAI(prompt: prompt, strokes: remap(aiStrokes, into: crop), crop: crop, guidance: true)
        } else {
            // 在原内容上修改：不发蒙版，AI 看得到原图。
            let hint = "\n\nThis is a cropped part of a larger photo. Apply the instruction to what is shown here and keep the same framing, position and scale so it can be placed back."
            launchAI(prompt: prompt + hint, strokes: [], crop: crop, guidance: true, identity: aiFaceCrop)
        }
    }

    /// 涂抹范围的外接框，四周留出余量，限制在图片内（归一化坐标）。
    private func regionCrop() -> CGRect? {
        let size = pixelSize()
        let long = max(size.width, size.height)
        var box: CGRect?
        for stroke in aiStrokes where !stroke.erase {
            let half = stroke.width * long / 2
            for p in stroke.points {
                let r = CGRect(x: p.x * size.width - half, y: p.y * size.height - half, width: half * 2, height: half * 2)
                box = box?.union(r) ?? r
            }
        }
        guard var b = box else { return nil }
        let margin = max(max(b.width, b.height) * 0.35, long * 0.06)
        b = b.insetBy(dx: -margin, dy: -margin)
        // 太细长的框补成不超过 2.5:1，接口对比例有限制。
        if b.width > b.height * 2.5 { b = b.insetBy(dx: 0, dy: -(b.width / 2.5 - b.height) / 2) }
        if b.height > b.width * 2.5 { b = b.insetBy(dx: -(b.height / 2.5 - b.width) / 2, dy: 0) }
        b = b.intersection(CGRect(origin: .zero, size: size))
        guard b.width >= 8, b.height >= 8 else { return nil }
        return CGRect(x: b.minX / size.width, y: b.minY / size.height, width: b.width / size.width, height: b.height / size.height)
    }

    /// 把整图坐标的笔画换算到裁剪框内的坐标。
    private func remap(_ strokes: [MosaicStroke], into crop: CGRect) -> [MosaicStroke] {
        let size = pixelSize()
        let k = max(size.width, size.height) / max(crop.width * size.width, crop.height * size.height)
        return strokes.map { stroke in
            var s = stroke
            s.points = stroke.points.map { CGPoint(x: ($0.x - crop.minX) / crop.width, y: ($0.y - crop.minY) / crop.height) }
            s.width = stroke.width * k
            return s
        }
    }

    /// identity = true：必须还是同一个人的任务。画质设成"自动"时改用高画质，并要求尽量忠实于原图。
    private func launchAI(prompt: String, strokes: [MosaicStroke], crop: CGRect?, guidance: Bool, identity: Bool = false,
                          reframe: AIReframe = .original, references: [UIImage] = [], recomposed: Bool = false,
                          outfit: Bool = false, overflow: Bool = false) {
        guard let proxy, let started = tool else { return }
        guard var endpoint = AISettings.shared.endpoint() else {
            aiError = "还没有设置 \(AISettings.shared.active.shortTitle) 的 API Key。"
            return
        }
        if identity {
            endpoint.highFidelity = true
            if endpoint.quality == "auto" { endpoint.quality = "high" }
        }
        // 只取光影和颜色时，AI 图的清晰度用不上，按标准尺寸要就够了，省钱。
        if aiToneOnly, started == .ai { endpoint.hires = false }
        // 文字、贴纸这些装饰不发给 AI，只发照片本身。
        var ops = liftedFloating.isEmpty ? self.ops : EditOp.splitFloating(self.ops).photo
        aiLift = []
        aiBase = nil
        // 大师、相机、创意本来就是换色调；其余的不能把用户加的滤镜冲掉。
        if started == .ai, ![.master, .camera, .creative].contains(aiGroup) {
            let split = EditOp.splitColor(ops)
            ops = split.base
            aiLift = split.color
        }
        let lifted = !aiLift.isEmpty
        aiError = nil
        aiResult = nil
        aiHasResult = false
        aiFaces = []
        aiMono = false
        aiCanKeepRest = false
        aiArea = nil
        aiCore = nil
        aiResultOutfit = false
        aiShift = .zero
        aiUsageText = nil
        // 整张重画、还是同一个人的这几组：出来以后把原图的脸贴回去。
        var before = started == .ai && outfit ? baseUIImage?.cgImage : started == .ai && crop == nil && strokes.isEmpty
            && [.master, .camera, .compose, .light, .body].contains(aiGroup) ? baseUIImage?.cgImage : nil
        // 只动一部分的这两组：没动的地方用原图。
        var part = started == .ai && outfit ? baseUIImage?.cgImage : started == .ai && crop == nil && strokes.isEmpty && !recomposed && reframe == .original
            && [.body, .remove].contains(aiGroup) ? baseUIImage?.cgImage : nil
        let bodyOnly = aiGroup == .body
        let bodyPart = aiPart
        _ = AIClient.takeLastUsage()
        aiRunning = true
        aiStarted = Date()
        renderAI()
        aiTask = Task { [weak self] in
            do {
                if recomposed, started == .ai {
                    // 对脸、查有没有跑题：用发出去的那一块（大图）。
                    let sent = ops
                    before = await Task.detached(priority: .userInitiated) { () -> CGImage? in
                        let full = EditOp.apply(sent, to: proxy)
                        return Renderer.shared.rasterize(full, maxDimension: 2560)?.cg
                    }.value ?? before
                }
                if outfit {
                    // 脸在画面里可能很小：比较和找脸用大一点的图。
                    let sent = ops
                    if let big = await Task.detached(priority: .userInitiated, operation: {
                        Renderer.shared.rasterize(EditOp.apply(sent, to: proxy), maxDimension: 3072)
                    }).value {
                        before = big.cg
                        part = big.cg
                    }
                }
                if lifted {
                    // 比较和贴脸都用没盖滤镜的底图。
                    let sent = ops
                    let r = await Task.detached(priority: .userInitiated) {
                        Renderer.shared.rasterize(EditOp.apply(sent, to: proxy), maxDimension: 1600)
                    }.value
                    if let r {
                        self?.aiBase = r.ci
                        if before != nil, !outfit { before = r.cg }
                        if part != nil, !outfit { part = r.cg }
                    }
                }
                var image = try await AIRunner.run(endpoint: endpoint, prompt: prompt, proxy: proxy, ops: ops,
                                                   strokes: strokes, crop: crop, appendGuidance: guidance, reframe: reframe,
                                                   references: references)
                if outfit, let crop {
                    // 只发了人这一块：拼回整张，后面就和发整张的一样处理。
                    let piece = image, sent = ops
                    if let whole = await Task.detached(priority: .userInitiated, operation: {
                        OutfitMask.paste(piece, crop: crop, over: EditOp.apply(sent, to: proxy))
                    }).value { image = whole }
                }
                let result = image
                let usage = AIClient.takeLastUsage()
                if let cost = usage?.cost { AISettings.shared.addSpend(cost) }
                if started == .beauty, let crop {
                    // 修完的脸和原来对不上（画成别人、换了姿势）就不采用。
                    let sent = ops
                    let same = await Task.detached(priority: .userInitiated) { () -> Bool in
                        guard let original = Self.piece(EditOp.apply(sent, to: proxy), crop) else { return true }
                        return FaceCheck.matches(original: original, result: result)
                    }.value
                    if !same { throw AIError(text: "AI 这次把脸画成了别人，没有采用。可以再点一次；脸太小太糊的话，先用 AI 修复里的\u{201C}增强画质\u{201D}。") }
                }
                let (before, part) = (before, part)
                let found = await Task.detached(priority: .userInitiated) { () -> ([FaceKeep], Bool, CGVector, CGImage?, CGImage?) in
                    let image = result
                    let shift = part.map { ChangeKeep.shift(original: $0, ai: image) } ?? .zero
                    var area: CGImage?
                    var core: CGImage?

                    if bodyOnly, let part {
                        area = ChangeKeep.personArea(PersonSegmenter.mask(for: part), PersonSegmenter.mask(for: image),
                                                     size: CGSize(width: part.width, height: part.height))
                        if let limit = bodyPart?.area(in: part) { area = ChangeKeep.intersect(area, limit) }
                    }
                    var faces = before.map { FaceKeep.match(original: $0, result: image) } ?? []
                    // 五官是在没对齐的 AI 图上量的，跟着整体平移一起挪。
                    for i in faces.indices { faces[i].move(shift, size: CGSize(width: image.width, height: image.height)) }
                    if outfit, let part {
                        // 头基本没挪（位置差不到脸宽的 12%、大小差不到 4%）就整个头用原图；挪了就按五官对齐贴脸。
                        let still = !faces.isEmpty && faces.allSatisfy { $0.isStill }
                        (area, core) = OutfitMask.masks(original: part, ai: image, overflow: overflow, keepHead: still)
                        if still { faces = [] }
                    }
                    return (faces, MonoCheck.isMono(image), shift, area, core)
                }.value
                guard let self, !Task.isCancelled, self.tool == started else { return }
                self.aiFaces = found.0
                // 大师保持最早的样子：默认用 AI 的脸，想要原图的脸再切过去。
                self.aiKeepFace = self.aiGroup != .master
                self.aiMono = found.1
                self.aiShift = found.2
                self.aiArea = found.3
                self.aiCore = found.4
                self.aiResultOutfit = outfit
                if outfit { self.aiFrame = nil }
                self.aiCanKeepRest = part != nil
                self.aiUsageText = usage?.summary
                self.aiResult = result
                self.aiResultReframed = reframe != .original || recomposed
                self.aiHasResult = true
                self.aiRunning = false
                self.saveDraft()
                if started == .beauty, let key = self.pendingFaceKey, let frame = self.aiFrame, let ellipse = self.aiEllipse {
                    self.faceCache[key] = CachedFace(image: result, frame: frame, ellipse: ellipse)
                    self.cachedFaceKeys.insert(key)
                }
                self.renderAI()
            } catch is CancellationError {
                self?.aiRunning = false
            } catch {
                guard let self, !Task.isCancelled else { return }
                self.aiRunning = false
                self.aiError = error.localizedDescription
            }
        }
    }

    func cancelAI() {
        aiTask?.cancel()
        aiTask = nil
        aiRunning = false
    }

    /// 不要这次的结果，回到涂抹和写指令的状态。
    func discardAIResult() {
        aiResult = nil
        aiHasResult = false
        renderAI()
    }

    // MARK: 美颜

    func detectFaces() {
        guard baseUIImage?.cgImage != nil else { return }
        detectingFaces = true
        Task { [weak self] in
            guard let self else { return }
            let found = await self.findFaces()
            guard self.tool == .beauty else { return }
            self.faces = found
            self.describedFaces = [:]
            self.faceStates = [:]
            self.beauty.faces = found.first.map { [$0] } ?? []
            self.faceIndex = 0
            self.detectingFaces = false
            self.updateFocus()
            if self.runFavoriteAfterDetect {
                self.runFavoriteAfterDetect = false
                if !found.isEmpty { self.runFavoriteFace() }
            }
        }
    }

    private func pixelSize() -> CGSize {
        baseUIImage?.size ?? CGSize(width: 1, height: 1)
    }

    /// 以脸为中心、边长为脸的 factor 倍的方框（按像素是正方形），限制在图片范围内。
    private func faceFrame(_ face: FaceInfo, factor: CGFloat) -> CGRect {
        let size = pixelSize()
        let bw = face.box.width * size.width
        let bh = face.box.height * size.height
        let side = max(bw, bh) * factor
        let cx = face.box.midX * size.width
        // Vision 的框不含额头上半部分，往上挪一点把头顶也框进来。
        let cy = face.box.midY * size.height - bh * 0.1
        let rect = CGRect(x: cx - side / 2, y: cy - side / 2, width: side, height: side)
            .intersection(CGRect(origin: .zero, size: size))
        return CGRect(x: rect.minX / size.width, y: rect.minY / size.height,
                      width: rect.width / size.width, height: rect.height / size.height)
    }

    private func updateFocus() {
        guard faces.indices.contains(faceIndex) else {
            focusRect = nil
            return
        }
        focusRect = faceFrame(faces[faceIndex], factor: 1.9)
    }

    /// 每张脸各自的修改：切到别的脸时先存起来，切回来再取出，互不影响。
    private struct FaceState {
        var edit: AIEdit?
        var style: String?
        var beauty = BeautyParams()
        var preset: String?
    }
    @ObservationIgnored private var faceStates: [Int: FaceState] = [:]
    private(set) var editedFaces: Set<Int> = []

    func faceEdited(_ index: Int) -> Bool {
        index == faceIndex ? (aiHasResult || !beauty.isIdentity) : editedFaces.contains(index)
    }

    func selectFace(_ index: Int) {
        guard faces.indices.contains(index), !aiRunning else { return }
        guard index != faceIndex else { return updateFocus() }
        // 存下当前这张脸的状态
        faceStates[faceIndex] = FaceState(edit: currentAIEdit, style: beautyStyle, beauty: beauty, preset: beautyPreset)
        if currentAIEdit != nil || !beauty.isIdentity { editedFaces.insert(faceIndex) } else { editedFaces.remove(faceIndex) }
        // 取出要切过去的那张脸的状态
        faceIndex = index
        let state = faceStates[index] ?? FaceState()
        aiResult = state.edit?.result
        aiHasResult = aiResult != nil
        aiFrame = state.edit?.frame
        aiEllipse = state.edit?.ellipse
        aiStrength = state.edit?.strength ?? 1
        beautyStyle = state.style
        beauty = state.beauty
        beauty.faces = [faces[index]]
        beautyPreset = state.preset
        aiUsageText = nil
        aiError = nil
        updateFocus()
        renderAI()
    }

    /// 点画面：点到哪张脸就切到哪张。
    func tapFace(at point: CGPoint) {
        if rescueFace(at: point) { return }
        guard tool == .beauty, !aiRunning, faces.count > 1 else { return }
        var best: (index: Int, distance: CGFloat)?
        for (i, face) in faces.enumerated() {
            let area = face.box.insetBy(dx: -face.box.width * 0.35, dy: -face.box.height * 0.45)
            guard area.contains(point) else { continue }
            let d = hypot(point.x - face.box.midX, point.y - face.box.midY)
            if best == nil || d < best!.distance { best = (i, d) }
        }
        if let best { selectFace(best.index) }
    }

    /// 所有脸当前的修改：先是各张脸的 AI 结果，再是各张脸的手动美颜。
    private func faceLayers() -> (edits: [AIEdit], beauties: [BeautyParams]) {
        var edits: [AIEdit] = []
        var beauties: [BeautyParams] = []
        for i in faces.indices {
            let edit = i == faceIndex ? currentAIEdit : faceStates[i]?.edit
            let params = i == faceIndex ? beauty : (faceStates[i]?.beauty ?? BeautyParams())
            if let edit { edits.append(edit) }
            if !params.isIdentity { beauties.append(params) }
        }
        return (edits, beauties)
    }

    private func faceOps() -> [EditOp] {
        let layers = faceLayers()
        return layers.edits.map { EditOp.ai($0) } + layers.beauties.map { EditOp.beauty($0) }
    }

    func setBeauty(_ key: BeautyKey, _ value: CGFloat) {
        beauty[key] = value < 0.02 ? 0 : value
        beautyPreset = nil
        renderAI()
    }

    func applyBeautyPreset(_ preset: BeautyPreset?) {
        beauty.set(preset)
        beautyPreset = preset?.id
        renderAI()
    }

    func setLipColor(_ index: Int) {
        beauty.lipColor = index
        if beauty[.lips] == 0 { beauty[.lips] = 0.5 }
        beautyPreset = nil
        renderAI()
    }

    private func faceKey(_ style: BeautyStyle) -> String { "\(faceIndex)|\(style.prompt)" }  // 男女两套有同名的风格，按指令区分

    func isFaceStyleCached(_ style: BeautyStyle) -> Bool { cachedFaceKeys.contains(faceKey(style)) }

    /// AI 美颜：只把选中的那张脸裁出来发给服务商，结果只贴回脸部的椭圆范围。
    /// 这张脸的这个风格之前生成过的话直接用记住的结果；force = true 时强制重新生成。
    /// 一进美颜就按满意脸型修（主菜单"满意脸型"入口用）：等找完脸再开始。
    var runFavoriteAfterDetect = false

    /// 按满意脸型修当前这张脸。
    func runFavoriteFace(force: Bool = false) {
        guard let face = FavoriteFaceStore.shared.current, let reference = FavoriteFaceStore.shared.image(face) else {
            aiError = "还没有满意脸型"
            return
        }
        runFaceAI(.favorite, force: force, references: [reference])
    }

    func runFaceAI(_ style: BeautyStyle, force: Bool = false, references: [UIImage] = []) {
        guard tool == .beauty, !aiRunning, faces.indices.contains(faceIndex) else { return }
        let key = faceKey(style)
        if !force, let cached = faceCache[key] {
            aiError = nil
            aiUsageText = nil
            beautyStyle = style.id
            aiFrame = cached.frame
            aiEllipse = cached.ellipse
            aiResult = cached.image
            aiHasResult = true
            renderAI()
            return
        }
        let face = faces[faceIndex]
        if !describedFaces.keys.contains(faceIndex), needsDescription(face) {
            // 脸太小、太糊、认不出五官：先让 AI 看清原来的样子，框也按它指的校准，再去修，免得修成别人。
            describeFace(face, index: faceIndex) { [weak self] in
                self?.runFaceAI(style, force: force, references: references)
            }
            return
        }
        let size = pixelSize()
        let crop = faceFrame(face, factor: 2.0)
        let bw = face.box.width * size.width
        let bh = face.box.height * size.height
        let cx = face.box.midX * size.width
        let cy = face.box.midY * size.height - bh * 0.1
        let ellipse = CGRect(x: (cx - bw * 0.66) / size.width, y: (cy - bh * 0.82) / size.height,
                             width: bw * 1.32 / size.width, height: bh * 1.64 / size.height)
        beautyStyle = style.id
        aiFrame = crop
        aiEllipse = ellipse
        pendingFaceKey = key
        // 原来的样子写清楚，AI 不许改。
        let known = (describedFaces[faceIndex] ?? "").isEmpty ? "" : " The person currently looks like this and must stay exactly so: \(describedFaces[faceIndex] ?? "")"
            + " The source is small and slightly blurry: restore it conservatively, never invent a different face."
        launchAI(prompt: BeautyStyle.preamble + " " + style.prompt + known, strokes: [], crop: crop, guidance: false, identity: true,
                 references: references)
    }

    /// 这张脸要不要先让 AI 看清楚：五官认不出，或者原图里脸宽不到 220 像素。
    private func needsDescription(_ face: FaceInfo) -> Bool {
        guard AISettings.shared.endpoint() != nil else { return false }
        let full = (source?.extent.width ?? 0) > 0 ? CGFloat(max(source?.extent.width ?? 0, source?.extent.height ?? 0)) : 0
        let size = pixelSize()
        let pixels = face.box.width * size.width / max(size.width, size.height) * full
        return !face.hasReliableLandmarks || pixels < 220
    }

    private func describeFace(_ face: FaceInfo, index: Int, then next: @escaping () -> Void) {
        guard let endpoint = AISettings.shared.endpoint(), let proxy else { return next() }
        let crop = faceFrame(face, factor: 3)
        let ops = liftedFloating.isEmpty ? self.ops : EditOp.splitFloating(self.ops).photo
        aiError = nil
        aiRunning = true
        aiStarted = Date()
        aiTask = Task { [weak self] in
            var desc = "", box: CGRect?
            let jpeg = await Task.detached(priority: .userInitiated) { () -> Data? in
                Self.piece(EditOp.apply(ops, to: proxy), crop).flatMap {
                    AIOneShot.prepared(UIImage(cgImage: $0), maxSide: 1024).jpegData(compressionQuality: 0.9)
                }
            }.value
            if let jpeg, let text = try? await AIClient.look(endpoint, prompt: FaceCheck.describePrompt, jpeg: jpeg) {
                desc = String((SmartCrop.object(text, key: "faces")?["desc"] as? String ?? "").prefix(500))
                // 挑离原来那个位置最近的框。
                box = SmartCrop.boxes(text, key: "faces").min {
                    hypot($0.midX - 0.5, $0.midY - 0.5) < hypot($1.midX - 0.5, $1.midY - 0.5)
                }
            }
            guard let self, !Task.isCancelled, self.tool == .beauty, self.aiRunning else { return }
            self.aiRunning = false
            // 看不了图也照常修，只是少了这句描述。
            self.describedFaces[index] = desc
            if let b = box, !face.hasReliableLandmarks, b.width > 0.1, self.faces.indices.contains(index) {
                let moved = CGRect(x: crop.minX + b.minX * crop.width, y: crop.minY + b.minY * crop.height,
                                   width: b.width * crop.width, height: b.height * crop.height)
                self.faces[index] = FaceInfo(box: moved)
                self.forcedFaces = self.faces
                self.forcedFacesSize = self.basePreview?.extent.size
                self.updateFocus()
            }
            next()
        }
    }

    /// 裁出画面里的一块（归一化，左上原点）。
    nonisolated static func piece(_ image: CIImage, _ crop: CGRect) -> CGImage? {
        let e = image.extent
        let r = CGRect(x: e.minX + crop.minX * e.width, y: e.maxY - crop.maxY * e.height, width: crop.width * e.width, height: crop.height * e.height)
            .integral.intersection(e)
        guard r.width >= 8, r.height >= 8 else { return nil }
        let moved = image.cropped(to: r).transformed(by: CGAffineTransform(translationX: -r.minX, y: -r.minY))
        return Renderer.shared.rasterize(moved, maxDimension: 1200)?.cg
    }

    /// 对当前显示的这个风格重新生成一次（会再调用一次接口）。
    func regenerateFaceAI() {
        if beautyStyle == BeautyStyle.favorite.id { return runFavoriteFace(force: true) }
        guard let style = BeautyStyle.named(beautyStyle) else { return }
        runFaceAI(style, force: true)
    }

    /// 换了服务商之后，把刚才那次请求原样重发。
    func retryAI() {
        if tool == .beauty {
            if beautyStyle == BeautyStyle.favorite.id { return runFavoriteFace(force: true) }
            if let style = BeautyStyle.named(beautyStyle) { runFaceAI(style, force: true) }
        } else {
            runAI()
        }
    }

    func discardFaceAI() {
        aiResult = nil
        aiHasResult = false
        beautyStyle = nil
        renderAI()
    }

    // MARK: 保存

    /// 用原图分辨率重新跑一遍所有操作，存进相册。
    /// 按当前所有步骤算出来的成品是多少像素。
    func outputSize() async -> CGSize? {
        guard let source else { return nil }
        let ops = self.ops
        return await Task.detached(priority: .userInitiated) {
            EditOp.apply(ops, to: source).extent.size
        }.value
    }

    /// 按保存选项渲染出最终的文件数据。
    func renderData(_ options: SaveOptions = .saved) async -> Data? {
        guard let source else { return nil }
        let ops = self.ops
        var space = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        if let s = source.colorSpace, s.model == .rgb { space = s }
        let data = await Task.detached(priority: .userInitiated) { () -> Data? in
            var out = EditOp.apply(ops, to: source)
            out = out.transformed(by: CGAffineTransform(translationX: -out.extent.minX, y: -out.extent.minY))
            if let side = options.size.maxSide { out = Renderer.shared.downscaled(out, maxDimension: side) }
            let quality = CIImageRepresentationOption(rawValue: kCGImageDestinationLossyCompressionQuality as String)
            let context = Renderer.shared.context
            switch options.format {
            case .jpeg:
                return context.jpegRepresentation(of: out, colorSpace: space, options: [quality: options.size.quality])
            case .heic:
                return context.heifRepresentation(of: out, format: .RGBA8, colorSpace: space,
                                                  options: [quality: options.size.quality])
            case .png:
                return context.pngRepresentation(of: out, format: .RGBA8, colorSpace: space)
            }
        }.value
        return data
    }

    /// 存进历史图库（打开了的话）。
    func addToHistory(_ data: Data, options: SaveOptions) async {
        guard HistoryStore.shared.enabled, let source else { return }
        await HistoryStore.shared.add(data: data, ext: options.format == .jpeg ? "jpg" : options.format.rawValue,
                                      source: "修图", recipe: EditRecipe(ops: ops, input: proxy ?? source))
    }

    func export(_ options: SaveOptions = .saved) async -> Bool {
        guard let data = await renderData(options) else { return false }
        do {
            try await PHPhotoLibrary.shared().performChanges {
                let creation = PHAssetResourceCreationOptions()
                creation.uniformTypeIdentifier = options.format.typeIdentifier
                PHAssetCreationRequest.forAsset().addResource(with: .photo, data: data, options: creation)
            }
            await addToHistory(data, options: options)
            return true
        } catch {
            return false
        }
    }
}
