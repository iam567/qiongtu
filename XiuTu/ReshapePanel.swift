import SwiftUI

/// 面部重塑里交给 AI 做的项目：表情、转头、对称这类靠挪像素做不出来的改动。
/// 只把脸部这一块发出去，结果再贴回原图。
struct ReshapeAIItem: Identifiable {
    let title: String
    let symbol: String
    let category: ReshapeCategory
    let prompt: String

    var id: String { category.rawValue + "." + title }

    var preset: AIPreset { AIPreset(title: title, symbol: symbol, prompt: prompt, faceCrop: true) }

    /// 所有项目共用的要求：只改指定的那一处，必须还是同一个人，位置和构图不能动。
    private static let rules = """
     This is a crop from a portrait photo. Change only what is described above and nothing else. \
    It must be unmistakably the same individual: keep the identity, face shape, facial proportions, skin tone, makeup, \
    hairstyle, hair colour, accessories, clothing, lighting direction and background exactly as in the input. \
    Keep the exact same framing, head size and position of everything so the result can be overlaid on the original. \
    Photorealistic, with natural skin texture.
    """

    private static func make(_ title: String, _ symbol: String, _ category: ReshapeCategory, _ change: String) -> ReshapeAIItem {
        ReshapeAIItem(title: title, symbol: symbol, category: category, prompt: change + rules)
    }

    private static let symmetry = "Make the face more symmetrical: gently even out the differences between the left and right sides " +
        "(eye size and height, eyebrow height, nostrils, mouth corners, jawline). Subtle and natural, not a mirrored face."

    static let all: [ReshapeAIItem] = [
        // 表情管理
        make("wink", "face.smiling", .expression,
             "Change only the facial expression: the person winks playfully, closing the eye on the left side of the image while the other eye stays open, with a slight natural smile."),
        make("微笑", "face.smiling", .expression,
             "Change only the facial expression: a gentle natural closed-mouth smile. Lift the corners of the mouth slightly and let the cheeks and eyes follow subtly."),
        make("嘴巴闭合", "mouth", .expression,
             "Change only the mouth: close it naturally, lips gently together and relaxed, no teeth visible."),
        make("抿嘴笑", "mouth.fill", .expression,
             "Change only the facial expression: a shy pressed-lip smile, lips pressed together with the corners of the mouth lifted."),
        make("大笑", "face.smiling.inverse", .expression,
             "Change only the facial expression: a big happy open-mouth laugh showing natural upper teeth, cheeks raised and eyes smiling."),
        make("睁眼", "eye", .expression,
             "Change only the eyes: open both eyes naturally and fully (they are closed or half closed in the input), looking toward the camera, with realistic irises, eyelids and eyelashes that match this person."),
        make("冷酷", "sunglasses", .expression,
             "Change only the facial expression: a cool, calm, serious look. Relaxed neutral mouth, no smile, steady confident gaze."),
        // 3D 塑颜
        make("对称", "square.split.2x1", .pose, symmetry),
        make("抬头", "arrow.up", .pose,
             "Change only the head pose: tilt the head slightly upward (chin up) by about 8 degrees, as if the camera were a little lower. The facial features follow the new angle consistently."),
        make("低头", "arrow.down", .pose,
             "Change only the head pose: tilt the head slightly downward (chin down) by about 8 degrees, as if the camera were a little higher. The facial features follow the new angle consistently."),
        make("左转", "arrow.turn.up.left", .pose,
             "Change only the head pose: turn the head slightly toward the left side of the image by about 10 degrees. The facial features follow the new angle consistently."),
        make("右转", "arrow.turn.up.right", .pose,
             "Change only the head pose: turn the head slightly toward the right side of the image by about 10 degrees. The facial features follow the new angle consistently."),
        // 脸型
        make("面部超清", "wand.and.rays", .shape,
             "Restore the face in very high definition: crisp eyes and eyelashes, individual eyebrow hairs, realistic skin texture with pores, clear lip texture. This is a restoration, not a redraw: every facial feature keeps exactly the same shape, size and position, and the expression and gaze do not change. Do not beautify."),
        make("面部对称", "square.split.2x1", .shape, symmetry),
        make("去双下巴", "arrow.up.to.line", .shape,
             "Remove the double chin: tighten the area under the jaw so the jawline is clean and defined. Do not change anything above the jawline."),
        // 眼睛
        make("眼神矫正", "eye.circle", .eyes,
             "Correct the gaze so both eyes look directly into the camera lens. Keep the eye shape, eye size, iris colour, eyelids and eyelashes unchanged."),
        make("对称", "square.split.2x1", .eyes,
             "Make the two eyes symmetrical: match their size, shape, height and eyelid fold to each other. Natural, and nothing else about the eyes changes."),
        make("去脂", "eye.slash", .eyes,
             "Reduce the puffiness and fat of the upper eyelids so the eyelid fold is cleaner and the eyes look more awake. Keep the eye shape and size unchanged."),
    ]

    static func items(in category: ReshapeCategory) -> [ReshapeAIItem] {
        all.filter { $0.category == category }
    }
}

/// 面部重塑面板：上面是背景保护、变形还原和重置，中间一根滑块，下面一排项目。
struct ReshapePanel: View {
    @Bindable var model: EditorModel

    var body: some View {
        let state = model.reshapeState
        VStack(spacing: 10) {
            topRow
            if state.detecting {
                HStack(spacing: 10) {
                    ProgressView().tint(.white)
                    Text("正在找人脸…").font(.system(size: 14))
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 26)
            } else if let error = state.error, !state.usable.contains(true) {
                FaceRescue(model: model, message: error.trimmingCharacters(in: CharacterSet(charactersIn: "。")))
            } else {
                if let error = state.error {
                    Text(error)
                        .font(.system(size: 12))
                        .foregroundStyle(Color(red: 1, green: 0.45, blue: 0.4))
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                if state.missing.contains(state.category) {
                    Text("这张脸的\(state.category.title)位置认不准，这一组调不了。")
                        .font(.system(size: 12))
                        .foregroundStyle(Color(red: 1, green: 0.45, blue: 0.4))
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else if state.restoring {
                    brushRow
                } else if state.key != nil {
                    sliderRow
                }
                tiles
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 12)
        .padding(.bottom, 4)
    }

    private var topRow: some View {
        let state = model.reshapeState
        return HStack(spacing: 8) {
            Chip(title: "背景保护", symbol: state.protectBusy ? "hourglass" : "person.and.background.dotted",
                 selected: state.protect) {
                model.setReshapeProtect(!state.protect)
            }
            Chip(title: "变形还原", symbol: "bandage", selected: state.restoring) {
                model.setReshapeRestoring(!state.restoring)
            }
            Spacer(minLength: 0)
            if state.usable.filter({ $0 }).count > 1 {
                HScroll {
                    HRow(spacing: 6) {
                        ForEach(state.faces.indices, id: \.self) { index in
                            if state.usable.indices.contains(index), state.usable[index] {
                                Chip(title: state.faces[index].isIdentity ? "脸\(index + 1)" : "脸\(index + 1) ✓",
                                     selected: state.faceIndex == index) { model.selectReshapeFace(index) }
                            }
                        }
                    }
                }
                .frame(maxWidth: 130)
            }
            Button { model.resetReshape() } label: {
                Image(systemName: "arrow.counterclockwise")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(state.hasChanges ? Color.white : Theme.dim)
                    .frame(width: 36, height: 34)
                    .background(Theme.chip, in: Capsule())
            }
            .buttonStyle(.plain)
            .disabled(!state.hasChanges)
            .accessibilityLabel("全部还原")
        }
    }

    private var sliderRow: some View {
        let state = model.reshapeState
        let key = state.key ?? .faceWidth
        return HStack(spacing: 12) {
            Text("\(Int((state.value * 100).rounded()))")
                .font(.system(size: 15, weight: .semibold))
                .monospacedDigit()
                .frame(width: 44, alignment: .leading)
            Slider(value: Binding(get: { Double(state.value) }, set: { model.setReshape(Float($0)) }),
                   in: key.bipolar ? -1...1 : 0...1)
            if key.paired {
                Menu {
                    ForEach(ReshapeSide.allCases) { side in
                        Button {
                            model.reshapeState.side = side
                        } label: {
                            if state.side == side {
                                Label(side.title, systemImage: "checkmark")
                            } else {
                                Text(side.title)
                            }
                        }
                    }
                } label: {
                    HStack(spacing: 4) {
                        Text(state.side.title).font(.system(size: 13, weight: .semibold))
                        Image(systemName: "chevron.up.chevron.down").font(.system(size: 10, weight: .semibold))
                    }
                    .foregroundStyle(.white)
                    .padding(.horizontal, 10)
                    .frame(height: 30)
                    .overlay(Capsule().stroke(Color(white: 0.45), lineWidth: 1))
                }
            }
            Button { model.setReshape(0) } label: {
                Image(systemName: "arrow.counterclockwise")
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(state.value == 0 ? Theme.dim : Color.white)
                    .frame(width: 32, height: 36)
            }
            .buttonStyle(.plain)
        }
    }

    /// 变形还原时：笔刷大小和撤销一笔。
    private var brushRow: some View {
        HStack(spacing: 12) {
            Image(systemName: "circle.dashed")
                .font(.system(size: 16))
                .foregroundStyle(Theme.dim)
                .frame(width: 44, alignment: .leading)
            Slider(value: Binding(get: { Double(model.reshapeState.brush) }, set: { model.reshapeState.brush = CGFloat($0) }),
                   in: 30...160)
            Button { model.undoReshapeRestore() } label: {
                Image(systemName: "arrow.uturn.backward")
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(model.reshapeState.params.restore.isEmpty ? Theme.dim : Color.white)
                    .frame(width: 36, height: 36)
            }
            .buttonStyle(.plain)
            .disabled(model.reshapeState.params.restore.isEmpty)
            .accessibilityLabel("撤销一笔")
        }
    }

    private var tiles: some View {
        let state = model.reshapeState
        return HScroll {
            HRow(spacing: 6) {
                ForEach(ReshapeAIItem.items(in: state.category)) { item in
                    IconTile(symbol: item.symbol, title: item.title, badge: "AI") { model.runReshapeAI(item) }
                }
                if !state.missing.contains(state.category) {
                    ForEach(state.category.keys) { key in
                        IconTile(symbol: key.symbol, title: key.title, selected: !state.restoring && state.key == key,
                                 modified: state.isModified(key)) {
                            model.setReshapeRestoring(false)
                            model.selectReshapeKey(key)
                        }
                    }
                }
            }
            .padding(.horizontal, 16)
        }
        .padding(.horizontal, -16)
        .id(state.category)
    }
}

/// 面部重塑时底部确认栏（✕ 和 ✓ 之间）显示的内容：表情管理 / 3D塑颜 / 比例 / 脸型 / 眼睛 …… 可以横着滑。
struct ReshapeTitle: View {
    @Bindable var model: EditorModel

    var body: some View {
        let selected = model.reshapeState.category
        ScrollViewReader { proxy in
            HScroll {
                HRow(spacing: 22) {
                    ForEach(ReshapeCategory.allCases) { category in
                        let on = category == selected
                        Button {
                            model.selectReshapeCategory(category)
                            withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo(category, anchor: .center) }
                        } label: {
                            VStack(spacing: 5) {
                                Text(category.title)
                                    .font(.system(size: 15, weight: on ? .bold : .regular))
                                    .foregroundStyle(on ? Color.white : Theme.dim)
                                Capsule().fill(on ? Theme.accent : Color.clear).frame(width: 18, height: 3)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .id(category)
                    }
                }
                .padding(.horizontal, 10)
            }
            .onAppear { proxy.scrollTo(selected, anchor: .center) }
        }
        .frame(maxWidth: .infinity)
    }
}
