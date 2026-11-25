import SwiftUI

/// 摄影棚各个选项的小图标、短名字和配色。
enum StudioIcons {
    /// 去掉标题开头的 emoji 和括号里的补充，按钮上只留名字。
    static func plain(_ title: String) -> String {
        var scalars = Substring(title).unicodeScalars[...]
        while let f = scalars.first, isDecoration(f) || f == " " { scalars = scalars.dropFirst() }
        var s = String(String.UnicodeScalarView(scalars))
        if let i = s.firstIndex(where: { $0 == "（" || $0 == "(" }), i != s.startIndex { s = String(s[..<i]) }
        return s.trimmingCharacters(in: .whitespaces)
    }

    private static func isDecoration(_ u: Unicode.Scalar) -> Bool {
        if u.value == 0xFE0F || u.value == 0x200D { return true }
        if (0x1F1E6...0x1F1FF).contains(u.value) { return true }
        return u.properties.isEmoji && u.value > 0x2000
    }

    // MARK: 摄影师、器材

    static let photographerNames: [String: String] = [
        "none": "不指定", "random": "随机大师",
        "newton": "牛顿", "avedon": "阿维顿", "lindbergh": "林德伯格", "leibovitz": "莱博维茨",
        "klein": "克莱因", "lachapelle": "拉切贝尔", "walker": "蒂姆·沃克", "knight": "尼克·奈特",
        "mertmarcus": "默特马库斯", "testino": "特斯蒂诺", "demarchelier": "德马舍利耶", "inezvinoodh": "伊内兹",
        "weber": "韦伯", "teller": "泰勒", "ninagawa": "蜷川实花", "okuyama": "奥山由之",
        "hamada": "滨田英明", "kawauchi": "川内伦子", "moriyama": "森山大道", "uedashoji": "植田正治",
        "araki": "荒木经惟", "uedayoshihiko": "上田义彦", "wongdoyle": "王家卫", "shya": "夏永康",
        "hou": "侯孝贤", "yang": "杨德昌", "tsai": "蔡明亮", "anglee": "李安", "kwan": "关锦鹏",
    ]

    static func photographerName(_ option: StudioModel.Option) -> String {
        photographerNames[option.id] ?? plain(option.title)
    }

    static let equipmentNames: [String: String] = [
        "auto": "自动", "random": "随机器材",
        "portra400": "Portra 400", "portra800": "Portra 800", "gold200": "Gold 200", "ektar100": "Ektar 100",
        "fuji400h": "富士 400H", "velvia50": "Velvia 50", "cinestill800t": "800T", "cinestill50d": "50D",
        "ilfordhp5": "HP5", "ilforddelta3200": "Delta 3200", "trix400": "Tri-X 400",
        "canon5d": "佳能 5D", "sonya7": "索尼 A7", "fujifilmx": "富士 X", "leicam": "徕卡 M",
        "hasselblad": "哈苏", "phaseone": "飞思", "polaroidsx70": "SX-70", "polaroid600": "宝丽来 600",
        "instaxmini": "Instax Mini", "instaxwide": "Instax Wide", "disposable": "一次性相机",
        "lomo": "LOMO", "iphone": "iPhone", "vhs": "VHS",
    ]

    static func equipmentName(_ option: StudioModel.Option) -> String {
        equipmentNames[option.id] ?? plain(option.title)
    }

    // MARK: 时段、氛围

    /// 时段（拍人物）和氛围（拍场景）共用：id 对应图标和底色。
    static func lightSymbol(_ id: String) -> (String, Color) {
        switch id {
        case "auto": return ("wand.and.stars", .purple)
        case "random": return ("dice.fill", .purple)
        case "dawn": return ("sunrise.fill", .orange)
        case "morning": return ("sun.min.fill", .yellow)
        case "noon": return ("sun.max.fill", .yellow)
        case "afternoon": return ("sun.haze.fill", .orange)
        case "goldenhour", "golden": return ("sun.horizon.fill", .orange)
        case "bluehour", "blue": return ("moon.haze.fill", .blue)
        case "night": return ("moon.stars.fill", .indigo)
        case "latenight": return ("moon.zzz.fill", .indigo)
        case "sunny": return ("sun.max.fill", .yellow)
        case "cloudy": return ("cloud.sun.fill", .cyan)
        case "overcast": return ("cloud.fill", .gray)
        case "rain", "rainy": return ("cloud.rain.fill", .blue)
        case "afterrain": return ("cloud.sun.rain.fill", .teal)
        case "snow", "snowy": return ("cloud.snow.fill", .cyan)
        case "fog", "foggy": return ("cloud.fog.fill", .gray)
        case "spring": return ("camera.macro", .pink)
        case "summer": return ("sun.max.fill", .green)
        case "autumn": return ("leaf.fill", .orange)
        case "winter": return ("snowflake", .cyan)
        case "soft": return ("sun.haze.fill", .gray)
        case "hard": return ("sun.max.fill", .yellow)
        case "side": return ("circle.lefthalf.filled", .orange)
        case "back": return ("sun.and.horizon.fill", .orange)
        case "window": return ("window.casement", .teal)
        case "beam": return ("rays", .yellow)
        case "neon": return ("lightbulb.led.fill", .pink)
        case "lowkey": return ("moon.fill", .indigo)
        case "highkey": return ("sun.min.fill", .white)
        default: return ("circle.dashed", .gray)
        }
    }

    static func moodGroupSymbol(_ group: SceneLook.Group) -> String {
        switch group {
        case .time: return "clock.fill"
        case .weather: return "cloud.sun.fill"
        case .season: return "leaf.fill"
        case .light: return "lightbulb.fill"
        }
    }

    // MARK: 人物

    static func personGroupSymbol(_ raw: String) -> String {
        switch raw {
        case "gender": return "person.2.fill"
        case "persona": return "theatermasks.fill"
        case "age": return "hourglass"
        case "beauty": return "sparkles"
        case "retouch": return "wand.and.stars"
        case "hair": return "paintbrush.fill"
        default: return "circle"
        }
    }

    /// 穿裙子的小人 iOS 18 才有，之前的系统用男女并排的那个。
    static var dressSymbol: String {
        if #available(iOS 18.0, *) { return "figure.stand.dress" }
        return "figure.dress.line.vertical.figure"
    }

    static let genderSymbols: [String: String] = [
        "auto": "wand.and.stars", "female": dressSymbol, "male": "figure.stand",
        "androgynous": "circle.lefthalf.filled",
    ]

    static let ageSymbols: [String: String] = ["original": "person.crop.circle"]

    static let beautySymbols: [String: String] = [
        "none": "circle.dashed", "subtle": "sparkle", "medium": "sparkles", "strong": "wand.and.stars",
    ]

    static let retouchSymbols: [String: String] = [
        "skin": "drop.fill", "eyes": "eye.fill", "nose": "nose.fill", "lips": "mouth.fill",
        "face": "face.smiling", "hair": "comb.fill", "neck": "person.bust", "body": "figure.stand",
    ]

    static let personaSymbols: [String: String] = [
        "random": "dice.fill", "seiso": "drop.fill", "kawaii": "heart.fill", "gyaru": "sparkles",
        "jirai": "bolt.heart.fill", "onee": "eyeglasses", "nightclub": "wineglass.fill", "queen": "crown.fill",
        "cabaret": "sparkles", "jk": "backpack.fill", "business": "briefcase.fill", "scholar": "book.fill",
        "athlete": "figure.run", "fitness": "dumbbell.fill", "rocker": "guitars.fill", "gentleman": "mustache.fill",
        "kpopboy": "music.mic", "cityboy": "building.2.fill", "bachelor": "house.fill", "artist": "paintpalette.fill",
        "natural": "leaf.fill", "half": "globe.europe.africa.fill", "coser": "theatermasks.fill", "alt": "bolt.fill",
        "hkretro": "film.fill", "kclean": "drop", "genki": "sun.max.fill", "lolita": "suit.heart.fill",
        "ryousan": "heart.circle.fill",
    ]

    // MARK: 摄影分组、品牌

    static func cameraGroupSymbol(_ raw: String) -> String {
        switch raw {
        case "photographer": return "camera.fill"
        case "equipment": return "film.fill"
        case "time": return "sun.max.fill"
        case "brands": return "tag.fill"
        default: return "circle"
        }
    }

    static func brandCategorySymbol(_ title: String) -> String {
        let rules: [(String, String)] = [
            ("包", "handbag.fill"), ("表", "watch.analog"), ("珠宝", "diamond.fill"), ("首饰", "diamond.fill"),
            ("车", "car.side.fill"), ("服", "hanger"), ("生活", "wineglass.fill"),
        ]
        return rules.first { title.contains($0.0) }?.1 ?? "tag.fill"
    }

    /// 单品自己的图标；没有合适的就用所在大类的图标。
    static func brandItemSymbol(_ option: StudioModel.Option, category: String) -> String {
        let rules: [(String, String)] = [
            ("香槟", "wineglass.fill"), ("威士忌", "wineglass.fill"), ("XO", "wineglass.fill"), ("路易十三", "wineglass.fill"),
            ("耳机", "headphones"), ("AirPods", "headphones"), ("iPhone", "iphone"), ("相机", "camera.fill"),
            ("行李箱", "suitcase.rolling.fill"), ("鞋", "shoe.fill"), ("高跟", "shoe.fill"), ("丝巾", "hanger"),
        ]
        return rules.first { option.title.contains($0.0) }?.1 ?? brandCategorySymbol(category)
    }

    /// 拍场景的拍法。
    static let variationSymbols: [String: String] = [
        "keep": "photo", "wide": "arrow.up.left.and.arrow.down.right", "detail": "plus.magnifyingglass",
        "angle": "arrow.triangle.2.circlepath.camera", "low": "arrow.up.to.line", "high": "arrow.down.to.line",
        "symmetric": "square.split.2x1", "frame": "rectangle.inset.filled",
    ]

    // MARK: 场景

    /// 按关键词给场景大类挑图标。
    static func categorySymbol(_ title: String) -> String {
        let rules: [(String, String)] = [
            ("东京", "building.2.fill"), ("关西", "storefront.fill"), ("京都", "building.columns.fill"),
            ("氛围", "moon.stars.fill"), ("传统", "fireworks"), ("韩国", "bag.fill"), ("中国", "mountain.2.fill"),
            ("美国", "star.fill"), ("英国", "crown.fill"), ("酒店", "bed.double.fill"), ("校园", "graduationcap.fill"),
            ("海岛", "beach.umbrella.fill"), ("海边", "beach.umbrella.fill"), ("咖啡", "cup.and.saucer.fill"),
            ("夜", "moon.stars.fill"), ("街", "building.2.fill"), ("都市", "globe.europe.africa.fill"),
        ]
        return rules.first { title.contains($0.0) }?.1 ?? "mappin.and.ellipse"
    }

    private static let night = Color.indigo, water = Color.teal, green = Color.green, warm = Color.orange
    private static let pink = Color.pink, gold = Color.yellow, art = Color.purple, city = Color.blue, calm = Color.gray

    /// 按关键词给场景挑图标和底色，前面的规则优先；都对不上就用大类的图标。
    private static let sceneRules: [(String, String, Color)] = [
        // 地名里带"海""江""湾"之类字的，先单独认出来。
        ("外滩", "building.2.fill", city), ("田子坊", "house.fill", warm), ("新天地", "building.2.fill", city),
        ("江南", "building.2.fill", city), ("古城", "house.fill", warm), ("铜锣湾", "bag.fill", pink),
        ("中环", "building.2.fill", city), ("海神庙", "building.columns.fill", gold),
        ("贩卖机", "refrigerator.fill", night), ("居酒屋", "fork.knife", warm), ("弹珠", "circle.grid.3x3.fill", art),
        ("便利店", "storefront.fill", night), ("练歌房", "music.mic", art), ("KTV", "music.mic", art),
        ("电车", "tram.fill", city), ("地铁", "tram.fill", city), ("车站", "train.side.front.car", city),
        ("樱", "camera.macro", pink), ("红叶", "leaf.fill", warm), ("雪", "snowflake", water),
        ("烟花", "fireworks", night), ("祭", "fireworks", warm), ("盆踊", "figure.socialdance", warm),
        ("和服", dressSymbol, pink), ("浴衣", dressSymbol, pink),
        ("舞妓", dressSymbol, pink), ("温泉", "bathtub.fill", water),
        ("榻榻米", "house.lodge.fill", calm), ("茶道", "cup.and.saucer.fill", green),
        ("夜", "moon.stars.fill", night), ("歌舞伎町", "moon.stars.fill", night),
        ("咖啡", "cup.and.saucer.fill", warm), ("早餐", "cup.and.saucer.fill", warm),
        ("酒吧", "wineglass.fill", art), ("泳池", "figure.pool.swim", water), ("浴室", "bathtub.fill", water),
        ("电梯", "arrow.up.arrow.down.square.fill", calm), ("大堂", "sofa.fill", gold), ("阳台", "sun.horizon.fill", warm),
        ("套房", "bed.double.fill", gold), ("宿舍", "bed.double.fill", calm),
        ("教室", "studentdesk", calm), ("走廊", "door.left.hand.open", calm), ("保健室", "cross.case.fill", calm),
        ("操场", "figure.run", green), ("天台", "building.fill", city), ("楼梯", "stairs", calm),
        ("办公室", "briefcase.fill", calm), ("图书馆", "books.vertical.fill", warm), ("食堂", "fork.knife", warm),
        ("校门", "door.left.hand.open", calm), ("小树林", "tree.fill", green), ("大学", "graduationcap.fill", city),
        ("剑桥", "graduationcap.fill", city), ("牛津", "graduationcap.fill", city),
        ("珊瑚", "fish.fill", water), ("环礁", "fish.fill", water), ("水上屋", "water.waves", water),
        ("梯田", "mountain.2.fill", green), ("七色土", "mountain.2.fill", warm),
        ("海", "beach.umbrella.fill", water), ("岛", "beach.umbrella.fill", water), ("湾", "beach.umbrella.fill", water),
        ("鹿", "pawprint.fill", green), ("熊猫", "pawprint.fill", green), ("竹林", "tree.fill", green),
        ("公园", "tree.fill", green), ("园林", "tree.fill", green), ("乡村", "house.lodge.fill", green),
        ("牧场", "figure.equestrian.sports", warm), ("巨石阵", "mountain.2.fill", calm),
        ("天文台", "binoculars.fill", night), ("拉斯维加斯", "dice.fill", art), ("星光大道", "star.fill", gold),
        ("河", "water.waves", water), ("江", "water.waves", water), ("西湖", "water.waves", water), ("港", "ferry.fill", water),
        ("大桥", "road.lanes", city), ("塔桥", "road.lanes", city), ("金门", "road.lanes", city),
        ("寺", "building.columns.fill", gold), ("神社", "building.columns.fill", gold), ("鸟居", "building.columns.fill", gold),
        ("宫", "building.columns.fill", gold), ("城", "building.columns.fill", gold), ("钟楼", "building.columns.fill", gold),
        ("清真寺", "building.columns.fill", gold), ("高迪", "building.columns.fill", gold), ("红场", "building.columns.fill", gold),
        ("雷门", "building.columns.fill", gold), ("大本钟", "building.columns.fill", gold),
        ("壁画", "paintpalette.fill", art), ("艺术", "paintpalette.fill", art), ("文化村", "paintpalette.fill", art),
        ("文艺", "paintpalette.fill", art), ("彩色屋", "house.fill", pink), ("蓝顶", "house.fill", city),
        ("韩屋", "house.fill", warm), ("胡同", "house.fill", warm), ("古", "house.fill", warm), ("老城", "house.fill", warm),
        ("石板路", "house.fill", warm), ("旧街", "house.fill", warm), ("巷", "house.fill", warm), ("田子坊", "house.fill", warm),
        ("九曲", "road.lanes", pink), ("市场", "basket.fill", warm), ("商业", "bag.fill", pink), ("精品", "bag.fill", pink),
        ("时尚", "bag.fill", pink), ("明洞", "bag.fill", pink), ("中环", "building.2.fill", city),
        ("塔", "building.2.fill", city), ("哈利法", "building.2.fill", city), ("歌剧院", "building.columns.fill", gold),
        ("云门", "circle.fill", city), ("广场", "building.2.fill", city), ("十字路口", "figure.walk", city),
        ("街", "building.2.fill", city), ("都市", "building.2.fill", city), ("外滩", "building.2.fill", city),
        ("新天地", "building.2.fill", city), ("洪崖洞", "building.2.fill", night),
    ]

    /// 太长的场景名在格子上放不下，换个短的叫法。
    private static let shortSceneNames: [String: String] = [
        "伊斯坦布尔蓝色清真寺": "蓝色清真寺", "巴塞罗那高迪建筑": "高迪建筑", "EDITION酒店套房": "EDITION 套房",
        "北京798艺术区": "798 艺术区", "纽约SOHO街拍": "SOHO 街拍",
    ]

    static func sceneName(_ title: String) -> String {
        shortSceneNames[title] ?? title
    }

    static func sceneSymbol(_ title: String, category: String) -> (String, Color) {
        if let rule = sceneRules.first(where: { title.contains($0.0) }) { return (rule.1, rule.2) }
        return (categorySymbol(category), calm)
    }

    /// 发色色块；彩虹挑染是渐变。
    static func swatch(_ value: String?) -> AnyShapeStyle {
        guard let value else { return AnyShapeStyle(Color.gray) }
        let colors = value.components(separatedBy: "#").dropFirst().compactMap { Color(hex: String($0.prefix(6))) }
        if colors.count > 1 { return AnyShapeStyle(AngularGradient(colors: colors + [colors[0]], center: .center)) }
        return AnyShapeStyle(colors.first ?? .gray)
    }
}

private extension Color {
    init?(hex: String) {
        guard hex.count == 6, let v = UInt32(hex, radix: 16) else { return nil }
        self.init(red: Double((v >> 16) & 0xff) / 255, green: Double((v >> 8) & 0xff) / 255, blue: Double(v & 0xff) / 255)
    }
}

/// 摄影棚的选项格子：有图就放图，没图就是带底色的图标；选中时描一圈强调色。
struct PickTile: View {
    let title: String
    var image: UIImage? = nil
    var symbol: String? = nil
    var tint: Color = .gray
    let selected: Bool
    var width: CGFloat = StudioLooks.tileWidth
    var height: CGFloat = StudioLooks.tileHeight
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 5) {
                ZStack {
                    Color(white: 0.16)
                    if let image {
                        Image(uiImage: image).resizable().scaledToFill()
                    } else {
                        // 深灰底，图标后面透一点它自己的颜色。
                        RadialGradient(colors: [tint.opacity(0.32), tint.opacity(0.0)],
                                       center: .center, startRadius: 4, endRadius: 46)
                        if let symbol {
                            Image(systemName: symbol)
                                .font(.system(size: 23, weight: .regular))
                                .symbolRenderingMode(.multicolor)
                                .foregroundStyle(.white)
                        }
                    }
                }
                .frame(width: width, height: height)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .stroke(selected ? Theme.accent : Color.clear, lineWidth: 2.5)
                )
                Text(title)
                    .font(.system(size: 11.5, weight: selected ? .semibold : .regular))
                    .foregroundStyle(selected ? Theme.accent : Color.white)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                    .frame(width: width + 4)
            }
        }
        .buttonStyle(PressStyle())
    }
}

/// 一排横向滚动的格子。
struct TileRow<Item: Identifiable, Tile: View>: View {
    let items: [Item]
    @ViewBuilder var tile: (Item) -> Tile

    var body: some View {
        HScroll {
            HRow(spacing: 8) {
                ForEach(items) { tile($0) }
            }
            .padding(.vertical, 2)
        }
    }
}

/// 一排横向滚动的小标签，每个前面带图标（没有合适图标的就只有文字）。
struct SymbolChipRow<Item: Identifiable>: View {
    let items: [Item]
    let title: (Item) -> String
    let symbol: (Item) -> String?
    let isSelected: (Item) -> Bool
    let onTap: (Item) -> Void

    var body: some View {
        HScroll {
            HRow(spacing: 8) {
                ForEach(items) { item in
                    Chip(title: title(item), symbol: symbol(item), selected: isSelected(item)) { onTap(item) }
                }
            }
        }
    }
}

/// 发色：小标签前面是一个色块。
struct SwatchChip: View {
    let title: String
    let swatch: AnyShapeStyle
    let selected: Bool
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Circle().fill(swatch)
                    .frame(width: 16, height: 16)
                    .overlay(Circle().stroke(Color.white.opacity(0.35), lineWidth: 1))
                Text(title).font(.system(size: 14, weight: selected ? .semibold : .regular))
            }
            .foregroundStyle(selected ? Color.black : Color.white)
            .padding(.leading, 9)
            .padding(.trailing, 14)
            .padding(.vertical, 7)
            .background(selected ? Color.white : Theme.chip, in: Capsule())
        }
        .buttonStyle(.plain)
    }
}
