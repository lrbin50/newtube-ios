import SwiftUI

/// Standard, extensible localization layer.
///
/// To add a new language:
///   1. Add a case to `AppLanguage` with its locale identifier.
///   2. Add a `[String: String]` table under that case in `L10n.strings`.
///   3. Add the display name in `AppLanguage.label`.
/// No view code needs to change — all text resolves through `L10n.tr(...)`.
enum AppLanguage: String, CaseIterable, Identifiable {
    case system = "system"
    case english = "en"
    case simplifiedChinese = "zh-Hans"

    var id: String { rawValue }

    var label: String {
        switch self {
        case .system: return L10n.tr("lang.system", fallback: "Follow System")
        case .english: return "English"
        case .simplifiedChinese: return "简体中文"
        }
    }
}

/// Resolves the effective language from the user's choice (`.system` follows
/// the device locale) and serves localized strings with a safe fallback.
final class L10n: ObservableObject {
    static let shared = L10n()

    @Published var language: AppLanguage {
        didSet { UserDefaults.standard.set(language.rawValue, forKey: "appLanguage") }
    }

    private init() {
        let saved = UserDefaults.standard.string(forKey: "appLanguage") ?? AppLanguage.system.rawValue
        language = AppLanguage(rawValue: saved) ?? .system
    }

    /// The concrete language to use, resolving "Follow System" via device locale.
    var effective: AppLanguage {
        guard language == .system else { return language }
        let code = Locale.current.languageCode?.lowercased() ?? "en"
        return code.hasPrefix("zh") ? .simplifiedChinese : .english
    }

    /// Look up a localized string. Falls back to English, then to the key.
    static func tr(_ key: String, fallback: String? = nil) -> String {
        let lang = L10n.shared.effective
        return strings[lang]?[key] ?? strings[.english]?[key] ?? fallback ?? key
    }

    /// Instance convenience for SwiftUI views that observe changes.
    func tr(_ key: String, fallback: String? = nil) -> String { L10n.tr(key, fallback: fallback) }

    /// Keys are stable identifiers; values can be edited without touching views.
    private static let strings: [AppLanguage: [String: String]] = [
        .english: [
            "lang.system": "Follow System",
            "tab.home": "Home", "tab.shorts": "Shorts", "tab.subscriptions": "Subscriptions", "tab.you": "You",
            "action.account": "Account", "action.openYouTube": "Open YouTube", "action.search": "Search YouTube",
            "chip.all": "All", "chip.music": "Music", "chip.podcasts": "Podcasts", "chip.mixes": "Mixes",
            "chip.live": "Live", "chip.travel": "Travel", "chip.recent": "Recently uploaded",
            "chip.watched": "Watched", "chip.newToYou": "New to you",
            "signin.title": "Sign in to YouTube",
            "signin.desc": "Sign in with your Google account to see personalized recommendations, subscriptions and search.",
            "signin.button": "Sign in",
            "common.loading": "Loading…", "common.retry": "Retry", "common.ok": "OK", "common.back": "Back",
            "common.share": "Share", "common.download": "Download", "common.save": "Save",
            "common.saved": "Saved", "common.like": "Like", "common.dislike": "Dislike",
            "common.comments": "Comments", "common.channel": "Channel", "common.subscribers": "subscribers",
            "comments.title": "Comments", "comments.guidelines": "Please follow the YouTube Community Guidelines when commenting. ",
            "comments.learnMore": "Learn more", "comments.placeholder": "Add a comment...",
            "comments.send": "Send", "comments.replies": "replies", "comments.loadMore": "Load more",
            "comments.signInHint": "Sign in to join the conversation", "comments.empty": "No comments yet",
            "comments.failed": "Couldn't load comments", "comments.postFailed": "Couldn't post comment",
            "common.subscribe": "Subscribe", "common.subscribed": "Subscribed",
            "player.upNext": "Up next", "player.moreActions": "More actions",
            "player.quality": "Quality", "player.subtitles": "Subtitles", "player.speed": "Playback speed",
            "player.pip": "Picture in Picture", "player.more": "More", "player.auto": "Auto",
            "player.off": "Off", "player.normal": "Normal", "player.settings": "Settings",
            "player.loading": "Loading…",
            "player.saveTo": "Save to playlist",
            "player.saveTo.empty": "Sign in to see your playlists.",
            "player.saveTo.failed": "Couldn't add to this playlist.",
            "card.watchLater": "Add to Watch later", "card.notInterested": "Not interested",
            "settings.title": "Settings", "settings.language": "Language",
            "settings.playback": "Playback", "settings.defaultSpeed": "Default speed",
            "settings.community": "Community services",
            "settings.community.footer": "Enabled services receive the current video ID. SponsorBlock supplies segments, DeArrow supplies titles, and Return YouTube Dislike supplies counts.",
            "settings.skipSponsors": "Skip sponsors and self-promotion",
            "settings.dearrow": "Show DeArrow titles", "settings.dislikes": "Show estimated dislikes",
            "settings.playOnTV": "Play on TV",
            "settings.tv.footer": "Find the pairing code in SmartTube or YouTube on your TV. After pairing, select your TV in the player menu.",
            "settings.pairedTV": "Paired TV", "settings.forgetTV": "Forget TV",
            "settings.tvCode": "12-digit TV code", "settings.pairTV": "Pair TV", "settings.pairing": "Pairing…",
            "settings.library": "Library", "settings.clearHistory": "Clear local watch history",
            "settings.about": "About", "settings.credits": "Credits and licenses",
            "settings.account": "Account", "settings.signedInAs": "Signed in as",
            "settings.signOut": "Sign out",
            "you.history": "History", "you.playlists": "Playlists", "you.myVideos": "Your videos",
            "you.films": "Films", "you.watchTime": "Watch time", "you.viewChannel": "View channel",
            "you.creator": "Creator", "you.googleAccount": "Google Account",
            "you.incognito": "Turn on Incognito", "you.shareSettings": "Share or settings",
            "you.signedIn": "Signed in", "you.switchAccount": "Sign in / switch account",
            "you.playlists.empty": "Sign in to see your playlists.",
            "you.playlists.failed": "Couldn't load your playlists. Tap Retry.",
            "feed.failed": "Couldn't load the feed",
            "subscriptions.empty": "No subscriptions yet. Subscribe to channels to see their videos here.",
            "feed.notSignedIn": "Sign in to see your home feed",
            "you.saved.desc": "Save videos with Watch later from the player menu.",
            "you.downloads.desc": "Download a video or its audio from the player menu to play it offline.",
            "you.history.desc": "Videos you play appear here.",
            "you.watchTime.desc": "Your total watch time appears here as you play videos.",
            "you.addToQueue": "Add to queue", "you.removeSaved": "Remove from Watch later",
            "you.deleteDownload": "Delete download", "you.playAll": "Play all",
            "you.shuffle": "Shuffle", "you.play": "Play",
            "you.watchLater": "Watch later", "you.private.playlist": "Private · Playlist",
            "you.videoCount": "%d videos",
            "channel.analytics": "Analytics", "channel.edit": "Edit channel",
            "channel.posts": "Posts", "channel.posts.empty": "No posts yet",
            "channel.latest": "Latest", "channel.sort.newest": "Newest",
            "channel.tab.home": "Home", "channel.tab.videos": "Videos",
            "channel.tab.shorts": "Shorts", "channel.tab.playlists": "Playlists",
            "channel.tab.community": "Community", "channel.tab.coming": "Coming soon",
            "channel.videos.empty": "No videos yet",
            "playlist.empty": "No videos in this playlist yet.",
            "movies.tab.browse": "Browse", "movies.tab.free": "Free (with ads)",
            "movies.tab.live": "Live", "movies.tab.purchases": "Purchases",
            "movies.tab.store": "Store",
            "movies.empty": "No movies here yet.", "movies.more": "More",
        ],
        .simplifiedChinese: [
            "lang.system": "跟随系统",
            "tab.home": "首页", "tab.shorts": "Shorts", "tab.subscriptions": "订阅", "tab.you": "我",
            "action.account": "账号", "action.openYouTube": "打开 YouTube", "action.search": "搜索 YouTube",
            "chip.all": "全部", "chip.music": "音乐", "chip.podcasts": "播客", "chip.mixes": "混排",
            "chip.live": "直播", "chip.travel": "旅行", "chip.recent": "最近上传",
            "chip.watched": "已观看", "chip.newToYou": "为你推荐",
            "signin.title": "登录 YouTube",
            "signin.desc": "使用你的 Google 账号登录，查看个性化推荐、订阅内容和搜索结果。",
            "signin.button": "登录",
            "common.loading": "加载中…", "common.retry": "重试", "common.ok": "好", "common.back": "返回",
            "common.share": "分享", "common.download": "下载", "common.save": "保存",
            "common.saved": "已保存", "common.like": "点赞", "common.dislike": "点踩",
            "common.comments": "评论", "common.channel": "频道", "common.subscribers": "位订阅者",
            "comments.title": "评论", "comments.guidelines": "请务必遵守《YouTube 社区准则》，文明发表评论。",
            "comments.learnMore": "了解详情", "comments.placeholder": "评论...",
            "comments.send": "发送", "comments.replies": "条回复", "comments.loadMore": "加载更多",
            "comments.signInHint": "登录后即可发表评论", "comments.empty": "还没有评论",
            "comments.failed": "无法加载评论", "comments.postFailed": "评论发送失败",
            "common.subscribe": "订阅", "common.subscribed": "已订阅",
            "player.upNext": "即将播放", "player.moreActions": "更多操作",
            "player.quality": "画质", "player.subtitles": "字幕", "player.speed": "播放速度",
            "player.pip": "画中画", "player.more": "更多", "player.auto": "自动",
            "player.off": "关", "player.normal": "正常", "player.settings": "设置",
            "player.loading": "加载中…",
            "player.saveTo": "保存到播放列表",
            "player.saveTo.empty": "登录后才能看到你的播放列表。",
            "player.saveTo.failed": "添加到该播放列表失败。",
            "card.watchLater": "添加到稍后观看", "card.notInterested": "不感兴趣",
            "settings.title": "设置", "settings.language": "语言",
            "settings.playback": "播放", "settings.defaultSpeed": "默认速度",
            "settings.community": "社区服务",
            "settings.community.footer": "启用的服务会收到当前视频 ID。SponsorBlock 提供跳过片段，DeArrow 提供标题，Return YouTube Dislike 提供点踩数。",
            "settings.skipSponsors": "跳过赞助和自我介绍",
            "settings.dearrow": "显示 DeArrow 标题", "settings.dislikes": "显示估算点踩数",
            "settings.playOnTV": "投屏到电视",
            "settings.tv.footer": "在电视上的 SmartTube 或 YouTube 中查找配对码。配对后，在播放器菜单中选择你的电视。",
            "settings.pairedTV": "已配对电视", "settings.forgetTV": "忘记电视",
            "settings.tvCode": "12 位电视配对码", "settings.pairTV": "配对电视", "settings.pairing": "配对中…",
            "settings.library": "资料库", "settings.clearHistory": "清除本地观看历史",
            "settings.about": "关于", "settings.credits": "鸣谢与许可",
            "settings.account": "账号", "settings.signedInAs": "已登录账号",
            "settings.signOut": "退出登录",
            "you.history": "历史记录", "you.playlists": "播放列表", "you.myVideos": "我的视频",
            "you.films": "影视", "you.watchTime": "观看时长", "you.viewChannel": "查看频道",
            "you.creator": "创作者", "you.googleAccount": "Google 账号",
            "you.incognito": "开启无痕模式", "you.shareSettings": "分享或设置",
            "you.signedIn": "已登录", "you.switchAccount": "登录 / 切换账号",
            "you.playlists.empty": "登录后即可查看你的播放列表。",
            "you.playlists.failed": "播放列表加载失败，请点击重试。",
            "feed.failed": "无法加载首页内容",
            "subscriptions.empty": "还没有订阅频道。订阅频道后，这里会显示它们的最新视频。",
            "feed.notSignedIn": "登录后查看首页推荐",
            "you.saved.desc": "在播放器菜单中点击“稍后观看”即可保存视频。",
            "you.downloads.desc": "在播放器菜单中下载视频或音频，即可离线播放。",
            "you.history.desc": "你播放过的视频会出现在这里。",
            "you.watchTime.desc": "播放视频后，你的观看时长会显示在这里。",
            "you.addToQueue": "添加到队列", "you.removeSaved": "从稍后观看移除",
            "you.deleteDownload": "删除下载", "you.playAll": "全部播放",
            "you.shuffle": "随机播放", "you.play": "播放",
            "you.watchLater": "稍后观看", "you.private.playlist": "私享 · 播放列表",
            "you.videoCount": "%d 个视频",
            "channel.analytics": "数据分析", "channel.edit": "修改频道",
            "channel.posts": "帖子", "channel.posts.empty": "暂无帖子",
            "channel.latest": "最新发布", "channel.sort.newest": "最新",
            "channel.tab.home": "首页", "channel.tab.videos": "视频",
            "channel.tab.shorts": "Shorts", "channel.tab.playlists": "播放列表",
            "channel.tab.community": "社区", "channel.tab.coming": "敬请期待",
            "channel.videos.empty": "暂无视频",
            "playlist.empty": "这个播放列表还没有视频。",
            "movies.tab.browse": "浏览", "movies.tab.free": "免费（含广告）",
            "movies.tab.live": "直播", "movies.tab.purchases": "购买的内容",
            "movies.tab.store": "商店",
            "movies.empty": "这里暂时没有影片。", "movies.more": "更多",
        ],
    ]
}
