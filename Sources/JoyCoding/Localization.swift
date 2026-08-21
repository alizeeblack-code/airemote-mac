import Foundation

/// 界面语言。
///
/// **英文是默认**——只有简体中文用户看到中文，繁体和其它语言一律英文。
/// 所以翻译表必须完整；漏一条就会有中文漏给英文用户看。
/// `build.sh` 里有一道检查，构建时会列出没翻译的字符串。
///
/// 用中文原文当 key 而不是 `settings.button.confirm` 这种：
/// 改造是机械的（包一层 `L(...)` 就行），对照表本身读起来就是词汇表，
/// 社区补翻译不用先去源码里查 key 对应什么。
enum Lang {
    static var isChinese: Bool {
        switch ConfigStore.shared.config.language {
        case "zh": return true
        case "en": return false
        default:
            // 只认简体。zh-Hant / zh-TW / zh-HK 走英文。
            let id = Locale.preferredLanguages.first ?? "en"
            return id.hasPrefix("zh-Hans") || id == "zh-CN"
        }
    }
}

/// 查表。中文环境直接返回原文；英文环境查不到就返回原文并在 DEBUG 下报警。
func L(_ zh: String) -> String {
    if Lang.isChinese { return Translations.zh[zh] ?? zh }
    if let en = Translations.en[zh] { return en }
    #if DEBUG
    NSLog("[JoyCoding] 未翻译: %@", zh)
    #endif
    return zh
}

/// 带插值的版本：L("已配 %@ 键", "11")
func L(_ zh: String, _ args: CVarArg...) -> String {
    String(format: L(zh), arguments: args)
}
