// Tacet's logic tests. Run with: tools/test.sh
// They use only pure functions and temporary files: nothing touches your Tacet data.
import Foundation
import CoreText
import CryptoKit
import JavaScriptCore
import SQLite3
import UniformTypeIdentifiers
import WebKit

var failures = 0
var passed = 0

func check(_ ok: Bool, _ name: String, _ detail: @autoclosure () -> String = "") {
    if ok { passed += 1 } else { failures += 1; print("FAIL  \(name)  \(detail())") }
}

func eq<T: Equatable>(_ a: T, _ b: T, _ name: String) { check(a == b, name, "got \(a), want \(b)") }

// MARK: Address bar

func resolved(_ s: String) -> String? { InputResolver.resolve(s)?.absoluteString }

eq(resolved("reddit.com"), "https://reddit.com", "address: bare domain")
eq(resolved("  reddit.com  "), "https://reddit.com", "address: trims spaces")
eq(resolved("http://example.com"), "http://example.com", "address: keeps http")
eq(resolved("localhost:3000/x"), "http://localhost:3000/x", "address: localhost with port")
eq(resolved("192.168.1.10"), "http://192.168.1.10", "address: IP")
eq(resolved("bbc.co.uk/news"), "https://bbc.co.uk/news", "address: path")
check(resolved("reddit")?.contains("q=reddit") == true, "search: single word", resolved("reddit") ?? "nil")
check(resolved("how are you")?.contains("how%20are%20you") == true, "search: spaces encoded", resolved("how are you") ?? "nil")
check(resolved("c++ & rust")?.contains("c%2B%2B%20%26%20rust") == true, "search: + and & encoded", resolved("c++ & rust") ?? "nil")
check(resolved("yt lofi")?.hasPrefix("https://www.youtube.com/results?search_query=lofi") == true, "search shortcut", resolved("yt lofi") ?? "nil")
check(resolved("file.txt") != nil, "address: unknown TLD searches instead of failing")
eq(resolved(""), nil, "address: empty")
check(resolved("münchen.de") != nil, "address: international domain", "nil")
check(resolved("javascript:alert(1)").map { !$0.hasPrefix("javascript:") } ?? true, "address: javascript: is not opened as a page", resolved("javascript:alert(1)") ?? "")
eq(InputResolver.displayHost(URL(string: "https://www.apple.com/mac")), "apple.com", "display host strips www")
check(InputResolver.isInternational(URL(string: "https://xn--pple-43d.com")), "punycode warning")
check(!InputResolver.isInternational(URL(string: "https://apple.com")), "no warning for plain host")

// MARK: Link cleaning

eq(URLCleaner.clean(URL(string: "https://shop.example.com/item?id=42&utm_source=x&fbclid=y&gclid=z")!)?.absoluteString,
   "https://shop.example.com/item?id=42", "clean: tracking params")
eq(URLCleaner.clean(URL(string: "https://example.com/?id=1")!), nil, "clean: nothing to remove")
eq(URLCleaner.clean(URL(string: "https://example.com/?utm_medium=a")!)?.absoluteString, "https://example.com/", "clean: all params removed")
eq(URLCleaner.unwrap(URL(string: "https://www.google.com/url?q=https://example.com/a%3Futm_source%3Dx&sa=D")!)?.absoluteString,
   "https://example.com/a", "unwrap: google redirect")
eq(URLCleaner.unwrap(URL(string: "https://www.google.com/url?q=javascript:alert(1)")!), nil, "unwrap: refuses non-http targets")

// MARK: HTTPS upgrade

check(HTTPSUpgrade.eligible(URL(string: "http://example.com")!), "https: eligible")
check(!HTTPSUpgrade.eligible(URL(string: "http://localhost:8080")!), "https: not localhost")
check(!HTTPSUpgrade.eligible(URL(string: "http://192.168.0.1")!), "https: not IP")
check(!HTTPSUpgrade.eligible(URL(string: "https://example.com")!), "https: already https")
eq(HTTPSUpgrade.upgraded(URL(string: "http://example.com:80/a?b=1")!)?.absoluteString, "https://example.com/a?b=1", "https: drops port 80")

// MARK: Sites for passwords

let pslPairs = [("alice.github.io", "alice.github.io"), ("a.b.evil.github.io", "evil.github.io"), ("www.bbc.co.uk", "bbc.co.uk"),
                ("mail.google.com", "google.com"), ("foo.netlify.app", "foo.netlify.app"), ("localhost", "localhost"),
                ("192.168.1.10", "192.168.1.10"), ("accounts.example.com", "example.com"), ("WWW.Example.COM", "example.com"),
                ("github.io", "github.io"), ("a.b.ck", "a.b.ck"), ("www.ck", "www.ck")]
for (host, site) in pslPairs { eq(PasswordStore.site(host), site, "site(\(host))") }
check(PasswordStore.site("alice.github.io") != PasswordStore.site("evil.github.io"), "shared domain sites stay apart")

// MARK: CSV

eq(CSV.parse("a,b\n1,2\n"), [["a", "b"], ["1", "2"]], "csv: simple")
eq(CSV.parse("a,\"b,c\",\"d \"\"q\"\"\"\r\n"), [["a", "b,c", "d \"q\""]], "csv: quotes and CRLF")
eq(CSV.parse("x,\"multi\nline\"\n"), [["x", "multi\nline"]], "csv: newline inside quotes")
eq(CSV.parse(""), [], "csv: empty")
for s in ["plain", "a,b", "say \"hi\"", "two\nlines"] { eq(CSV.parse(CSV.escape(s) + "\n").first?.first, s, "csv: round trip \(s.debugDescription)") }

// MARK: Downloads

eq(DownloadManager.safeName("../../evil.command"), "evil.command", "download name: no parent path")
eq(DownloadManager.safeName("/etc/passwd"), "passwd", "download name: no absolute path")
eq(DownloadManager.safeName("a:b.txt"), "a-b.txt", "download name: colon")
eq(DownloadManager.safeName(".hidden"), "hidden", "download name: no hidden file")
eq(DownloadManager.safeName(""), nil, "download name: empty")
eq(DownloadManager.safeName("report.pdf"), "report.pdf", "download name: normal")
check(DownloadManager.isDangerous("Setup.PKG"), "dangerous: pkg, any case")
check(!DownloadManager.isDangerous("photo.jpg"), "not dangerous: jpg")

// MARK: Updates

eq(UpdateChecker.version(fromTag: "v1.5.4"), "1.5.4", "tag v1.5.4")
eq(UpdateChecker.version(fromTag: "v1.6-beta"), "1.6", "tag with suffix")
check(UpdateChecker.isNewer("1.6", than: "1.5.4"), "1.6 > 1.5.4")
check(UpdateChecker.isNewer("1.10", than: "1.9"), "1.10 > 1.9")
check(!UpdateChecker.isNewer("1.5", than: "1.5.0"), "1.5 == 1.5.0")
check(!UpdateChecker.isNewer("1.5.3", than: "1.5.4"), "1.5.3 < 1.5.4")

// MARK: Welcome pages
eq(Set(WhatsNew.pages(since: "1.7").map(\.version)), ["1.7.1", "1.8"], "welcome after 1.7: the 1.7.1 and 1.8 pages")
eq(Set(WhatsNew.pages(since: "1.7.1.1").map(\.version)), ["1.8"], "welcome after 1.7.1.1: the 1.8 pages")
eq(Set(WhatsNew.pages(since: "1.6.5").map(\.version)), ["1.7", "1.7.1", "1.8"], "welcome after 1.6.5: 1.7 and later pages")
eq(Set(WhatsNew.pages(since: "1.6.1").map(\.version)), ["1.6.2", "1.6.3", "1.6.4", "1.6.5", "1.7", "1.7.1", "1.8"], "welcome after 1.6.1: every newer page")
eq(WhatsNew.pages(since: "1.6").count, WhatsNew.all.count, "welcome after 1.6: every page")
eq(WhatsNew.pages(since: "").count, WhatsNew.all.count, "welcome never seen: every page")
check(WhatsNew.pages(since: "1.8").isEmpty, "welcome already seen: nothing")

// MARK: Arc's sidebar
do {
    let json = """
    {"sidebar":{"containers":[{"global":{}},{
      "spaces":["s1",{"id":"s1","title":"Work","containerIDs":["pinned","p1","unpinned","u1"],"profile":{"default":true},"customInfo":{"iconType":{"emoji_v2":"💼"}}},
                "s2",{"id":"s2","title":"Home","containerIDs":["pinned","p2","unpinned","u2"],"profile":{"custom":{"_0":{"directoryBasename":"Profile 1"}}}}],
      "items":[
        "top",{"id":"top","childrenIds":["f1"],"data":{"itemContainer":{"containerType":{"topApps":{"_0":{"default":true}}}}}},
        "f1",{"id":"f1","parentID":"top","title":null,"data":{"tab":{"savedURL":"https://mail.example.com/","savedTitle":"Mail"}}},
        "p1",{"id":"p1","childrenIds":["t1","d1","x1"],"data":{"itemContainer":{"containerType":{"spaceItems":{"_0":"s1"}}}}},
        "t1",{"id":"t1","title":"Docs","data":{"tab":{"savedURL":"https://docs.example.com/","savedTitle":"Old title"}}},
        "x1",{"id":"x1","data":{"tab":{"savedURL":"file:///etc/passwd","savedTitle":"Local"}}},
        "d1",{"id":"d1","title":"Clients","childrenIds":["t2","d2"],"data":{"list":{}}},
        "t2",{"id":"t2","data":{"tab":{"savedURL":"https://a.example.com/","savedTitle":"A"}}},
        "d2",{"id":"d2","title":"Old","childrenIds":["t3"],"data":{"list":{}}},
        "t3",{"id":"t3","data":{"tab":{"savedURL":"https://b.example.com/","savedTitle":"B"}}},
        "u1",{"id":"u1","childrenIds":["t4"],"data":{"itemContainer":{}}},
        "t4",{"id":"t4","data":{"tab":{"savedURL":"https://news.example.com/","savedTitle":"News"}}},
        "p2",{"id":"p2","childrenIds":["t5"],"data":{"itemContainer":{}}},
        "t5",{"id":"t5","data":{"tab":{"savedURL":"https://shop.example.com/","savedTitle":"Shop"}}}
      ]}]}}
    """
    let work = try ArcImport.read(Data(json.utf8), profile: "Default", includeToday: false)
    eq(work.favorites.map(\.title), ["Mail"], "arc: favorites of the profile")
    eq(work.groups.map(\.name), ["💼 Work", "💼 Work · Clients", "💼 Work · Clients · Old"], "arc: a group per space and folder")
    eq(work.groups.first?.tabs.map(\.title), ["Docs"], "arc: renamed tab keeps its title, local files skipped")
    eq(work.tabCount, 4, "arc: tab count")
    let today = try ArcImport.read(Data(json.utf8), profile: "Default", includeToday: true)
    eq(today.groups.last?.tabs.map(\.title), ["News"], "arc: today's tabs when asked")
    let home = try ArcImport.read(Data(json.utf8), profile: "Profile 1", includeToday: false)
    eq(home.groups.map(\.name), ["Home"], "arc: other profile's spaces only")
    eq(home.favorites.count, 0, "arc: favorites belong to their profile")
    check((try? ArcImport.read(Data("{}".utf8), profile: nil, includeToday: false)) == nil, "arc: unreadable file is an error")
} catch {
    check(false, "arc: sample sidebar", "\(error)")
}

// MARK: Password check
check(PasswordStore.isWeak("password"), "weak: common short password")
check(PasswordStore.isWeak("aaaaaaaaaaaaaaa"), "weak: one repeated character")
check(!PasswordStore.isWeak("abcdEf-ghijk2-lmnopq"), "weak: a suggested password is strong")

// MARK: Tacet Guide
check(TacetGuide.sections.count > 15, "guide: sections load")
check(TacetGuide.lookup("Tacet Plugins shortcut").contains("⇧⌘P"), "guide: plugins shortcut")
check(TacetGuide.lookup("who made Tacet engine").contains("scadavide55"), "guide: who made it")
check(TacetGuide.lookup("why Lumen renamed").contains("Lumen Assistant"), "guide: the rename")
check(TacetGuide.lookup("").contains("Sections of the Tacet Guide"), "guide: empty query lists sections")

// MARK: Tacet Plugins
do {
    // A list saved by an earlier build, without the newer fields, must still load.
    let old = #"{"cutout":{"plugin":{"id":"cutout","name":"Cutout","description":"d","version":"1.0","sites":["*"],"js":"main.js","files":{},"app":{"start":"index.html","files":[],"assets":[]}},"enabled":true},"hide-comments":{"plugin":{"id":"hide-comments","name":"Hide Comments","description":"d","version":"1.0","sites":["*"],"css":"style.css","files":{}},"enabled":true}}"#
    let list = try JSONDecoder().decode([String: PluginStore.Installed].self, from: Data(old.utf8))
    eq(list["cutout"]?.plugin.behaviour, "app", "plugins: an app opens even without a mode")
    eq(list["hide-comments"]?.plugin.behaviour, "toggle", "plugins: a style-only plugin toggles")
    check(list["hide-comments"]?.plugin.isStyleOnly == true, "plugins: style-only changes live")
    check(list["cutout"]?.pinned == nil && list["cutout"]?.offSites == nil, "plugins: new fields default to nothing")
    var item = list["hide-comments"]!
    item.offSites = ["youtube.com"]
    check(item.isOff(on: "www.youtube.com") && item.isOff(on: "youtube.com"), "plugins: off on a site and its subdomains")
    check(!item.isOff(on: "notyoutube.com") && !item.isOff(on: nil), "plugins: still on elsewhere")
} catch {
    check(false, "plugins: old list loads", "\(error)")
}

// The plugins folder itself: every plugin reads, has its files, a real icon, and the signed list matches what's on disk.
do {
    let fm = FileManager.default
    let root = URL(fileURLWithPath: fm.currentDirectoryPath).appendingPathComponent("plugins")
    let folders = ((try? fm.contentsOfDirectory(atPath: root.path)) ?? [])
        .filter { fm.fileExists(atPath: root.appendingPathComponent($0).appendingPathComponent("plugin.json").path) }.sorted()
    check(folders.count >= 24, "plugins folder: plugins found", "\(folders.count)")
    var byId: [String: PluginStore.Plugin] = [:]
    for id in folders {
        let dir = root.appendingPathComponent(id)
        // A manifest has no "files": the signed list adds them, with each file's hash.
        guard let raw = try? Data(contentsOf: dir.appendingPathComponent("plugin.json")),
              var obj = (try? JSONSerialization.jsonObject(with: raw)) as? [String: Any],
              let data = { obj["files"] = obj["files"] ?? [String: String](); return try? JSONSerialization.data(withJSONObject: obj) }(),
              let p = try? JSONDecoder().decode(PluginStore.Plugin.self, from: data) else { check(false, "plugin \(id): plugin.json reads"); continue }
        byId[id] = p
        eq(p.id, id, "plugin \(id): id is the folder name")
        var needed = [p.js, p.css].compactMap { $0 }
        needed += (p.app?.files ?? []).map { "app/" + $0 }
        check(!needed.isEmpty, "plugin \(id): has files")
        for f in needed { check(fm.fileExists(atPath: dir.appendingPathComponent(f).path), "plugin \(id): \(f) exists") }
        check(["toggle", "action", "info", "app"].contains(p.behaviour), "plugin \(id): known mode", p.behaviour)
        check(p.runAt == nil || ["start", "end"].contains(p.runAt!), "plugin \(id): runAt is start or end")
        check(!p.sites.isEmpty || p.app != nil, "plugin \(id): has sites or is an app")
        check(p.version.split(separator: ".").allSatisfy { Int($0) != nil }, "plugin \(id): version is numbers", p.version)
        check(!p.name.isEmpty && p.description.count > 20, "plugin \(id): name and description")
        if let icon = p.icon { check(NSImage(systemSymbolName: icon, accessibilityDescription: nil) != nil, "plugin \(id): icon \(icon) exists") }
        else { check(false, "plugin \(id): has an icon") }
        if p.behaviour == "action", let js = p.js, let text = try? String(contentsOf: dir.appendingPathComponent(js), encoding: .utf8) {
            check(text.contains("tacetAction") && p.action != nil, "plugin \(id): an action defines tacetAction and a name")
        }
        // A style-only plugin turns on and off live, so it must say it is a toggle.
        if p.isStyleOnly { eq(p.behaviour, "toggle", "plugin \(id): style-only toggles") }
    }
    // The signed list: same plugins and versions, every file's hash right, and the signature valid with the app's key.
    if let indexData = try? Data(contentsOf: root.appendingPathComponent("index.json")),
       let sig = try? Data(contentsOf: root.appendingPathComponent("index.json.sig")),
       let obj = try? JSONSerialization.jsonObject(with: indexData) as? [String: Any], let list = obj["plugins"] as? [[String: Any]] {
        check(PluginStore.verify(indexData, signature: sig), "plugins index: signature is valid for Tacet's key")
        eq(Set(list.compactMap { $0["id"] as? String }), Set(folders), "plugins index: lists every plugin folder")
        for entry in list {
            guard let id = entry["id"] as? String, let files = entry["files"] as? [String: String] else { continue }
            eq(entry["version"] as? String, byId[id]?.version, "plugins index: \(id) has the folder's version")
            for (name, hash) in files {
                let file = (try? Data(contentsOf: root.appendingPathComponent(id).appendingPathComponent(name))) ?? Data()
                eq(SHA256.hash(data: file).map { String(format: "%02x", $0) }.joined(), hash, "plugins index: \(id)/\(name) hash")
            }
        }
    } else {
        check(false, "plugins index: index.json and its signature read")
    }
}

// MARK: AI providers

check(AIProvider.anthropic.guessesImages("claude-opus-5-5"), "vision: claude")
check(AIProvider.openAI.guessesImages("gpt-4o-mini"), "vision: gpt-4o")
check(!AIProvider.openAI.guessesImages("gpt-3.5-turbo"), "no vision: gpt-3.5")
check(AIProvider.deepSeek.guessesImages("DeepSeek-V4.1-Flash"), "vision: deepseek flash")
check(!AIProvider.deepSeek.guessesImages("deepseek-chat"), "no vision: deepseek-chat")
let userMsg = AssistantChat.userMessage(text: "hi", page: "<page>x</page>", images: [Data([1, 2])], provider: .anthropic)
check((userMsg["content"] as? [[String: Any]])?.first?["type"] as? String == "image", "anthropic image block")
let oaMsg = AssistantChat.userMessage(text: "hi", page: nil, images: [Data([1])], provider: .openAI)
check((oaMsg["content"] as? [[String: Any]])?.first?["type"] as? String == "image_url", "openai image block")
check(JSONSerialization.isValidJSONObject(userMsg) && JSONSerialization.isValidJSONObject(oaMsg), "messages encode as JSON")
for t in AssistantPrompt.tools { check(JSONSerialization.isValidJSONObject(AssistantPrompt.schema(t)), "tool schema \(t.name)") }

check(AssistantPrompt.tools.contains { $0.name == "group_tabs" }, "group_tabs tool exists")
let allNames = AssistantPrompt.clientTools(provider: .openAI, web: true, control: true).map(\.name)
eq(Set(allNames).count, allNames.count, "tool names are unique")
for t in AssistantPrompt.webTools + AssistantPrompt.controlTools { check(JSONSerialization.isValidJSONObject(AssistantPrompt.schema(t)), "tool schema \(t.name)") }
check(!AssistantPrompt.clientTools(provider: .anthropic, web: true, control: false).contains { $0.name == "web_search" }, "anthropic uses its own web tools")
check(!AssistantPrompt.clientTools(provider: .openAI, web: false, control: false).contains { ["web_fetch", "click"].contains($0.name) }, "web and control tools off when turned off")
eq(AssistantPrompt.anthropicWebTools(model: "claude-opus-5-5").first?["type"] as? String, "web_search_20260209", "web search with filtering on opus 5.5")
eq(AssistantPrompt.anthropicWebTools(model: "claude-haiku-4-5").first?["type"] as? String, "web_search_20250305", "basic web search on older models")
for name in allNames + ["web_search", "web_fetch"] {
    check(AssistantPrompt.system(web: true, control: true).contains(name + ":"), "system prompt explains \(name)")
}
let offPrompt = AssistantPrompt.system(web: false, control: false)
check(!offPrompt.contains("- find_elements:") && !offPrompt.contains("- web_search:"), "prompt without web and control tools")
check(offPrompt.contains("Web access") && offPrompt.contains("Right now it is off") && offPrompt.contains("Browser use"), "prompt knows the chat buttons")
check(AssistantPrompt.system(web: true, control: false).contains("web_search and web_fetch. Right now it is on"), "prompt knows web access is on")
eq(AssistantHistory.title("  How does this work?\nmore"), "How does this work?", "chat title: first line")
eq(AssistantHistory.title(String(repeating: "a", count: 100)).count, 71, "chat title: shortened")
let cited = AIClient.citedSources([["type": "text", "text": "x", "citations": [["url": "https://a.com/1", "title": "A"], ["url": "https://a.com/1", "title": "A"], ["url": "https://b.com", "title": ""]]]])
eq(cited.map(\.url.absoluteString), ["https://a.com/1", "https://b.com"], "citations become sources once each")

for name in ["read_tab", "get_video_transcript", "search_history", "search_bookmarks"] {
    check(AssistantPrompt.tools.contains { $0.name == name }, "tool \(name) exists")
    check(AssistantPrompt.system(web: true, control: false).contains(name + ":"), "prompt explains \(name)")
}
check(AssistantPrompt.clientTools(provider: .openAI, web: false, control: false, vision: true).contains { $0.name == "take_screenshot" }, "screenshot tool for vision models")
check(!AssistantPrompt.clientTools(provider: .openAI, web: false, control: false, vision: false).contains { $0.name == "take_screenshot" }, "no screenshot tool without vision")
check(AssistantPrompt.system(web: false, control: false, vision: true).contains("take_screenshot:"), "prompt explains take_screenshot for vision models")
check(!AssistantPrompt.system(web: false, control: false).contains("take_screenshot"), "no screenshot in prompt without vision")
check(AssistantPrompt.system(web: false, control: false).contains("<selection>"), "prompt explains selections")
// Quick answers from the command bar get a short prompt of their own, so the first words come sooner.
let quickPrompt = AssistantPrompt.system(web: true, control: false, quick: true)
check(quickPrompt.count * 5 < AssistantPrompt.system(web: true, control: false).count, "quick prompt is far shorter than the chat's")
check(quickPrompt.contains("tacet_guide") && quickPrompt.contains("command bar"), "quick prompt knows the guide and where it was asked")
check(!AssistantPrompt.system(web: false, control: false, quick: true).contains("search the web once"), "quick prompt without web access doesn't offer searches")
eq(AssistantPrompt.clientTools(provider: .anthropic, web: true, control: false, quick: true).map(\.name), ["tacet_guide"], "quick answers on Anthropic only add the guide")
eq(AssistantPrompt.clientTools(provider: .openAI, web: false, control: false, quick: true).map(\.name), ["tacet_guide"], "quick answers respect Web access turned off")
eq((AssistantPrompt.anthropicWebTools(model: "claude-haiku-5-5", quick: true).first?["max_uses"] as? Int), 2, "quick answers search less")
check(AIProvider.takesEffort("claude-haiku-5-5") && AIProvider.takesEffort("claude-opus-5-5") && !AIProvider.takesEffort("claude-haiku-4-5"), "effort only for models that take it")
check(AIProvider.takesReasoningEffort("gpt-5-mini") && !AIProvider.takesReasoningEffort("gpt-4o"), "reasoning effort only for reasoning models")
eq(AIProvider.anthropic.fastModel, "claude-haiku-5-5", "Anthropic's fast model for the command bar")
check(AIProvider.deepSeek.fastModel == nil, "providers without a smaller model keep the chosen one")
check(AssistantPrompt.system(web: true, control: false).contains("Your voice"), "the assistant has its voice")
do {
    let s = Settings.shared
    let (personality, detailed) = (s.aiPersonality, s.aiDetailed)
    s.aiPersonality = true; s.aiDetailed = false
    let short = AssistantPrompt.system(web: true, control: false)
    check(short.contains("tacet") && short.contains("Be brief"), "prompt: a voice of its own, and short answers by default")
    s.aiPersonality = false
    check(AssistantPrompt.system(web: true, control: false).contains("neutral and matter-of-fact"), "prompt: Personality off is neutral")
    check(AssistantPrompt.system(web: true, control: false, quick: true).contains("neutral and matter-of-fact"), "prompt: the quick prompt follows Personality too")
    s.aiDetailed = true
    check(AssistantPrompt.system(web: true, control: false).contains("Be thorough"), "prompt: Detailed asks for fuller answers")
    s.aiPersonality = personality; s.aiDetailed = detailed
}
for t in AssistantPrompt.tools + AssistantPrompt.visionTools { check(JSONSerialization.isValidJSONObject(AssistantPrompt.schema(t)), "schema \(t.name)") }
eq(AssistantChat.number("3"), 3, "tool number from string")
eq(AssistantChat.number(2.0), 2, "tool number from double")
eq(AssistantChat.number(nil), 0, "tool number missing")

let shotCall = AIClient.ToolCall(id: "c1", name: "take_screenshot", arguments: [:])
let anthropicShot = AIClient.toolResults([(shotCall, "Screenshot", false)], provider: .anthropic, images: ["c1": Data([1, 2, 3])])
let anthropicBlock = ((anthropicShot.first?["content"] as? [[String: Any]])?.first?["content"]) as? [[String: Any]]
eq(anthropicBlock?.first?["type"] as? String, "image", "anthropic screenshot inside tool result")
let openAIShot = AIClient.toolResults([(shotCall, "Screenshot", false)], provider: .openAI, images: ["c1": Data([1, 2, 3])])
eq(openAIShot.map { $0["role"] as? String ?? "" }, ["tool", "user"], "openai screenshot follows as a user message")
check(JSONSerialization.isValidJSONObject(anthropicShot) && JSONSerialization.isValidJSONObject(openAIShot), "screenshot results encode as JSON")

check(AssistantSources.isVideo(URL(string: "https://www.youtube.com/watch?v=abc")), "youtube watch is a video")
check(AssistantSources.isVideo(URL(string: "https://youtube.com/shorts/abc")), "youtube shorts is a video")
check(!AssistantSources.isVideo(URL(string: "https://www.youtube.com/")), "youtube home isn't a video")
check(!AssistantSources.isVideo(URL(string: "https://notyoutube.com/watch?v=1")), "other sites aren't youtube")
eq(AssistantChat.quote("  hello\n   world  "), "hello world", "selection quote flattened")
eq(AssistantChat.quote(String(repeating: "a", count: 300)).count, 141, "selection quote shortened")

// Apple's on-device model
check(!AIProvider.apple.needsKey, "apple model needs no key")
check(!AIProvider.apple.supportsImages(AppleModel.modelID), "apple model reads no images")
let appleTools = AppleModel.tools(web: true).map(\.name)
check(appleTools.contains("read_tab") && appleTools.contains("web_search") && !appleTools.contains("click"), "apple model without browser use when it's off")
check(!AppleModel.tools(web: false).contains { $0.name == "web_fetch" }, "apple model without web tools when web is off")
check(AppleModel.shorten(String(repeating: "x", count: 10_000)).count < 6_100, "apple model text shortened")
check(AppleModel.instructions(control: true).count < 1_400, "apple instructions stay short")
check(AppleModel.instructions(control: true).contains("find_elements") && !AppleModel.instructions(control: false).contains("find_elements"), "apple instructions follow browser use")
check(AppleModel.tools(web: false, control: true).contains { $0.name == "click" }, "apple model gets browser use when it's on")

// Site styles
let oldStyle = Data(#"{"id":"6C1E0D2A-5B7F-4E2D-9C1A-4C55E7A1B0F3","host":"example.com","css":"p{color:red}","enabled":true}"#.utf8)
let decoded = try? JSONDecoder().decode(SiteStyle.self, from: oldStyle)
eq(decoded?.css, "p{color:red}", "old site style still loads")
eq(decoded?.theme, .site, "old site style gets default options")
var styled = SiteStyle(host: "example.com")
check(styled.isEmpty, "new style is empty")
styled.theme = .dark
styled.hidden = ["#comments", ".ad > div:nth-of-type(2)"]
styled.reduceMotion = true
check(styled.effectiveCSS.contains("#comments") && styled.effectiveCSS.contains("animation:none"), "style becomes CSS")
check(!styled.effectiveCSS.contains("invert") && SiteStyle.darkCSS.contains("invert"), "dark theme kept apart for already-dark pages")
check(styled.matches("www.example.com") && styled.matches("example.com") && !styled.matches("notexample.com"), "style matches its site and subdomains")
eq(SiteStyle.normalizedHost("https://www.GitHub.com/x"), "github.com", "style host normalised")
let roundTrip = try? JSONDecoder().decode(SiteStyle.self, from: JSONEncoder().encode(styled))
eq(roundTrip, styled, "style round trip")

// MARK: Web tools

let ddg = """
<div class="result results_links results_links_deep result--ad "><a class="result__a" href="https://duckduckgo.com/y.js?ad_domain=x.com">Ad</a></div>
<div class="result results_links results_links_deep web-result "><h2 class="result__title"><a rel="nofollow" class="result__a" href="https://developer.apple.com/documentation/observation">Observation | <b>Apple</b> Developer</a></h2>
<a class="result__snippet" href="https://developer.apple.com/documentation/observation">Make responsive apps that update the presentation when underlying data changes &amp; more.</a></div>
<div class="result results_links results_links_deep web-result "><a class="result__a" href="//duckduckgo.com/l/?uddg=https%3A%2F%2Fexample.com%2Fa%3Fb%3D1&amp;rut=abc">Example</a><a class="result__snippet" href="x">Snip</a></div>
"""
let parsed = WebTools.parseResults(ddg)
eq(parsed.map(\.url), ["https://developer.apple.com/documentation/observation", "https://example.com/a?b=1"], "search: results without ads, redirect unwrapped")
eq(parsed.first?.title, "Observation | Apple Developer", "search: title without tags")
eq(parsed.first?.snippet, "Make responsive apps that update the presentation when underlying data changes & more.", "search: snippet entities")

let html = """
<html><head><title>My &amp; Page</title><style>.a{}</style></head><body><nav>Menu</nav><script>alert(1)</script>
<h1>Hello</h1><p>First&nbsp;line<br>second &#8220;quoted&#x201D;</p><ul><li>One</li><li>Two</li></ul>
<a href="/docs#top">Docs</a> <a href="https://other.org/x">Other</a> <a href="javascript:evil()">JS</a><!-- hidden --></body></html>
"""
let plain = WebTools.plainText(html: html)
eq(plain.title, "My & Page", "html: title")
check(plain.text.contains("Hello") && plain.text.contains("First\u{00A0}line".replacingOccurrences(of: "\u{00A0}", with: " ")), "html: text kept", plain.text)
check(!plain.text.contains("alert") && !plain.text.contains("Menu") && !plain.text.contains(".a{}") && !plain.text.contains("hidden"), "html: scripts, styles, nav, comments removed", plain.text)
check(plain.text.contains("“quoted”") && plain.text.contains("- One\n- Two"), "html: entities and lists", plain.text)
let pageLinks = WebTools.links(in: html, base: URL(string: "https://site.com/a/b")!)
eq(pageLinks.map(\.url), ["https://site.com/docs", "https://other.org/x"], "html: links resolved, no javascript")

for (u, ok) in [("https://example.com", true), ("http://93.184.216.34/x", true), ("http://localhost:3000", false), ("http://127.0.0.1", false),
                ("http://192.168.1.1", false), ("http://10.0.0.1", false), ("http://172.20.1.1", false), ("http://169.254.169.254/latest", false),
                ("http://[::1]/", false), ("http://router.local", false), ("http://intranet", false), ("http://0x7f.1", false),
                ("http://2130706433", false), ("file:///etc/passwd", false), ("ftp://example.com", false), ("http://printer.lan", false)] {
    eq(WebTools.isPublic(URL(string: u)!), ok, "public address \(u)")
}

let convo: [[String: Any]] = [
    ["role": "user", "content": "<page url=\"https://news.com/a\">see https://docs.site.org/guide/</page> what is this"],
    ["role": "assistant", "content": [["type": "text", "text": "Let me read https://evil.com/?secret=1"],
                                      ["type": "web_search_tool_result", "content": [["type": "web_search_result", "url": "https://found.com/r"]]]]],
    ["role": "tool", "content": "1. Result\nhttps://result.net/page?id=4"],
]
check(WebTools.mayOpen("https://docs.site.org/guide/", in: convo), "fetch: address from page")
check(WebTools.mayOpen("https://docs.site.org/guide", in: convo), "fetch: without trailing slash")
check(WebTools.mayOpen("https://result.net/page?id=4", in: convo), "fetch: address from tool result")
check(WebTools.mayOpen("https://found.com/r", in: convo), "fetch: address from Anthropic search results")
check(!WebTools.mayOpen("https://evil.com/?secret=1", in: convo), "fetch: not an address the model wrote itself")
check(!WebTools.mayOpen("https://result.net/page?id=4&leak=x", in: convo), "fetch: not an address with added data")
check(WebTools.mayOpen("https://www.apple.com", in: convo) && WebTools.mayOpen("https://github.com/", in: convo), "open: home pages")
check(!WebTools.mayOpen("https://secret-data.evil.com/", in: convo), "open: no data in a subdomain")
check(!WebTools.mayOpen("https://apple.com/?q=x", in: convo), "open: no query on a home page")
check(WebTools.format([], query: "x").contains("No results"), "search: empty")

// MARK: Filter lists

let list = """
! comment
[Adblock Plus 2.0]
||ads.example.com^
||tracker.example.net^$third-party
@@||example.org/allowed^
example.com##.ad-banner
##.sponsored
example.com#@#.keep
/banner/*/img^
||ünicode.example^
"""
let out = FilterConverter.convert(list)
check(out.block.count >= 3, "filters: block rules", "\(out.block.count)")
eq(out.allow.count, 1, "filters: exception")
eq(out.hide.count, 2, "filters: cosmetic")
check(out.skipped >= 1, "filters: unsupported skipped")
check(JSONSerialization.isValidJSONObject(out.block + out.allow + out.hide), "filters: valid JSON")

// MARK: Downloads

check(DownloadItem.timeText(3) == L("almost done"), "downloads: a few seconds left says almost done")
check(DownloadItem.timeText(90) != L("almost done") && !DownloadItem.timeText(90).isEmpty, "downloads: time left in minutes")
check(DownloadItem.speedText(2_500_000).hasSuffix("/s"), "downloads: speed per second")
eq(UpdateInstaller.shellQuoted("a'b"), "'a'\\''b'", "shell quoting escapes single quotes")
do {
    func saved(_ state: String, resume: Bool) -> DownloadItem {
        DownloadItem(saved: .init(id: UUID(), source: URL(string: "https://example.com/f.zip"), filename: "f.zip", destination: nil,
                                  received: 50, total: 100, state: state, reason: nil, started: Date(), finished: nil,
                                  resumeData: resume ? Data([1, 2, 3]) : nil))
    }
    let paused = saved("paused", resume: true)
    check(paused.state == .paused && paused.canResume, "downloads: a paused download comes back paused, ready to resume")
    eq(paused.fraction, 0.5, "downloads: a paused download keeps how far it got")
    check(saved("paused", resume: false).state == .failed(L("Stopped when Tacet quit")), "downloads: paused without resume data can't go on")
    check(saved("active", resume: false).state == .failed(L("Stopped when Tacet quit")), "downloads: one running when Tacet quit is shown as stopped")
    let cancelled = saved("cancelled", resume: true)
    check(cancelled.state == .cancelled && !cancelled.canResume && cancelled.canRetry, "downloads: a cancelled one can only be downloaded again")
    eq(saved("finished", resume: false).fraction, 1, "downloads: a finished one is full")
}
eq(GroupHeader.colorNames.count, TabGroup.colors.count, "every group colour has a name (menus index both)")
eq(Calculator.evaluate("12*7+3"), 87, "calculator: order of operations")
eq(Calculator.evaluate("(4,5 + 2) / 2"), 3.25, "calculator: commas as decimal points, brackets")
eq(Calculator.evaluate("2^10"), 1024, "calculator: powers")
eq(Calculator.evaluate("-3 x 4"), -12, "calculator: a leading minus and x for times")
eq(Calculator.evaluate("10 ÷ 4"), 2.5, "calculator: ÷")
for halfway in ["2+", "(1+2", "1+2)", "42", "1/0", "3 apples", "", "((((", "2**3", "1..2+3"] {
    check(Calculator.evaluate(halfway) == nil, "calculator: \"\(halfway)\" isn't a sum")
}
check(Calculator.evaluate(String(repeating: "(", count: 60) + "1" + String(repeating: ")", count: 60)) == nil, "calculator: deep nesting is refused")
eq(DevTools.parseSize("390 × 844"), CGSize(width: 390, height: 844), "responsive: a size typed with ×")
eq(DevTools.parseSize("1280x720"), CGSize(width: 1280, height: 720), "responsive: a size typed with x")
check(DevTools.parseSize("12 × 5") == nil && DevTools.parseSize("390") == nil, "responsive: sizes too small or incomplete are refused")
eq(Set(DevDevice.all.map(\.id)).count, DevDevice.all.count, "responsive: every device has its own id")
check(DevUserAgent.allCases.allSatisfy { $0.value.hasPrefix("Mozilla/5.0 (") }, "user agents: every one is a full user agent")
check(DevUserAgent.safariiPhone.value.contains("iPhone") && DevUserAgent.chromeAndroid.value.contains("Android"), "user agents: phones say what they are")

// MARK: History database

let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("lumen-tests-\(UUID().uuidString)")
try? FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
if let db = HistoryDB(tmp.appendingPathComponent("h.sqlite")) {
    check(db.isEmpty, "history: starts empty")
    let now = Date()
    let a = HistoryEntry(url: URL(string: "https://a.com")!, title: "A \"quoted\" ' title", date: now.addingTimeInterval(-10))
    let b = HistoryEntry(url: URL(string: "https://b.com")!, title: "B", date: now)
    db.save([a, b])
    db.flush()
    let loaded = db.load()
    eq(loaded.map(\.url.absoluteString), ["https://b.com", "https://a.com"], "history: newest first")
    // An old history.json left behind: only what the database doesn't have comes in.
    let staleB = HistoryEntry(url: URL(string: "https://b.com")!, title: "Old B", date: now.addingTimeInterval(-99_999), visits: 1)
    let onlyOld = HistoryEntry(url: URL(string: "https://old.example")!, title: "Old page", date: now.addingTimeInterval(-50_000))
    check(db.insertMissing([staleB, onlyOld]), "history: merging an old copy works")
    let merged = db.load()
    eq(merged.first { $0.url.absoluteString == "https://b.com" }?.title, "B", "history: the newer row stays when merging")
    check(merged.contains { $0.url.absoluteString == "https://old.example" }, "history: entries only in the old copy come in")
    db.delete([onlyOld.id])
    db.flush()
    eq(loaded.last?.title, a.title, "history: title with quotes survives")
    var a2 = a; a2.visits = 5; a2.date = now.addingTimeInterval(10)
    db.save([a2]); db.flush()
    eq(db.load().first?.visits, 5, "history: same URL replaced")
    eq(db.load().count, 2, "history: no duplicate URL")
    db.delete([b.id]); db.flush()
    eq(db.load().count, 1, "history: delete")
    db.save((0..<2000).map { HistoryEntry(url: URL(string: "https://x\($0).com")!, title: "\($0)", date: now) }); db.flush()
    eq(db.load().count, 2001, "history: 2000 rows in one transaction")
    db.clear(since: nil)
    check(db.isEmpty, "history: clear all")
    db.checkpoint()
    let wal = (try? FileManager.default.attributesOfItem(atPath: tmp.appendingPathComponent("h.sqlite-wal").path)[.size] as? Int) ?? 0
    eq(wal, 0, "history: WAL truncated by checkpoint")
} else {
    check(false, "history: database opens")
}
try? FileManager.default.removeItem(at: tmp)

// MARK: WebKit compiles the rules

func compiles(_ json: String, _ name: String) {
    let id = "lumen-test-\(UUID().uuidString)"
    var done = false
    WKContentRuleListStore.default().compileContentRuleList(forIdentifier: id, encodedContentRuleList: json) { list, error in
        check(list != nil, "webkit compiles \(name)", error?.localizedDescription ?? "")
        WKContentRuleListStore.default().removeContentRuleList(forIdentifier: id) { _ in done = true }
    }
    let deadline = Date().addingTimeInterval(60)
    while !done && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
    check(done, "webkit finished \(name)")
}
compiles(BuiltInRules.json(), "built-in rules")
compiles(BuiltInRules.cookieJSON, "cookie rules")
let converted = String(decoding: try! JSONSerialization.data(withJSONObject: out.block + out.allow + out.hide), as: UTF8.self)
compiles(converted, "converted filters")

// MARK: Organising tabs (a private window, so nothing is saved)

func tabsWindow(_ urls: [String]) -> BrowserState {
    let w = BrowserState(isPrivate: true)
    let blank = w.tabs
    for u in urls { w.tabs.append(Tab(browser: w, url: URL(string: u)!)) }
    w.tabs.removeAll { t in blank.contains { $0 === t } }
    w.select(w.tabs[0])
    return w
}
do {
    // Tabs closed together come back together with ⇧⌘T, in their places.
    let w = tabsWindow(["https://a.example/", "https://b.example/", "https://c.example/", "https://d.example/"])
    w.closeBelow(w.tabs[1])
    eq(w.tabs.count, 2, "batch: closing tabs below")
    w.reopenLastClosed()
    eq(w.tabs.compactMap { $0.url?.host }, ["a.example", "b.example", "c.example", "d.example"], "batch: all come back in order")
    w.close(w.tabs[3])
    w.close(w.tabs[2])
    w.reopenLastClosed()
    eq(w.tabs.count, 3, "batch: single closes come back one at a time")
    // A pinned tab remembers where it was pinned.
    w.togglePin(w.tabs[0])
    eq(w.tabs.first?.pinnedHome?.host, "a.example", "pinned: remembers its address")
    eq(w.tabs.first?.snapshot().home?.host, "a.example", "pinned: home is saved with the session")
}
// The settings file reads back what it wrote, and keeps this Mac's own bookkeeping out.
do {
    let file = SettingsTransfer.File(settings: ["theme": "\"dark\"", "welcomedVersion": "\"1.6.3\""], plugins: [.init(id: "cutout", enabled: true, pinned: true, offSites: nil)])
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    let back = SettingsTransfer.read(try encoder.encode(file))
    eq(back?.settings["theme"], "\"dark\"", "settings file: round trip")
    eq(back?.plugins.first?.pinned, true, "settings file: plugins")
    check(SettingsTransfer.make().map { !String(decoding: $0, as: UTF8.self).contains("\"welcomedVersion\"") } ?? false, "settings file: leaves out this Mac's bookkeeping")
} catch {
    check(false, "settings file", "\(error)")
}

let settingsBefore = (Settings.shared.groupThreshold, Settings.shared.groupExceptions)
Settings.shared.groupExceptions = []

Settings.shared.groupThreshold = 3
let tw = tabsWindow(["https://github.com/a", "https://www.github.com/b", "https://news.ycombinator.com", "https://github.com/c", "https://apple.com"])
tw.autoOrganize()
eq(tw.groups.map(\.name), ["GitHub"], "group by site at 3 tabs")
eq(tw.tabs.filter { $0.groupID != nil }.count, 3, "three GitHub tabs grouped")
Settings.shared.groupThreshold = 5
let tw5 = tabsWindow(["https://github.com/a", "https://github.com/b", "https://github.com/c"])
tw5.autoOrganize()
check(tw5.groups.isEmpty, "no group below a threshold of 5")
Settings.shared.groupThreshold = 2
let tw2 = tabsWindow(["https://youtube.com/1", "https://youtube.com/2", "https://github.com/x", "https://github.com/y"])
tw2.autoOrganize()
eq(Set(tw2.groups.map(\.name)), ["YouTube", "GitHub"], "threshold of 2 groups pairs")
Settings.shared.setGroupException("www.youtube.com", true)
eq(Settings.shared.groupExceptions, ["youtube.com"], "exception stored as the site")
tw2.autoOrganize()
eq(tw2.groups.map(\.name), ["GitHub"], "excepted site's group undone")
check(tw2.tabs.filter { $0.host?.contains("youtube") == true }.allSatisfy { $0.groupID == nil }, "excepted tabs left ungrouped")
Settings.shared.groupExceptions = []

let tt = tabsWindow(["https://b.com/x", "https://a.com/y", "https://c.com/z", "https://a.com/y"])
eq(tt.duplicateCount, 1, "one duplicate tab")
tt.closeDuplicates()
eq(tt.duplicateCount, 0, "duplicates closed")
tt.tabs[0].title = "Zeta"; tt.tabs[1].title = "alpha"; tt.tabs[2].title = "Beta"
tt.sortTabs(by: .title)
eq(tt.tabs.map(\.title), ["alpha", "Beta", "Zeta"], "sort by title, ignoring case")
tt.sortTabs(by: .site)
eq(tt.tabs.compactMap(\.host), ["a.com", "b.com", "c.com"], "sort by site")
let topic = tt.group([tt.tabs[0], tt.tabs[2]], named: "Rome trip")
eq(topic?.name, "Rome trip", "group named by topic")
eq(tt.tabs.map { $0.groupID == topic?.id }, [true, true, false], "group's tabs kept together")
tt.group([tt.tabs[2]], named: "rome TRIP")
eq(tt.groups.count, 1, "same name adds to the existing group")
eq(tt.tabs(in: tt.groups[0]).count, 3, "group has three tabs")
tt.newTab(inGroup: tt.groups[0].id)
eq(tt.tabs(in: tt.groups[0]).count, 4, "new tab inside the group")
eq(tt.tabs.last?.groupID, tt.groups[0].id, "new tab at the end of the group")

let ms = tabsWindow(["https://a.com", "https://b.com", "https://c.com", "https://d.com"])
ms.click(ms.tabs[0], modifiers: [])
ms.click(ms.tabs[2], modifiers: .shift)
eq(ms.marked.count, 3, "shift-click picks a range")
ms.click(ms.tabs[1], modifiers: .command)
eq(ms.marked.count, 2, "command-click removes a picked tab")
eq(ms.actionTabs(for: ms.tabs[2]).count, 2, "menu acts on picked tabs")
eq(ms.actionTabs(for: ms.tabs[3]).count, 1, "menu on another tab acts on it alone")
eq(ms.dragPayload(for: ms.tabs[0]).split(separator: "\n").count, 2, "dragging carries every picked tab")
ms.close(ms.actionTabs(for: ms.tabs[0]))
eq(ms.tabs.compactMap(\.host), ["b.com", "d.com"], "close picked tabs")
check(ms.marked.isEmpty, "picking cleared after closing")
ms.click(ms.tabs[1], modifiers: [])
check(ms.marked.isEmpty && ms.selectedID == ms.tabs[1].id, "plain click selects")
Settings.shared.groupThreshold = settingsBefore.0
Settings.shared.groupExceptions = settingsBefore.1

// MARK: Page control, in a real web view

let wv = WKWebView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
var loadedPage = false
final class LoadWaiter: NSObject, WKNavigationDelegate {
    var done: () -> Void = {}
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { done() }
}
let waiter = LoadWaiter()
waiter.done = { loadedPage = true }
wv.navigationDelegate = waiter
wv.loadHTMLString("""
<html><body style="height:3000px">
<input id="q" placeholder="Search" value="old">
<label for="pw">Password</label><input id="pw" type="password">
<input autocomplete="cc-number" name="card">
<textarea aria-label="Notes"></textarea>
<select id="s"><option value="a">Apple</option><option value="b">Banana</option></select>
<button id="b" onclick="window.clicked=(window.clicked||0)+1; document.title='clicked'">Go now</button>
<div id="ed" contenteditable="true">x</div>
<div id="d1" draggable="true">Card</div><div id="d2" ondragover="event.preventDefault()" ondrop="document.title='dropped'" tabindex="0">Column</div>
<form onsubmit="event.preventDefault(); document.title='submitted:' + this.elements[0].value"><input name="f" aria-label="Form field"></form>
<a href="https://example.com/x">Example link</a>
<p data-lumen-ref="1">fake</p>
</body></html>
""", baseURL: URL(string: "https://test.lumen/"))
let loadDeadline = Date().addingTimeInterval(20)
while !loadedPage && Date() < loadDeadline { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
check(loadedPage, "page control: test page loads")

func control(_ action: PageControl.Action, _ args: [String: Any]) -> (String, Bool) {
    var out: (String, Bool)?
    Task { @MainActor in out = await PageControl.run(action, args: args, in: wv) }
    let deadline = Date().addingTimeInterval(10)
    while out == nil && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
    return out ?? ("timeout", true)
}
func js(_ code: String) -> Any? {
    var out: Any?, done = false
    wv.evaluateJavaScript(code) { r, _ in out = r; done = true }
    while !done { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
    return out
}
func refFor(_ listing: String, _ needle: String) -> Int? {
    listing.split(separator: "\n").first { $0.contains(needle) }.flatMap { line in
        line.firstIndex(of: "]").flatMap { Int(line[line.index(after: line.startIndex)..<$0]) }
    }
}

let (listing, listErr) = control(.find, [:])
check(!listErr && listing.contains("\"Go now\"") && listing.contains("value=\"old\""), "find_elements lists elements", listing)
check(listing.contains("off limits") && !listing.contains("fake"), "find_elements marks secrets, ignores page-made refs", listing)
check(listing.contains("options=[\"Apple\",\"Banana\"]"), "find_elements lists menu options", listing)
let filtered = control(.find, ["query": "banana"]).0
check(filtered.contains("select") && !filtered.contains("Go now"), "find_elements query", filtered)

if let q = refFor(listing, "Search"), let pw = refFor(listing, "type=password"), let card = refFor(listing, "card"),
   let b = refFor(listing, "Go now"), let sel = refFor(listing, "select"), let ed = refFor(listing, "editable"),
   let notes = refFor(listing, "Notes"), let d1 = refFor(listing, "Card"), let d2 = refFor(listing, "Column"),
   let form = refFor(listing, "Form field") {
    check(!control(.type, ["ref": q, "text": "lumen browser"]).1, "type: text field")
    eq(js("document.getElementById('q').value") as? String, "lumen browser", "type: value replaced")
    _ = control(.type, ["ref": q, "text": "!", "clear": false])
    eq(js("document.getElementById('q').value") as? String, "lumen browser!", "type: append")
    check(control(.type, ["ref": pw, "text": "hunter2"]).1, "type: refuses password field")
    check(control(.type, ["ref": card, "text": "4111111111111111"]).1, "type: refuses card field")
    eq(js("document.getElementById('pw').value") as? String, "", "type: password stays empty")
    _ = control(.type, ["ref": sel, "text": "banana"])
    eq(js("document.getElementById('s').value") as? String, "b", "type: chooses menu option")
    _ = control(.type, ["ref": ed, "text": "edited"])
    eq(js("document.getElementById('ed').innerText") as? String, "edited", "type: editable text")
    _ = control(.type, ["ref": notes, "text": "line"])
    eq(js("document.querySelector('textarea').value") as? String, "line", "type: textarea")
    _ = control(.type, ["ref": form, "text": "sent", "submit": true])
    eq(js("document.title") as? String, "submitted:sent", "type: submit presses Return")
    check(!control(.click, ["ref": b]).1, "click: runs")
    eq(js("window.clicked") as? Int, 1, "click: exactly one click")
    _ = control(.drag, ["from_ref": d1, "to_ref": d2])
    eq(js("document.title") as? String, "dropped", "drag: drop event")
    let s1 = control(.scroll, ["direction": "down", "pages": 2])
    check(!s1.1 && ((js("window.scrollY") as? Double) ?? 0) > 500, "scroll: down", s1.0)
    _ = control(.scroll, ["direction": "up", "pages": 10])
    eq(js("window.scrollY") as? Double, 0, "scroll: up to the top")
    check(control(.click, ["ref": 99999]).1, "click: unknown element is an error")
} else {
    check(false, "page control: refs found", listing)
}

// MARK: Sign-in fields inside shadow roots (Reddit's login)

_ = js("""
document.body.innerHTML = '<div id="host"></div>';
const root = document.getElementById('host').attachShadow({ mode: 'open' });
root.innerHTML = '<div id="u"></div><div id="p"></div>';
root.getElementById('u').attachShadow({ mode: 'open' }).innerHTML = '<input name="username" autocomplete="username">';
root.getElementById('p').attachShadow({ mode: 'open' }).innerHTML = '<input type="password" name="password">';
""")
_ = js(Scripts.logins)
eq(js("window.__lumenFill('me@example.com', 'hunter2')") as? Bool, true, "logins: finds fields in shadow roots")
eq(js("document.getElementById('host').shadowRoot.getElementById('u').shadowRoot.querySelector('input').value") as? String,
   "me@example.com", "logins: fills the username in a shadow root")
eq(js("document.getElementById('host').shadowRoot.getElementById('p').shadowRoot.querySelector('input').value") as? String,
   "hunter2", "logins: fills the password in a shadow root")

// MARK: Highlights are marked, removed and found again

func pageJS(_ code: String, _ args: [String: Any] = [:]) -> Any? {
    var out: Any?, done = false
    wv.callAsyncJavaScript(code, arguments: args, in: nil, in: .page) { r in out = try? r.get(); done = true }
    let deadline = Date().addingTimeInterval(10)
    while !done && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
    return out
}
_ = js("document.body.innerHTML = '<p id=\"p\">The cat sat on <b>the warm</b> mat. The cat sat again.</p>'")
_ = js(Scripts.highlights)
_ = js("""
const p = document.getElementById('p'); const r = document.createRange();
r.setStart(p.firstChild, 4); r.setEnd(p.childNodes[2], 4);
getSelection().removeAllRanges(); getSelection().addRange(r); 1
""")
let hlFound = pageJS("return window.__tacetHL.capture({ id: 'h1', css: 'yellow', note: '' })") as? [String: Any]
eq(hlFound?["quote"] as? String, "cat sat on the warm mat", "highlights: the selection's words are kept")
eq(pageJS("return document.querySelectorAll('mark[data-tacet-hl=h1]').length") as? Int, 3, "highlights: marked across bold text, piece by piece")
let hlBack = pageJS("""
window.__tacetHL.remove('h1');
const gone = document.querySelectorAll('mark').length === 0 && document.getElementById('p').textContent === 'The cat sat on the warm mat. The cat sat again.';
const n = window.__tacetHL.apply([{ id: 'h1', quote: q, prefix: 'The ', suffix: ' The cat', css: 'yellow', note: 'n' }]);
return gone && n === 1 && document.querySelector('mark').textContent === 'cat sat on '
""", ["q": hlFound?["quote"] as? String ?? ""])
eq(hlBack as? Bool, true, "highlights: removed cleanly and found again by its words")
let sampleHL = Highlight(url: URL(string: "https://example.com/a")!, title: "A [page]", quote: "one\n two", prefix: "", suffix: "", note: "mine")
check(sampleHL.markdown.hasPrefix("> one two\n\nmine\n\n— [A [page\\]](https://example.com/a)"), "highlights: Markdown with quote, note and source", sampleHL.markdown)
check(sampleHL.linkToPassage.absoluteString.hasSuffix("#:~:text=one%20two"), "highlights: link opens at the passage", sampleHL.linkToPassage.absoluteString)

// MARK: Drafts go back into their field

_ = js("document.body.innerHTML = '<textarea name=\"msg\"></textarea><input type=\"password\" name=\"pw\">'")
_ = js(Scripts.drafts)
eq(pageJS("return window.__tacetDrafts.restore('name:msg', 'Hello again')") as? String, "ok", "drafts: put back into an empty field")
eq(pageJS("return document.querySelector('textarea').value") as? String, "Hello again", "drafts: the text is there")
eq(pageJS("return window.__tacetDrafts.restore('name:msg', 'other')") as? String, "busy", "drafts: a field with text isn't overwritten")
eq(pageJS("return window.__tacetDrafts.restore('name:pw', 'secret')") as? String, "missing", "drafts: never a password field")

// MARK: Opening rules

let ghRule = OpeningRule(site: "github.com", action: .reuseTab)
check(ghRule.matches(URL(string: "https://gist.github.com/x")!) && ghRule.matches(URL(string: "https://github.com")!), "rules: a site and its subdomains")
check(!ghRule.matches(URL(string: "https://notgithub.com")!), "rules: a lookalike site doesn't match")
eq(OpeningRule.normalizedSite(" https://www.GitHub.com/tacet "), "github.com", "rules: typed site is tidied")
eq(OpeningRule.normalizedSite("not a site"), nil, "rules: not a site")

// MARK: A passkey request is turned down and reported

_ = js("window.passkeyAsked = 0; window.addEventListener('tacet-passkey', () => window.passkeyAsked++)")
_ = js(Scripts.passkeys)
if (js("typeof PublicKeyCredential") as? String) == "function" {
    var errName: Any?, settled = false
    wv.callAsyncJavaScript("try { await navigator.credentials.get({ publicKey: { challenge: new Uint8Array(16) } }); return 'resolved' } catch (e) { return e.name }",
                           arguments: [:], in: nil, in: .page) { r in errName = try? r.get(); settled = true }
    let deadline = Date().addingTimeInterval(5)
    while !settled && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
    eq(errName as? String, "NotAllowedError", "passkeys: a request is turned down")
    eq(js("window.passkeyAsked") as? Int, 1, "passkeys: a request is reported")
} else {
    print("note: no PublicKeyCredential in the test web view, passkey checks skipped")
}

// MARK: Updater: the installed app survives every failure

func swapRun(_ setup: (URL) throws -> (String, String)) -> URL {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("tacet-swap-" + UUID().uuidString)
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let (current, newApp) = (try? setup(dir)) ?? ("", "")
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/bin/sh")
    p.arguments = ["-c", UpdateInstaller.swapScript(current: current, newApp: newApp, waitingFor: 999_999)]
    p.standardError = FileHandle.nullDevice
    try? p.run(); p.waitUntilExit()
    return dir
}
func marker(_ app: URL) -> String? { try? String(contentsOf: app.appendingPathComponent("v"), encoding: .utf8) }
let swapOK = swapRun { dir in
    for (n, v) in [("Tacet.app", "old"), ("New.app", "new")] {
        try FileManager.default.createDirectory(at: dir.appendingPathComponent(n), withIntermediateDirectories: true)
        try v.write(to: dir.appendingPathComponent(n + "/v"), atomically: true, encoding: .utf8)
    }
    return (dir.appendingPathComponent("Tacet.app").path, dir.appendingPathComponent("New.app").path)
}
eq(marker(swapOK.appendingPathComponent("Tacet.app")), "new", "updater: the new app replaces the old one")
let swapBadCopy = swapRun { dir in
    try FileManager.default.createDirectory(at: dir.appendingPathComponent("Tacet.app"), withIntermediateDirectories: true)
    try "old".write(to: dir.appendingPathComponent("Tacet.app/v"), atomically: true, encoding: .utf8)
    return (dir.appendingPathComponent("Tacet.app").path, dir.appendingPathComponent("Missing.app").path)
}
eq(marker(swapBadCopy.appendingPathComponent("Tacet.app")), "old", "updater: a failed copy puts the old app back")
let swapNoMove = swapRun { dir in
    let locked = dir.appendingPathComponent("locked")
    try FileManager.default.createDirectory(at: locked.appendingPathComponent("Tacet.app"), withIntermediateDirectories: true)
    try "old".write(to: locked.appendingPathComponent("Tacet.app/v"), atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: locked.path)
    return (locked.appendingPathComponent("Tacet.app").path, dir.appendingPathComponent("Missing.app").path)
}
eq(marker(swapNoMove.appendingPathComponent("locked/Tacet.app")), "old", "updater: if the app can't be moved aside, it's left alone")
let swapOddPath = swapRun { dir in
    let folder = dir.appendingPathComponent("Davide's $HOME \"apps\"")
    for (n, v) in [("Tacet.app", "old"), ("New.app", "new")] {
        try FileManager.default.createDirectory(at: folder.appendingPathComponent(n), withIntermediateDirectories: true)
        try v.write(to: folder.appendingPathComponent(n + "/v"), atomically: true, encoding: .utf8)
    }
    return (folder.appendingPathComponent("Tacet.app").path, folder.appendingPathComponent("New.app").path)
}
eq(marker(swapOddPath.appendingPathComponent("Davide's $HOME \"apps\"/Tacet.app")), "new", "updater: works in a folder whose name has quotes and $")
for d in [swapOK, swapBadCopy, swapNoMove, swapOddPath] {
    try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: d.appendingPathComponent("locked").path)
    try? FileManager.default.removeItem(at: d)
}

// MARK: Saving: the newest value wins, and nothing waiting is lost when Tacet quits

struct Big: Codable { var n: Int; var pad: [String] }
let stored = StoredFile<Big>(at: FileManager.default.temporaryDirectory.appendingPathComponent("tacet-order-\(UUID().uuidString).json"))
stored.save(Big(n: 1, pad: Array(repeating: String(repeating: "x", count: 1000), count: 5000)), delay: 0)
stored.saveNow(Big(n: 2, pad: []))
stored.flush()
eq(stored.load()?.n, 2, "storage: the newest save wins")
stored.save(Big(n: 3, pad: []), delay: 60)
eq(stored.load()?.n, 2, "storage: a delayed save waits")
StoredFiles.flushAll()
eq(stored.load()?.n, 3, "storage: quitting writes what was waiting")
stored.delete()

// MARK: Encrypted backups

do {
    var c = Backup.Contents()
    c.files = ["bookmarks.json": Data("[1,2,3]".utf8), "Reading List/a.html": Data("<p>x</p>".utf8)]
    c.passwords = "Title,URL,Username,Password\nx,https://x.example/,me,secret"
    c.aiKeys = ["anthropic": "sk-test"]
    c.cookies = ["main": [Backup.StoredCookie(HTTPCookie(properties: [.name: "sid", .value: "v", .domain: ".x.example", .path: "/", .secure: "TRUE"])!)]]
    let sealed = try! Backup.seal(c, password: "correct horse")
    check(!String(decoding: sealed, as: UTF8.self).contains("secret") && !String(decoding: sealed, as: UTF8.self).contains("sk-test"), "backup: nothing readable without the password")
    let back = try? Backup.open(sealed, password: "correct horse")
    eq(back?.files["Reading List/a.html"], Data("<p>x</p>".utf8), "backup: files come back")
    eq(back?.aiKeys["anthropic"], "sk-test", "backup: keys come back")
    eq(back?.cookies["main"]?.first?.cookie?.isSecure, true, "backup: sign-ins come back")
    check((try? Backup.open(sealed, password: "wrong horse")) == nil, "backup: a wrong password opens nothing")
    check((try? Backup.open(Data("{}".utf8), password: "x")) == nil, "backup: another file isn't taken for one")
}

// MARK: Long conversations fit the model

do {
    let big = String(repeating: "x", count: 5000)
    let convo: [[String: Any]] = [
        ["role": "user", "content": "first " + big],
        ["role": "assistant", "content": "ok " + big],
        ["role": "user", "content": [["type": "text", "text": "second"], ["type": "image", "source": ["data": big]]]],
        ["role": "assistant", "content": [["type": "tool_use", "id": "t1", "name": "x", "input": [:]]]],
        ["role": "user", "content": [["type": "tool_result", "tool_use_id": "t1", "content": big]]],
        ["role": "user", "content": "latest " + big],
    ]
    eq(AssistantChat.fitted(convo, budget: 1_000_000).count, 6, "context: a short conversation is left alone")
    let fit = AssistantChat.fitted(convo, budget: 12_000)
    eq(fit.last?["content"] as? String, "latest " + big, "context: the latest request stays whole")
    check(((fit.first?["content"] as? String) ?? "").count < 2000, "context: older text is shortened", "\(fit.first ?? [:])")
    let tiny = AssistantChat.fitted(convo, budget: 6_000)
    check(tiny.count < convo.count && (tiny.first?["role"] as? String) == "user", "context: oldest turns go, starting at a request", "\(tiny.count)")
}

// MARK: The answer in progress fits too (deep research reads many long pages)

/// Whether a transcript is one Anthropic's Messages API accepts: it starts with the user, roles alternate, and each
/// tool_use is answered by a tool_result in the very next message.
func validAnthropic(_ t: [[String: Any]]) -> Bool {
    guard t.first?["role"] as? String == "user" else { return false }
    for (i, m) in t.enumerated() {
        if i > 0, m["role"] as? String == t[i - 1]["role"] as? String { return false }
        let uses = (m["content"] as? [[String: Any]] ?? []).filter { $0["type"] as? String == "tool_use" }.compactMap { $0["id"] as? String }
        guard !uses.isEmpty else { continue }
        guard i + 1 < t.count else { return false }
        let answered = Set((t[i + 1]["content"] as? [[String: Any]] ?? []).compactMap { $0["tool_use_id"] as? String })
        if !Set(uses).isSubset(of: answered) { return false }
    }
    return true
}

/// The same for OpenAI's Chat Completions: every tool call is answered by a tool message before the next turn, and
/// no tool message answers a call that isn't there.
func validOpenAI(_ t: [[String: Any]]) -> Bool {
    guard t.first?["role"] as? String == "user" else { return false }
    var open = Set<String>()
    for m in t {
        if m["role"] as? String == "tool" {
            guard let id = m["tool_call_id"] as? String, open.remove(id) != nil else { return false }
            continue
        }
        if !open.isEmpty { return false }
        for c in m["tool_calls"] as? [[String: Any]] ?? [] { if let id = c["id"] as? String { open.insert(id) } }
    }
    return open.isEmpty
}

func jsonSize(_ t: [[String: Any]]) -> Int { t.reduce(0) { $0 + ((try? JSONSerialization.data(withJSONObject: $1))?.count ?? 0) } }

do {
    // Ten rounds, each reading one long page, as a deep research does; then the model's last round of two pages.
    func research(_ provider: AIProvider, pageChars: Int) -> [[String: Any]] {
        let page = { (n: Int) in String(repeating: "Page \(n) says something. ", count: pageChars / 22) }
        var t: [[String: Any]] = [["role": "user", "content": "old question " + String(repeating: "o", count: 3000)],
                                  ["role": "assistant", "content": "old answer"],
                                  ["role": "user", "content": "Research the topic"]]
        for n in 0..<11 {
            let ids = n == 10 ? ["c10a", "c10b"] : ["c\(n)"]
            let outputs = ids.map { (call: AIClient.ToolCall(id: $0, name: "web_fetch", arguments: [:]), output: page(n), isError: false) }
            if provider == .anthropic {
                t.append(["role": "assistant", "content": [["type": "text", "text": "Reading."]] + ids.map { ["type": "tool_use", "id": $0, "name": "web_fetch", "input": ["url": "https://x.example/\($0)"]] }])
            } else {
                t.append(["role": "assistant", "content": NSNull(), "tool_calls": ids.map { ["id": $0, "type": "function", "function": ["name": "web_fetch", "arguments": "{}"]] }])
            }
            t += AIClient.toolResults(outputs, provider: provider)
        }
        return t
    }
    for (provider, budget) in [(AIProvider.anthropic, 32_000), (.openAI, 32_000), (.anthropic, 250_000), (.openAI, 250_000)] {
        let pages = budget == 32_000 ? 6_000 : 25_000
        let t = research(provider, pageChars: pages)
        let fit = AssistantChat.fitted(t, budget: budget)
        let name = "context (\(provider.rawValue), \(budget)): "
        check(jsonSize(t) > budget, name + "the test starts over budget", "\(jsonSize(t))")
        check(jsonSize(fit) <= budget, name + "the answer in progress fits", "\(jsonSize(fit))")
        check(provider == .anthropic ? validAnthropic(fit) : validOpenAI(fit), name + "every tool call keeps its result, in a valid order")
        let lastRound = t.lastIndex { $0["role"] as? String == "assistant" }!
        let fitLast = fit.lastIndex { $0["role"] as? String == "assistant" }!
        eq(jsonSize(Array(fit[fitLast...])), jsonSize(Array(t[lastRound...])), name + "the last round stays whole")
        eq(fit.first { AssistantChat.isRequest($0) && ($0["content"] as? String) == "Research the topic" } != nil, true, name + "the request stays")
    }
    // Ten whole pages of 60,000 characters at once can't fit 32,000 bytes: they share the room, and still all answer.
    var huge: [[String: Any]] = [["role": "user", "content": "Read them all"],
                                 ["role": "assistant", "content": [["type": "tool_use", "id": "a", "name": "web_fetch", "input": [:]], ["type": "tool_use", "id": "b", "name": "web_fetch", "input": [:]]]]]
    huge += AIClient.toolResults([(AIClient.ToolCall(id: "a", name: "web_fetch", arguments: [:]), String(repeating: "a", count: 60_000), false),
                                  (AIClient.ToolCall(id: "b", name: "web_fetch", arguments: [:]), String(repeating: "b", count: 60_000), false)], provider: .anthropic)
    let squeezed = AssistantChat.fitted(huge, budget: 32_000)
    check(jsonSize(squeezed) <= 32_000 && validAnthropic(squeezed), "context: a last round too big alone shares the room", "\(jsonSize(squeezed))")
    // An older request keeps the user's words after its page when it's shortened.
    let old = AssistantChat.shortened(["role": "user", "content": "<page url=\"u\" title=\"t\">\n" + String(repeating: "p", count: 9000) + "\n</page>\n\nWhat does it say about cats?"])
    check((old["content"] as? String ?? "").hasSuffix("What does it say about cats?"), "context: a shortened request keeps the question")
    // The screenshot after OpenAI tool results isn't a request of its own.
    let shot = AIClient.toolResults([(AIClient.ToolCall(id: "s", name: "take_screenshot", arguments: [:]), "Screenshot", false)], provider: .openAI, images: ["s": Data([1])])
    check(!AssistantChat.isRequest(shot[1]) && AssistantChat.isToolResult(shot[1]), "context: a screenshot message isn't taken for a request")
    // Limits: pages are cut to what the model can take, saying how much arrived.
    eq(AssistantLimits.of(.ollama).pageChars, 6_000, "limits: local models read 6,000 characters of a page")
    eq(AssistantLimits.of(.deepSeek).pageChars, 25_000, "limits: DeepSeek reads 25,000")
    eq(AssistantLimits.of(.anthropic).pageChars, WebTools.textLimit, "limits: others read as before")
    let local8k = AssistantLimits.of(.ollama, contextTokens: 8_192, overhead: 6_000)
    check(local8k.budget < 32_000 && local8k.budget >= 4_000, "limits: a known 8k context sets the budget", "\(local8k)")
    check(AssistantLimits.of(.ollama, contextTokens: 131_072).budget > 32_000, "limits: a big local context takes more")
    let clipped = AssistantLimits.clip(String(repeating: "z", count: 1000), to: 100)
    check(clipped.contains("first 100 of its 1000 characters (10%)"), "limits: a cut page says how much is included", clipped)
    let pageResult = WebTools.format(WebTools.Page(url: URL(string: "https://a.example")!, title: "A", text: String(repeating: "w", count: 30_000), links: []), limit: 6_000)
    check(pageResult.contains("first 6000 of its 30000"), "limits: web_fetch results are cut for small models")
}

// MARK: History beyond what's kept in memory

do {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("tacet-history-\(UUID().uuidString).sqlite")
    if let hdb = HistoryDB(url) {
        let now = Date()
        hdb.save((0..<5).map { i in HistoryEntry(url: URL(string: "https://site\(i).example/page_\(i)")!, title: "Page \(i) 100%",
                                                 date: now.addingTimeInterval(-Double(i) * 3600), visits: i + 1) })
        hdb.flush()
        eq(hdb.count(), 5, "history: counted on disk")
        eq(hdb.load(limit: 2).map(\.title), ["Page 0 100%", "Page 1 100%"], "history: newest page first")
        eq(hdb.load(limit: 2, offset: 2).map(\.title), ["Page 2 100%", "Page 3 100%"], "history: the next page")
        check(hdb.hasIndex, "history: the full-text index is made")
        eq(hdb.search("page", limit: 10).count, 5, "history: the whole history is searched")
        eq(hdb.search("pag", limit: 10).count, 5, "history: a word's start is enough")
        eq(hdb.search("site4 100%", limit: 10).count, 1, "history: every word must match")
        eq(hdb.search("xx%", limit: 10).count, 0, "history: nothing found for a word no page has")
        eq(hdb.search("page", limit: 10).map(\.title).first, "Page 4 100%", "history: the most visited page comes first")
        eq(hdb.search("page", limit: 10, newestFirst: true).map(\.title).first, "Page 0 100%", "history: newest first when asked")
        // Recency: the same visits three months ago weigh less than this week.
        hdb.save([HistoryEntry(url: URL(string: "https://old.example/page")!, title: "Page old", date: now.addingTimeInterval(-100 * 86_400), visits: 30)])
        check(hdb.search("page", limit: 10).first?.title != "Page old", "history: old visits weigh less than recent ones")
        // Typed visits count more than links: one page typed three times beats one followed four times.
        let typedPage = HistoryEntry(url: URL(string: "https://typed.example/a")!, title: "Recipe typed", date: now, visits: 3)
        hdb.save([typedPage], typed: true)
        hdb.save([typedPage], typed: true)
        hdb.save([typedPage], typed: true)
        hdb.save([HistoryEntry(url: URL(string: "https://linked.example/b")!, title: "Recipe linked", date: now, visits: 4)])
        eq(hdb.search("recipe", limit: 10).map(\.title), ["Recipe typed", "Recipe linked"], "history: typed visits rank above links")
        eq(hdb.typedVisits(typedPage.url), 3, "history: typed visits are counted, and kept when the row is replaced")
        // A page on the site you start typing comes before a busier page that only mentions it.
        hdb.save([HistoryEntry(url: URL(string: "https://news.example/about-github")!, title: "github tips", date: now, visits: 40),
                  HistoryEntry(url: URL(string: "https://github.com/")!, title: "GitHub", date: now, visits: 2)])
        eq(hdb.search("github", limit: 10).first?.url.absoluteString, "https://github.com/", "history: a page on the typed site comes first")
        eq(hdb.entry(for: URL(string: "https://site2.example/page_2")!)?.visits, 3, "history: an entry found by its address")
    } else {
        check(false, "history: temporary database opens")
    }
    try? FileManager.default.removeItem(at: url)
}

// MARK: Searching Settings

do {
    // Every toggle and picker in a Settings pane can be found by its name.
    let panes = ["GeneralPane", "AppearancePane", "ShieldPane", "SearchPane", "SitesPane", "AdvancedPane"]
    let source = (try? String(contentsOfFile: "Sources/UI/SettingsView.swift", encoding: .utf8)) ?? ""
    let listed = Set(SettingsSearch.entries.map(\.title))
    var unlisted: [String] = []
    let structs = source.components(separatedBy: "\nstruct ")
    for part in structs where panes.contains(where: { part.hasPrefix($0 + ":") }) {
        let regex = try! NSRegularExpression(pattern: #"\b(?:Toggle|Picker)\("((?:[^"\\]|\\.)*)""#)
        for m in regex.matches(in: part, range: NSRange(part.startIndex..., in: part)) {
            let label = String(part[Range(m.range(at: 1), in: part)!])
            if !label.isEmpty, !label.contains("\\("), !listed.contains(label) { unlisted.append(label) }
        }
    }
    check(!source.isEmpty, "settings search: the panes' source is read")
    eq(unlisted, [], "settings search: every toggle and picker in a pane is listed")
    check(SettingsSearch.matches("cookie").contains { $0.pane == .shield }, "settings search: finds a Shield setting")
    eq(SettingsSearch.matches("zzzz").count, 0, "settings search: nothing for nonsense")
}

// MARK: A file field's accept attribute

eq(FileAccept.types("image/*"), [.image], "accept: image/*")
eq(FileAccept.types(".pdf, .PNG"), [.pdf, .png], "accept: extensions, any case")
eq(FileAccept.types("application/pdf,video/*"), [.pdf, .movie], "accept: MIME types")
eq(FileAccept.types(""), [], "accept: empty offers every file")
eq(FileAccept.types("image/*,nonsense"), [], "accept: anything not understood offers every file")
eq(FileAccept.types("image/*,image/*"), [.image], "accept: no type twice")

// MARK: History from an older Tacet gets its full-text index

do {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("tacet-history-old-\(UUID().uuidString).sqlite")
    var raw: OpaquePointer?
    sqlite3_open(url.path, &raw)
    sqlite3_exec(raw, "CREATE TABLE visits (id TEXT PRIMARY KEY, url TEXT NOT NULL UNIQUE, title TEXT NOT NULL, date REAL NOT NULL, visits INTEGER NOT NULL)", nil, nil, nil)
    let now = Date().timeIntervalSince1970
    for (i, (u, t)) in [("https://ricette.example/carbonara", "Perché la carbonara"), ("https://a.example/", "Alpha"), ("https://b.example/x", "Beta")].enumerated() {
        sqlite3_exec(raw, "INSERT INTO visits VALUES ('\(UUID().uuidString)', '\(u)', '\(t)', \(now - Double(i) * 60), \(i + 1))", nil, nil, nil)
    }
    sqlite3_close(raw)
    func version() -> Int {
        var db: OpaquePointer?, stmt: OpaquePointer?, v = -1
        sqlite3_open(url.path, &db)
        sqlite3_prepare_v2(db, "PRAGMA user_version", -1, &stmt, nil)
        if sqlite3_step(stmt) == SQLITE_ROW { v = Int(sqlite3_column_int64(stmt, 0)) }
        sqlite3_finalize(stmt)
        sqlite3_close(db)
        return v
    }
    func counts() -> (Int, Int) {
        var db: OpaquePointer?, out = [0, 0]
        sqlite3_open(url.path, &db)
        for (i, sql) in ["SELECT count(*) FROM visits", "SELECT count(*) FROM visits_fts_docsize"].enumerated() {
            var stmt: OpaquePointer?
            sqlite3_prepare_v2(db, sql, -1, &stmt, nil)
            if sqlite3_step(stmt) == SQLITE_ROW { out[i] = Int(sqlite3_column_int64(stmt, 0)) }
            sqlite3_finalize(stmt)
        }
        sqlite3_close(db)
        return (out[0], out[1])
    }
    eq(version(), 0, "history migration: an older database starts at version 0")
    if let migrated = HistoryDB(url) {
        check(migrated.hasIndex, "history migration: the index is made")
        eq(migrated.count(), 3, "history migration: every entry is kept")
        eq(migrated.search("perche carbo", limit: 5).map(\.title), ["Perché la carbonara"], "history migration: old entries are found, accents ignored")
        eq(migrated.typedVisits(URL(string: "https://a.example/")!), 0, "history migration: old entries have no typed visits")
        migrated.save([HistoryEntry(url: URL(string: "https://a.example/")!, title: "Alpha renamed", date: Date(), visits: 2)])
        eq(migrated.search("alpha", limit: 5).map(\.title), ["Alpha renamed"], "history migration: a replaced entry is in the index once")
        eq(migrated.search("beta", limit: 5).count, 1, "history migration: other entries stay found")
        migrated.flush()
    } else {
        check(false, "history migration: the older database opens")
    }
    eq(version(), HistoryDB.schemaVersion, "history migration: the version is written")
    let (rows, indexed) = counts()
    eq(rows, indexed, "history migration: the index has one row per entry")
    // An older Tacet replaces a row without the delete trigger; opening again rebuilds the index.
    sqlite3_open(url.path, &raw)
    sqlite3_exec(raw, "INSERT OR REPLACE INTO visits (id, url, title, date, visits) VALUES ('\(UUID().uuidString)', 'https://b.example/x', 'Gamma', \(now), 9)", nil, nil, nil)
    sqlite3_close(raw)
    if let again = HistoryDB(url) {
        eq(again.search("gamma", limit: 5).count, 1, "history migration: a row an older Tacet wrote is found")
        eq(again.search("beta", limit: 5).count, 0, "history migration: the row it replaced isn't")
        again.flush()
        let (r, i) = counts()
        eq(r, i, "history migration: a stale index is rebuilt on opening")
        eq(again.count(), 3, "history migration: opening twice changes nothing else")
    }
    for suffix in ["", "-wal", "-shm"] { try? FileManager.default.removeItem(at: URL(fileURLWithPath: url.path + suffix)) }
}

// MARK: Finding pages by what they said

do {
    let dbURL = FileManager.default.temporaryDirectory.appendingPathComponent("tacet-pagetext-\(UUID().uuidString).sqlite")
    let index = PageText(dbURL)
    let swift = URL(string: "https://example.com/swift-memory")!
    let pasta = URL(string: "https://ricette.example/carbonara")!
    index.keep(url: swift, title: "Profiling apps", text: "To reduce the memory footprint of a Swift app, start with Instruments and look at allocations. " + String(repeating: "More words here. ", count: 10), space: nil)
    index.keep(url: pasta, title: "Carbonara", text: "La carbonara si prepara con guanciale, uova e pecorino, perché la panna non c'entra. " + String(repeating: "Altro testo. ", count: 10), space: nil)
    index.keep(url: URL(string: "https://short.example/")!, title: "Short", text: "too short", space: nil)
    func found(_ q: String) -> [String] {
        var out: [String]?
        Task { out = await index.search(q).map(\.url.absoluteString) }
        while out == nil { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
        return out ?? []
    }
    eq(found("memory footprint"), [swift.absoluteString], "page text: finds a page by words in it")
    eq(found("alloc"), [swift.absoluteString], "page text: a word's start is enough")
    eq(found("perche guanciale"), [pasta.absoluteString], "page text: accents don't matter")
    eq(found("\"memory OR pasta"), [], "page text: typed search syntax is taken as plain words")
    eq(found("too short"), [], "page text: almost empty pages aren't kept")
    var snippet = ""
    Task { snippet = await index.search("guanciale").first?.snippet ?? "-" }
    while snippet.isEmpty { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
    check(snippet.contains("\u{2}guanciale\u{3}"), "page text: the passage marks the word found", snippet)
    index.forget(site: "ricette.example")
    eq(found("guanciale"), [], "page text: forgetting a site removes its pages")
    index.clear()
    eq(found("memory"), [], "page text: clearing removes everything")
    eq(PageText.matchExpression("a \"b"), "\"a\"* \"b\"*", "page text: query becomes quoted prefixes")
    let spaceA = UUID(), spaceB = UUID()
    let long = "Spaces keep their own reading. " + String(repeating: "Filler words here. ", count: 10)
    index.keep(url: swift, title: "Profiling apps", text: long, space: spaceA)
    index.keep(url: swift, title: "Profiling apps", text: long, space: spaceB)
    func inSpace(_ id: UUID) -> Int {
        var out: Int?
        Task { out = await index.search("reading", space: id).count }
        while out == nil { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
        return out ?? -1
    }
    eq([inSpace(spaceA), inSpace(spaceB)], [1, 1], "page text: a page read in two Spaces is found in both")
    // Keeping a page again replaces it; forgetting by address removes it; both go through the address table.
    index.keep(url: swift, title: "Profiling apps", text: long, space: nil)
    eq(found("reading"), [swift.absoluteString], "page text: a page kept again is there once")
    index.keep(url: pasta, title: "Carbonara", text: "Guanciale again, for the address table. " + String(repeating: "Altro testo. ", count: 10), space: nil)
    index.forget(urls: [pasta])
    eq(found("guanciale"), [], "page text: forgetting an address removes its page")
    eq(found("reading"), [swift.absoluteString], "page text: forgetting one address leaves the others")
    // A database written without the address table (an older Tacet) gets it rebuilt when opened.
    index.flush()
    var raw: OpaquePointer?
    sqlite3_open(dbURL.path, &raw)
    sqlite3_exec(raw, "DELETE FROM page_rows", nil, nil, nil)
    sqlite3_close(raw)
    let reopened = PageText(dbURL)
    reopened.keep(url: swift, title: "Profiling apps", text: long, space: nil)
    var again: [String]?
    Task { again = await reopened.search("reading").map(\.url.absoluteString) }
    while again == nil { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
    eq(again ?? [], [swift.absoluteString], "page text: the address table is rebuilt for an older database, with no duplicates")
    // An older Tacet replacing a page leaves the table pointing at a row that's gone, with the same counts.
    reopened.flush()
    var older: OpaquePointer?
    sqlite3_open(dbURL.path, &older)
    sqlite3_exec(older, "DELETE FROM pages WHERE url = '\(swift.absoluteString)'", nil, nil, nil)
    sqlite3_exec(older, "INSERT INTO pages (url, title, body, date, space) VALUES ('\(swift.absoluteString)', 'Profiling apps', 'Spaces keep their own reading, written by an older Tacet. More words here to pass the minimum length of kept text, and more.', 0, '')", nil, nil, nil)
    sqlite3_close(older)
    let third = PageText(dbURL)
    third.keep(url: swift, title: "Profiling apps", text: long, space: nil)
    var once: [String]?
    Task { once = await third.search("reading").map(\.url.absoluteString) }
    while once == nil { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
    eq(once ?? [], [swift.absoluteString], "page text: a page an older Tacet replaced isn't doubled")
    try? FileManager.default.removeItem(at: dbURL)
}

// MARK: Every script Tacet puts in pages is valid JavaScript

do {
    let scripts: [(String, String)] = [
        ("bridge", Scripts.bridge), ("media", Scripts.media), ("fileAccept", Scripts.fileAccept), ("find", Scripts.find), ("popups", Scripts.popups), ("drafts", Scripts.drafts), ("highlights", Scripts.highlights), ("passkeys", Scripts.passkeys),
        ("logins", Scripts.logins), ("gpc", Scripts.gpc), ("cookieBanners", Scripts.cookieBanners),
        ("fingerprinting", Scripts.fingerprinting), ("rejectCookies", Scripts.rejectCookies), ("youtube", Scripts.youtube),
        ("forceDark", Scripts.forceDark), ("siteStyles", Scripts.siteStyles), ("picker", Scripts.picker), ("reader", Scripts.reader),
        ("translate collect", PageTranslator.collectScript), ("translate apply", PageTranslator.applyScript),
        ("translate restore", PageTranslator.restoreScript),
        ("youtube transcript", AssistantSources.transcriptScript),
    ]
    let context = JSGlobalContextCreate(nil)
    for (name, raw) in scripts {
        // Placeholders are filled in before a script goes into a page.
        let source = raw.replacingOccurrences(of: "__ALLOW__", with: "[]").replacingOccurrences(of: "__DARK__", with: "[\"\"]")
            .replacingOccurrences(of: "__TIP__", with: "\"\"").replacingOccurrences(of: "__SHOT__", with: "true")
        func valid(_ code: String) -> Bool {
            let js = JSStringCreateWithUTF8CString(code)
            defer { JSStringRelease(js) }
            return JSCheckScriptSyntax(context, js, nil, 0, nil)
        }
        // Scripts run with callAsyncJavaScript are function bodies.
        check(valid(source) || valid("(async function () {\n" + source + "\n})"), "script \(name) is valid JavaScript")
    }
    JSGlobalContextRelease(context)
}

// MARK: What a quick answer sends (a stand-in server on this Mac)

/// Answers one HTTP request with `reply` and hands back the request's body.
func fakeServer(reply: String) -> (port: Int, body: () -> Data?) {
    let fd = socket(AF_INET, SOCK_STREAM, 0)
    var addr = sockaddr_in()
    addr.sin_family = sa_family_t(AF_INET)
    addr.sin_addr.s_addr = inet_addr("127.0.0.1")
    addr.sin_port = 0
    var len = socklen_t(MemoryLayout<sockaddr_in>.size)
    _ = withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, len) } }
    listen(fd, 1)
    _ = withUnsafeMutablePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &len) } }
    let port = Int(UInt16(bigEndian: addr.sin_port))
    let lock = NSLock()
    var received: Data?
    Thread.detachNewThread {
        let client = accept(fd, nil, nil)
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 65536)
        while true {
            let n = read(client, &buffer, buffer.count)
            if n <= 0 { break }
            data.append(contentsOf: buffer[0..<n])
            if let end = data.range(of: Data("\r\n\r\n".utf8)) {
                let head = String(decoding: data[..<end.lowerBound], as: UTF8.self).lowercased()
                let length = head.split(separator: "\r\n").first { $0.hasPrefix("content-length:") }
                    .flatMap { Int($0.dropFirst("content-length:".count).trimmingCharacters(in: .whitespaces)) } ?? 0
                if data.count - end.upperBound >= length {
                    lock.lock(); received = data[end.upperBound...].prefix(length); lock.unlock()
                    break
                }
            }
        }
        let response = "HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nConnection: close\r\n\r\n" + reply
        _ = response.withCString { write(client, $0, strlen($0)) }
        close(client)
        close(fd)
    }
    return (port, { lock.lock(); defer { lock.unlock() }; return received })
}

func sse(_ events: [String]) -> String { events.map { "data: " + $0 + "\n\n" }.joined() }

do {
    let server = fakeServer(reply: sse([
        #"{"type":"message_start","message":{"id":"m","type":"message","role":"assistant","content":[]}}"#,
        #"{"type":"content_block_start","index":0,"content_block":{"type":"text","text":""}}"#,
        #"{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"Tim "}}"#,
        #"{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"Berners-Lee."}}"#,
        #"{"type":"content_block_stop","index":0}"#,
        #"{"type":"message_delta","delta":{"stop_reason":"end_turn"}}"#,
        #"{"type":"message_stop"}"#,
    ]))
    var streamed = ""
    var answer: AIClient.Result?
    var failure: String?
    Task { @MainActor in
        do {
            answer = try await AIClient.stream(provider: .anthropic, base: "http://127.0.0.1:\(server.port)/v1", key: "test",
                                               model: "claude-haiku-5-5", transcript: [["role": "user", "content": "chi ha inventato il web"]],
                                               tools: true, web: true, control: false, quick: true,
                                               onText: { streamed += $0 }, onServerTool: { _ in })
        } catch { failure = error.localizedDescription }
    }
    let deadline = Date().addingTimeInterval(10)
    while answer == nil && failure == nil && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
    check(failure == nil, "quick answer: the request goes through", failure ?? "")
    eq(streamed, "Tim Berners-Lee.", "quick answer: the reply streams in")
    eq(answer?.stopReason, "end_turn", "quick answer: the reply ends")
    let sent = server.body().flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
    eq(sent["model"] as? String, "claude-haiku-5-5", "quick answer: sent to the fast model")
    eq(sent["max_tokens"] as? Int, 8000, "quick answer: a smaller output limit")
    eq((sent["output_config"] as? [String: Any])?["effort"] as? String, "low", "quick answer: low effort")
    eq((sent["cache_control"] as? [String: Any])?["type"] as? String, "ephemeral", "quick answer: the conversation is cached")
    let system = sent["system"] as? String ?? ""
    check(system.contains("command bar") && system.count < 4000, "quick answer: the short prompt is sent", "\(system.count) characters")
    let tools = (sent["tools"] as? [[String: Any]]) ?? []
    eq(tools.compactMap { $0["name"] as? String }.sorted(), ["tacet_guide", "web_fetch", "web_search"], "quick answer: only the guide and the web")
    eq(tools.first { $0["name"] as? String == "web_search" }?["max_uses"] as? Int, 2, "quick answer: at most two searches")
}

do {
    let server = fakeServer(reply: sse([
        #"{"choices":[{"index":0,"delta":{"role":"assistant","content":"Ciao"}}]}"#,
        #"{"choices":[{"index":0,"delta":{},"finish_reason":"stop"}]}"#,
        "[DONE]",
    ]))
    var streamed = ""
    var done = false
    var failure: String?
    Task { @MainActor in
        do {
            _ = try await AIClient.stream(provider: .openAI, base: "http://127.0.0.1:\(server.port)/v1", key: "test",
                                          model: "gpt-5-mini", transcript: [["role": "user", "content": "ciao"]],
                                          tools: true, web: true, control: false, quick: true,
                                          onText: { streamed += $0 }, onServerTool: { _ in })
        } catch { failure = error.localizedDescription }
        done = true
    }
    let deadline = Date().addingTimeInterval(10)
    while !done && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
    check(failure == nil, "quick answer (OpenAI): the request goes through", failure ?? "")
    eq(streamed, "Ciao", "quick answer (OpenAI): the reply streams in")
    let sent = server.body().flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
    eq(sent["reasoning_effort"] as? String, "low", "quick answer (OpenAI): less reasoning")
    let first = (sent["messages"] as? [[String: Any]])?.first
    check((first?["content"] as? String ?? "").contains("command bar"), "quick answer (OpenAI): the short prompt is the system message")
}

// MARK: Tacet Assistant's steps, deep research and replies (1.8)

do {
    let t0 = Date(timeIntervalSince1970: 1000)
    func step(_ k: AssistantStep.Kind, _ d: String = "", _ secs: Double? = 5, _ status: AssistantStep.Status = .done) -> AssistantStep {
        AssistantStep(kind: k, detail: d, started: t0, ended: secs.map { t0.addingTimeInterval($0) }, status: secs == nil ? .running : status)
    }
    eq(AssistantStep.time(9.7), "9s", "step time: seconds")
    eq(AssistantStep.time(65), "1m 05s", "step time: minutes")
    eq(AssistantStep.time(3720), "1h 02m", "step time: hours")
    eq(AssistantActivity.live([step(.thinking, "", nil)]), L("Thinking"), "live: thinking")
    eq(AssistantActivity.live([step(.thinking, "", nil), step(.search, "mac", nil)]), L("Searching the web"), "live: a running search leads over thinking")
    eq(AssistantActivity.live([step(.read, "a", nil), step(.read, "b", nil)]), String(format: L("Reading %d pages"), 2), "live: pages read at once")
    eq(AssistantActivity.live([step(.search, "q"), step(.thinking, "", nil)]), L("Going through the results"), "live: thinking after results")
    eq(AssistantActivity.live([AssistantStep(kind: .stage, detail: "x", stage: .comparing, started: t0), step(.thinking, "", nil)]), L("Comparing sources"), "live: the research stage the model reported")
    eq(AssistantActivity.live([step(.search, "q")], writing: true), L("Writing the answer"), "live: writing after steps")
    eq(AssistantActivity.live([], writing: true), nil, "live: a plain reply shows no line")
    eq(AssistantActivity.summary([step(.search, "a"), step(.read, "x"), step(.read, "y"), step(.read, "z", 2, .failed)]),
       L("searched the web").prefix(1).uppercased() + L("searched the web").dropFirst() + ", " + String(format: L("read %d pages"), 2),
       "summary: failed reads aren't counted as read")
    eq(AssistantActivity.summary([step(.thinking, "", 1)]), nil, "summary: a moment of thinking says nothing")
    eq(AssistantActivity.summary([step(.thinking, "", 4)]), String(format: L("Thought for %@"), "4s"), "summary: longer thinking")
    eq(AssistantActivity.summary([step(.search, "a"), step(.read, "b")], research: true), String(format: L("Researched: %d searches, %d pages read"), 1, 1), "summary: deep research")
    eq(AssistantActivity.listed([step(.thinking, "", 1), step(.search, "a")]).count, 1, "listed: short thinking is left out")
    eq(AssistantActivity.failures([step(.read, "a", 1, .failed), step(.read, "b")]), 1, "failures counted")
    var s = step(.read, "a", nil)
    s.finish(.failed, outcome: "x", at: t0.addingTimeInterval(3))
    s.finish(.done, at: t0.addingTimeInterval(9))
    check(s.status == .failed && s.duration() == 3 && s.outcome == "x", "a step finishes once")

    // Saved chats: steps round-trip, and chats from before 1.8 still open.
    let saved = AssistantHistory.SavedMessage(user: false, text: "a", images: [], pageTitle: nil, quote: nil, activity: [], links: [], sources: [],
                                              error: nil, steps: [step(.search, "q")], research: true, started: t0, finished: t0)
    let back = try? JSONDecoder().decode(AssistantHistory.SavedMessage.self, from: JSONEncoder().encode(saved))
    check(back?.steps?.first?.detail == "q" && back?.research == true, "saved chat keeps its steps")
    let old = #"{"user":false,"text":"hi","images":[],"activity":["Searching the web for “x”"],"links":[],"sources":[]}"#
    let oldMessage = try? JSONDecoder().decode(AssistantHistory.SavedMessage.self, from: Data(old.utf8))
    check(oldMessage != nil && oldMessage?.steps == nil, "a chat saved before 1.8 still opens")
}

do {
    let research = AssistantPrompt.system(web: true, control: false, research: true)
    check(research.contains("DEEP RESEARCH IS ON") && research.contains("research_stage"), "deep research: the prompt explains it")
    check(!AssistantPrompt.system(web: false, control: false, research: true).contains("DEEP RESEARCH"), "deep research: needs web access")
    check(!AssistantPrompt.system(web: true, control: false).contains("DEEP RESEARCH"), "deep research: off by default")
    check(AssistantPrompt.system(web: true, control: false).contains("Never invent facts"), "prompt: no invented facts")
    check(AssistantPrompt.clientTools(provider: .openAI, web: true, control: false, research: true).contains { $0.name == "research_stage" }, "deep research: the stage tool")
    check(!AssistantPrompt.clientTools(provider: .openAI, web: true, control: false).contains { $0.name == "research_stage" }, "no stage tool without deep research")
    check(JSONSerialization.isValidJSONObject(AssistantPrompt.schema(AssistantPrompt.researchTool)), "stage tool schema")
    eq(AssistantPrompt.anthropicWebTools(model: "claude-opus-5-5", research: true).first?["max_uses"] as? Int, 20, "deep research: more searches")
    check(AIClient.isTransient(AIClient.Failure.http(529, "")) && AIClient.isTransient(URLError(.networkConnectionLost)), "busy service is retried")
    check(!AIClient.isTransient(AIClient.Failure.http(401, "")), "a refused key isn't retried")
    check(AIClient.serverToolFailed(["content": ["type": "web_fetch_tool_error", "error_code": "url_not_accessible"]]), "server fetch error noticed")
    check(!AIClient.serverToolFailed(["content": [["type": "web_search_result"]]]), "server search results aren't an error")
}

do {
    let md = """
    ### Display
    **Bold** opening line
    and its second line

    - one
    - two
      more of two
    1. first
    2) second
    > quoted
    ---
    | A | B |
    |---|:-:|
    | 1 | 2 |
    ```swift
    let x = 1
    """
    let blocks = MarkdownBlocks.parse(md)
    eq(blocks.first, .heading(level: 3, text: "Display"), "markdown: heading")
    eq(blocks[1], .paragraph("**Bold** opening line\nand its second line"), "markdown: bold line is a paragraph, not a list")
    eq(blocks[2], .list([.init(marker: "•", level: 0, text: "one"), .init(marker: "•", level: 0, text: "two\nmore of two"),
                         .init(marker: "1.", level: 0, text: "first"), .init(marker: "2.", level: 0, text: "second")]), "markdown: lists")
    eq(blocks[3], .quote("quoted"), "markdown: quote")
    eq(blocks[4], .rule, "markdown: rule")
    eq(blocks[5], .table(header: ["A", "B"], rows: [["1", "2"]]), "markdown: table")
    eq(blocks[6], .code(language: "swift", text: "let x = 1"), "markdown: a code block still streaming in")
    eq(blocks.count, 7, "markdown: block count")
    eq(MarkdownBlocks.parse("#hashtag"), [.paragraph("#hashtag")], "markdown: a hashtag isn't a heading")
    eq(MarkdownBlocks.listItem("    - deep")?.level, 2, "markdown: nested item level")
}

do {
    // A deep research asks Anthropic for more thinking and more searches, and a reply's server searches are reported.
    let server = fakeServer(reply: sse([
        #"{"type":"content_block_start","index":0,"content_block":{"type":"server_tool_use","id":"srv1","name":"web_search","input":{}}}"#,
        #"{"type":"content_block_delta","index":0,"delta":{"type":"input_json_delta","partial_json":"{\"query\":\"macbook\"}"}}"#,
        #"{"type":"content_block_stop","index":0}"#,
        #"{"type":"content_block_start","index":1,"content_block":{"type":"web_search_tool_result","tool_use_id":"srv1","content":[{"type":"web_search_result","url":"https://a.example","title":"A"},{"type":"web_search_result","url":"https://b.example","title":"B"}]}}"#,
        #"{"type":"content_block_stop","index":1}"#,
        #"{"type":"content_block_start","index":2,"content_block":{"type":"text","text":""}}"#,
        #"{"type":"content_block_delta","index":2,"delta":{"type":"text_delta","text":"Done."}}"#,
        #"{"type":"content_block_stop","index":2}"#,
        #"{"type":"message_delta","delta":{"stop_reason":"end_turn"}}"#,
    ]))
    var events: [String] = []
    var done = false
    Task { @MainActor in
        _ = try? await AIClient.stream(provider: .anthropic, base: "http://127.0.0.1:\(server.port)/v1", key: "test",
                                       model: "claude-opus-5-5", transcript: [["role": "user", "content": "research"]],
                                       tools: true, web: true, control: false, research: true, onText: { _ in },
                                       onServerTool: { e in
                                           switch e {
                                           case .started(let id, let name, let input): events.append("start \(id) \(name) \(input["query"] as? String ?? "")")
                                           case .finished(let id, let n, let failed): events.append("end \(id) \(n ?? -1) \(failed)")
                                           }
                                       })
        done = true
    }
    let deadline = Date().addingTimeInterval(10)
    while !done && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
    eq(events, ["start srv1 web_search macbook", "end srv1 2 false"], "deep research: server searches reported with their results")
    let sent = server.body().flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
    eq((sent["output_config"] as? [String: Any])?["effort"] as? String, "high", "deep research: high effort")
    eq((sent["thinking"] as? [String: Any])?["type"] as? String, "adaptive", "deep research: adaptive thinking")
    let names = ((sent["tools"] as? [[String: Any]]) ?? []).compactMap { $0["name"] as? String }
    check(names.contains("research_stage") && names.contains("web_search"), "deep research: stage tool and web search sent")
    check((sent["system"] as? String ?? "").contains("DEEP RESEARCH IS ON"), "deep research: prompt sent")
}

// MARK: Anti-fingerprinting can't be told apart from the browser's own functions

do {
    let ctx = JSContext()!
    let result = ctx.evaluateScript("""
    (() => {
    \(Scripts.maskHelper)
      const before = Function.prototype.toString.call(Math.max);
      const toStringBefore = Function.prototype.toString.call(Function.prototype.toString);
      maskToString(globalThis);
      mask(Math, 'max', (t, self, args) => 42);
      const d = Object.getOwnPropertyDescriptor(Math, 'max');
      return [Math.max(1, 2) === 42, Function.prototype.toString.call(Math.max) === before, Math.max.toString() === before,
              Math.max.name === 'max', Math.max.length === 2, d.writable && !d.enumerable && d.configurable,
              Function.prototype.toString.call(Function.prototype.toString) === toStringBefore,
              before.includes('[native code]')].join(',');
    })()
    """)?.toString() ?? ""
    eq(result, "true,true,true,true,true,true,true,true", "fingerprinting: masked functions look native (call, toString, name, length, descriptor)")
}

// MARK: Sign-in forms in embedded frames

check(PasswordStore.frameMayFill(scheme: "https", frameHost: "accounts.example.com", savedHost: "example.com"), "frame login: same site over HTTPS")
check(PasswordStore.frameMayFill(scheme: "HTTPS", frameHost: "Login.Example.com", savedHost: "www.example.com"), "frame login: case doesn't matter")
check(!PasswordStore.frameMayFill(scheme: "http", frameHost: "accounts.example.com", savedHost: "example.com"), "frame login: never over HTTP")
check(!PasswordStore.frameMayFill(scheme: "https", frameHost: "ads.tracker.net", savedHost: "example.com"), "frame login: never another site's frame")
check(!PasswordStore.frameMayFill(scheme: "https", frameHost: "example.com.evil.net", savedHost: "example.com"), "frame login: a look-alike host is another site")
check(!PasswordStore.frameMayFill(scheme: "https", frameHost: "", savedHost: "example.com"), "frame login: a frame without a host gets nothing")

// MARK: Completing addresses in the command bar

do {
    func entry(_ u: String, _ visits: Int) -> HistoryEntry { HistoryEntry(url: URL(string: u)!, title: "", date: Date(), visits: visits) }
    let sites = InlineCompletion.candidates([entry("https://github.com/", 20), entry("https://www.github.com/apple/swift", 5),
                                             entry("https://gitlab.com/", 3), entry("https://gizmodo.com/", 1), entry("https://hub.docker.com/", 9)])
    eq(InlineCompletion.complete("gi", candidates: sites), "github.com", "completion: the most visited site")
    eq(InlineCompletion.complete("gitl", candidates: sites), "gitlab.com", "completion: narrows as you type")
    eq(InlineCompletion.complete("giz", candidates: sites), nil, "completion: a site visited once isn't offered")
    eq(InlineCompletion.complete("thub", candidates: sites), nil, "completion: never in the middle of a name")
    eq(InlineCompletion.complete("hub", candidates: sites), "hub.docker.com", "completion: from the start of a name")
    eq(InlineCompletion.complete("www.gi", candidates: sites), "github.com", "completion: www. is ignored")
    eq(InlineCompletion.complete("github.com/a", candidates: sites), "github.com/apple/swift", "completion: pages once a / is typed")
    eq(InlineCompletion.complete("github.com", candidates: sites), nil, "completion: nothing to add")
    eq(InlineCompletion.complete("how to", candidates: sites), nil, "completion: never for words with spaces")
    eq(InlineCompletion.suffix(of: "github.com", typed: "Gi"), "thub.com", "completion: the grey part after what was typed")
}

// MARK: Unit conversions and open tabs in the command bar

do {
    func conv(_ t: String) -> String? { UnitConversion.convert(t).map { String(format: "%.2f %@", $0.value, $0.symbol) } }
    eq(conv("10 km"), "6.21 mi", "units: km to miles by default")
    eq(conv("10 km in m"), "10000.00 m", "units: an explicit target")
    eq(conv("100 °F"), "37.78 °C", "units: Fahrenheit to Celsius")
    eq(conv("21 c to f"), "69.80 °F", "units: c to f")
    eq(conv("70 kg"), "154.32 lb", "units: kg to pounds")
    eq(conv("2,5 kg in g"), "2500.00 g", "units: a comma as decimal point")
    eq(conv("12 in"), "30.48 cm", "units: inches")
    eq(conv("5 in in cm"), "12.70 cm", "units: inches to cm with in")
    eq(conv("10 km in kg"), nil, "units: different kinds don't convert")
    eq(conv("10 apples"), nil, "units: unknown words are left alone")
    eq(conv("hello"), nil, "units: not a number")
    check(InlineCompletion.sameAddress(URL(string: "https://www.example.com/a/"), URL(string: "http://example.com/a#top")), "same address: www, slash, fragment")
    check(!InlineCompletion.sameAddress(URL(string: "https://example.com/a"), URL(string: "https://example.com/b")), "same address: other pages differ")
}

// MARK: Page dialogs

do {
    var policy = DialogPolicy()
    let t0 = Date(timeIntervalSince1970: 0)
    check(!policy.record(t0), "dialogs: the first one doesn't offer to stop them")
    check(policy.record(t0.addingTimeInterval(5)), "dialogs: the second soon after offers to stop them")
    check(!policy.record(t0.addingTimeInterval(100)), "dialogs: one long after is a first again")
    policy.reset()
    check(policy.shown.isEmpty, "dialogs: a new page starts over")
    // A page that's stopped gets its answers at once, without a dialog.
    let d = PageDialogs()
    var answers: [String] = []
    d.alert(title: "", message: "a") { answers.append("alert") }
    check(d.isWaiting, "dialogs: no window yet, so the dialog waits")
    d.confirm(title: "", message: "b") { answers.append("confirm \($0)") }
    d.prompt(title: "", message: "c", defaultText: "x") { answers.append("prompt \($0 ?? "nil")") }
    d.reset()
    eq(answers, ["alert", "confirm false", "prompt nil"], "dialogs: leaving the page answers every waiting dialog")
    check(!d.isWaiting, "dialogs: nothing left waiting")
}

// MARK: A mouse wheel scrolls the tabs along the top

do {
    let strip = NSScrollView(frame: NSRect(x: 0, y: 0, width: 300, height: 34))
    strip.hasHorizontalScroller = false
    strip.documentView = NSView(frame: NSRect(x: 0, y: 0, width: 1000, height: 34))
    let x = { strip.contentView.bounds.origin.x }
    check(WheelScrollsSideways.WheelView.scroll(strip, deltaY: -3, precise: false) && x() == 48, "tab strip: wheel down goes right", "\(x())")
    _ = WheelScrollsSideways.WheelView.scroll(strip, deltaY: -1000, precise: false)
    eq(x(), 700, "tab strip: stops at the last tab")
    _ = WheelScrollsSideways.WheelView.scroll(strip, deltaY: 20, precise: true)
    eq(x(), 680, "tab strip: trackpad deltas are points")
    _ = WheelScrollsSideways.WheelView.scroll(strip, deltaY: 1000, precise: false)
    eq(x(), 0, "tab strip: stops at the first tab")
    let fits = NSScrollView(frame: NSRect(x: 0, y: 0, width: 300, height: 34))
    fits.documentView = NSView(frame: NSRect(x: 0, y: 0, width: 200, height: 34))
    check(!WheelScrollsSideways.WheelView.scroll(fits, deltaY: -3, precise: false), "tab strip: a wheel passes through when the tabs fit")
}

// MARK: Models on this Mac: context, Ollama's own API, short instructions

do {
    let show: [String: Any] = ["model_info": ["general.architecture": "llama", "llama.context_length": 131072],
                               "parameters": "num_keep                       24\nstop                           \"<|eot_id|>\""]
    let c = LocalModels.ollamaContext(show)
    eq(c.max, 131072, "local: Ollama's trained context from model_info")
    eq(c.tokens, LocalModels.ollamaPreferred, "local: Tacet asks Ollama for 16k when the model allows it")
    var withCtx = show
    withCtx["parameters"] = "num_ctx 8192\ntemperature 0.7"
    eq(LocalModels.ollamaContext(withCtx).tokens, 8192, "local: a num_ctx set in the Modelfile is kept")
    eq(LocalModels.ollamaContext(["model_info": ["gemma3.context_length": 2048]]).tokens, 2048, "local: never more than the model was trained for")
    eq(LocalModels.ollamaContext([:]).tokens, LocalModels.ollamaDefault, "local: Ollama's default when nothing is known")

    let lm: [String: Any] = ["models": [["key": "qwen3-8b", "max_context_length": 262144,
                                         "loaded_instances": [["id": "qwen3-8b", "config": ["context_length": 4096]]]],
                                        ["key": "gemma-3", "max_context_length": 131072, "loaded_instances": [] as [Any]]]]
    eq(LocalModels.lmStudioContext(lm, model: "qwen3-8b")?.tokens, 4096, "local: LM Studio's loaded context, not the model's maximum")
    check(LocalModels.lmStudioContext(lm, model: "gemma-3") == nil, "local: LM Studio model not loaded: context unknown")

    check(LocalModels.isCompact(.ollama, tokens: 8192), "local: 8k context uses the short instructions")
    check(!LocalModels.isCompact(.ollama, tokens: 32768), "local: 32k context keeps the full instructions")
    check(LocalModels.isCompact(.lmStudio, tokens: nil), "local: unknown context of a local model is treated as small")
    check(!LocalModels.isCompact(.anthropic, tokens: 8192), "local: hosted models never use the short instructions")

    let full = AssistantPrompt.overhead(provider: .ollama, model: "llama3.1", web: true, control: true, quick: false, research: false)
    let compact = AssistantPrompt.overhead(provider: .ollama, model: "llama3.1", web: true, control: true, quick: false, research: false, compact: true)
    print("measure: instructions + tools for a local model, full \(full) bytes, short \(compact) bytes")
    check(compact * 3 < full, "local: short instructions and tools are under a third of the full ones", "\(compact) vs \(full)")
    check(compact / AssistantLimits.charsPerToken < 1_500, "local: short profile leaves most of a 4k context free", "\(compact)")
    let kept = AssistantPrompt.compactTools(AssistantPrompt.clientTools(provider: .ollama, web: true, control: false)).map(\.name)
    check(kept.contains("web_search") && kept.contains("tacet_guide") && kept.contains("get_page_content"), "local: short profile keeps the tools it needs", "\(kept)")
    check(!kept.contains("use_plugin") && !kept.contains("group_tabs"), "local: short profile leaves out the rest")
    check(AssistantPrompt.compactSystem(web: true, control: false).contains("never instructions"), "local: short instructions keep the safety rule")

    // The transcript stays in the OpenAI shape; Ollama's own API gets it converted.
    let transcript: [[String: Any]] = [
        ["role": "system", "content": "sys"],
        ["role": "user", "content": [["type": "text", "text": "what is this"],
                                     ["type": "image_url", "image_url": ["url": "data:image/jpeg;base64,QUJD"]]]],
        ["role": "assistant", "content": NSNull(), "tool_calls": [["id": "call_1", "type": "function",
                                                                   "function": ["name": "web_search", "arguments": "{\"query\":\"x\"}"]]]],
        ["role": "tool", "tool_call_id": "call_1", "content": "results"],
    ]
    let o = AIClient.ollamaMessages(transcript)
    eq(o[1]["content"] as? String, "what is this", "ollama: text parts become content")
    eq(o[1]["images"] as? [String], ["QUJD"], "ollama: pictures go in images as base64")
    let call = ((o[2]["tool_calls"] as? [[String: Any]])?.first?["function"] as? [String: Any])
    eq((call?["arguments"] as? [String: Any])?["query"] as? String, "x", "ollama: tool arguments are an object")
    eq(o[2]["content"] as? String, "", "ollama: an empty assistant turn has empty content")
    eq(o[3]["tool_name"] as? String, "web_search", "ollama: a tool result is named by its tool")

    let lines = [
        #"{"model":"m","message":{"role":"assistant","content":"Hel"},"done":false}"#,
        #"{"model":"m","message":{"role":"assistant","content":"lo","thinking":"hidden"},"done":false}"#,
        #"{"model":"m","message":{"role":"assistant","content":"","tool_calls":[{"function":{"name":"web_search","arguments":{"query":"rome"}}}]},"done":false}"#,
        #"{"model":"m","message":{"role":"assistant","content":""},"done":true,"done_reason":"stop"}"#,
    ]
    let stream = AsyncThrowingStream<String, Error> { c in lines.forEach { c.yield($0) }; c.finish() }
    var shown = ""
    let sem = DispatchSemaphore(value: 0)
    var result: AIClient.Result?
    Task { @MainActor in
        result = try? await AIClient.readOllama(stream) { shown += $0 }
        sem.signal()
    }
    while sem.wait(timeout: .now()) == .timedOut { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
    eq(shown, "Hello", "ollama: streamed text, without the thinking")
    eq(result?.toolCalls.first?.name, "web_search", "ollama: tool call read")
    eq(result?.toolCalls.first?.arguments?["query"] as? String, "rome", "ollama: tool call arguments")
    let back = (result?.assistantMessage["tool_calls"] as? [[String: Any]])?.first
    eq(back?["id"] as? String, result?.toolCalls.first?.id, "ollama: reply kept in the OpenAI shape with the same call id")
}

// MARK: Links in a reply are checked against the pages the assistant saw

do {
    let reply = """
    Apple says so ([Apple](https://www.apple.com/newsroom/2026/10/m6/)). See https://example.org/a_(b), \
    <https://news.example.com/x> and www.wiki.example/page.
    Also **https://bold.example/p**. Not `https://code.example/x`.
    ```
    https://block.example/y
    ```
    Again [Apple](https://www.apple.com/newsroom/2026/10/m6/).
    """
    eq(AssistantCitations.links(in: reply), ["https://www.apple.com/newsroom/2026/10/m6/", "https://example.org/a_(b)",
                                              "https://news.example.com/x", "www.wiki.example/page", "https://bold.example/p"],
       "citations: Markdown links, autolinks and bare addresses, without code or repeats")
    eq(AssistantCitations.trimmed("https://a.example/x)."), "https://a.example/x", "citations: trailing parenthesis and full stop dropped")

    let n = AssistantCitations.normalize
    eq(n("https://www.Apple.com/newsroom/#top"), "apple.com/newsroom", "citations: scheme, www, case of host, slash and fragment ignored")
    eq(n("http://apple.com/newsroom"), n("https://www.apple.com/newsroom/"), "citations: http and https are the same page")
    eq(n("https://a.example/p?id=3&utm_source=x&fbclid=y"), "a.example/p?id=3", "citations: tracking parameters dropped")
    eq(n("https://a.example:443/p"), "a.example/p", "citations: default port dropped")
    eq(n("https://a.example:8080/p"), "a.example:8080/p", "citations: other ports kept")
    eq(n("https://a.example/Page"), "a.example/Page", "citations: path case kept")
    eq(n("https://www.google.com/url?q=https://b.example/z&sa=D"), "b.example/z", "citations: a click-tracking redirect counts as its target")
    check(n("mailto:a@b.example") == nil && n("file:///etc/hosts") == nil, "citations: only web addresses")

    let conversation = "Results: https://news.example.com/x/ and www.apple.com/newsroom/2026/10/m6"
    let read = [URL(string: "https://example.org/a_(b)")!, URL(string: "http://bold.example/p?utm_medium=e")!]
    let flagged = AssistantCitations.unverified(in: reply, conversation: conversation, read: read)
    eq(flagged, ["wiki.example/page"], "citations: only the address nobody saw is flagged")
    eq(AssistantCitations.unverified(in: "No links here.", conversation: "", read: []), [], "citations: nothing to check")
    check(AssistantCitations.isUnverified(URL(string: "https://www.wiki.example/page/#s")!, in: flagged), "citations: a shown link matches its flagged form")
    check(!AssistantCitations.isUnverified(URL(string: "https://apple.com/newsroom/2026/10/m6")!, in: flagged), "citations: a read page isn't flagged")

    let transcript: [[String: Any]] = [["role": "user", "content": "Look at https://user.example/doc"],
                                       ["role": "assistant", "content": "I made up https://made.example/up"]]
    eq(AssistantCitations.unverified(in: "[a](https://user.example/doc) [b](https://made.example/up)", transcript: transcript, read: []),
       ["made.example/up"], "citations: the model's own words don't count as seen")

    let saved = AssistantHistory.SavedMessage(user: false, text: "a", images: [], pageTitle: nil, quote: nil, activity: [], links: [], sources: [],
                                              error: nil, steps: nil, research: nil, started: nil, finished: nil, unverified: ["made.example/up"])
    let back = try? JSONDecoder().decode(AssistantHistory.SavedMessage.self, from: JSONEncoder().encode(saved))
    eq(back?.unverified ?? [], ["made.example/up"], "citations: a saved chat keeps its unverified links")
    check(AssistantCitations.researchNote(2).contains("2"), "citations: the research note counts the links")
}

// MARK: Web search engines

do {
    /// Waits for an async piece of a test, as the page text tests do.
    func wait<T>(_ body: @escaping () async -> T) -> T {
        var out: T?
        Task { out = await body() }
        let deadline = Date().addingTimeInterval(10)
        while out == nil && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
        return out!
    }

    // SearXNG's JSON API.
    let searx = Data(#"{"query":"swift","number_of_results":0,"results":[{"url":"https://swift.org/","title":"Swift.org","content":"Swift is a <b>general-purpose</b> language","engine":"brave"},{"url":"https://swift.org/","title":"Again","content":"dup"},{"url":"javascript:alert(1)","title":"Bad"},{"url":"https://developer.apple.com/swift/","title":"","content":null}],"answers":[],"suggestions":[]}"#.utf8)
    let sx = (try? SearXNG.parse(searx)) ?? []
    eq(sx.map(\.url), ["https://swift.org/", "https://developer.apple.com/swift/"], "searxng: http results, once each")
    eq(sx.first?.snippet, "Swift is a general-purpose language", "searxng: markup taken out of the snippet")
    eq(sx.last?.title, "https://developer.apple.com/swift/", "searxng: an untitled result shows its address")
    check((try? SearXNG.parse(Data("<html>Forbidden</html>".utf8))) == nil, "searxng: an answer that isn't JSON is an error")
    eq(SearXNG(address: "searx.example.org/")?.endpoint.absoluteString, "https://searx.example.org/search", "searxng: address without scheme")
    eq(SearXNG(address: "http://localhost:8888/search?q=old")?.endpoint.absoluteString, "http://localhost:8888/search", "searxng: own server, /search kept once")
    check(SearXNG(address: "  ") == nil && SearXNG(address: "ftp://x.org") == nil, "searxng: not set up without an http address")
    let searxQuery = SearXNG(address: "https://s.example")!.requestURL("a b").query ?? ""
    check(searxQuery.contains("format=json") && searxQuery.contains("q=a%20b"), "searxng: asks for JSON", searxQuery)

    // Brave Search API.
    let brave = Data(#"{"type":"search","query":{"original":"swift"},"web":{"type":"search","results":[{"title":"The <strong>Swift</strong> Language","url":"https://swift.org/","description":"Learn <strong>Swift</strong> today","age":"2 days ago"},{"title":"Docs","url":"https://docs.swift.org/","description":"Guides"}]},"news":{"results":[{"title":"News","url":"https://news.example/"}]}}"#.utf8)
    let br = (try? BraveSearch.parse(brave)) ?? []
    eq(br.map(\.url), ["https://swift.org/", "https://docs.swift.org/"], "brave: only web results")
    eq(br.first?.title, "The Swift Language", "brave: <strong> taken out of the title")
    eq(br.first?.snippet, "Learn Swift today", "brave: description is the snippet")
    eq((try? BraveSearch.parse(Data(#"{"type":"search","news":{"results":[]}}"#.utf8)))?.count, 0, "brave: no web section, no results")
    let braveRequest = BraveSearch(key: " k123 ")!.request("x")
    eq(braveRequest.value(forHTTPHeaderField: "X-Subscription-Token"), "k123", "brave: key sent in its header")
    check(BraveSearch(key: "  ") == nil, "brave: not set up without a key")

    // DuckDuckGo's check for bots.
    let anomaly = #"<html><body><form id="challenge-form" action="//duckduckgo.com/anomaly.js"><div class="anomaly-modal__title">Unfortunately, bots use DuckDuckGo too.</div></form></body></html>"#
    eq(WebTools.readDuckDuckGo(anomaly), .blocked, "ddg: the check for bots is recognized")
    eq(WebTools.readDuckDuckGo("<html><body></body></html>"), .blocked, "ddg: an empty page counts as blocked")
    eq(WebTools.readDuckDuckGo(#"<div class="no-results">No  results.</div>"#), .noResults, "ddg: its No results page isn't an error")
    if case .results(let r) = WebTools.readDuckDuckGo(ddg) { eq(r.count, parsed.count, "ddg: a results page has results") }
    else { check(false, "ddg: a results page has results") }
    final class Count: @unchecked Sendable { var n = 0; let lock = NSLock()
        func next() -> Int { lock.lock(); defer { lock.unlock() }; n += 1; return n } }
    let loads = Count()
    var retried = DuckDuckGo()
    retried.retryDelay = .zero
    retried.load = { _ in loads.next() == 1 ? anomaly : ddg }
    let afterRetry = wait { (try? await retried.search("x"))?.count ?? -1 }
    eq(afterRetry, parsed.count, "ddg: blocked once, asked again after a pause")
    eq(loads.n, 2, "ddg: one more try only")
    let stillBlocked = Count()
    var blocked = DuckDuckGo()
    blocked.retryDelay = .zero
    blocked.load = { _ in _ = stillBlocked.next(); return anomaly }
    let blockedError = wait { () -> String in
        do { _ = try await blocked.search("x"); return "no error" } catch { return (error as? LocalizedError)?.errorDescription ?? "" }
    }
    check(blockedError.contains("DuckDuckGo is refusing"), "ddg: blocked twice is its own error", blockedError)
    eq(stillBlocked.n, 2, "ddg: gives up after two tries")

    // Engines in order, moving on when one fails.
    struct Fake: WebSearchEngine {
        let name: String
        let answer: @Sendable () async throws -> [WebTools.SearchResult]
        func search(_ query: String) async throws -> [WebTools.SearchResult] { try await answer() }
    }
    let hit = [WebTools.SearchResult(title: "T", url: "https://t.example/", snippet: "")]
    let down = Fake(name: "SearXNG") { throw WebTools.Failure.http(502) }
    let none = Fake(name: "Brave") { [] }
    let good = Fake(name: "DuckDuckGo") { hit }
    let gate = SearchGate(limit: 3)
    let fellBack = wait { (try? await WebTools.search("q", engines: [down, none, good], gate: gate))?.engine ?? "failed" }
    eq(fellBack, "DuckDuckGo", "search: falls back past a failing and an empty engine")
    let firstWins = wait { (try? await WebTools.search("q", engines: [good, down], gate: gate))?.engine ?? "failed" }
    eq(firstWins, "DuckDuckGo", "search: the first engine that answers is used")
    let onlyEmpty = wait { (try? await WebTools.search("q", engines: [down, none], gate: gate)).map { "\($0.engine) \($0.results.count)" } ?? "failed" }
    eq(onlyEmpty, "Brave 0", "search: no results from any engine is no results, not an error")
    let allDown = wait { () -> String in
        do { _ = try await WebTools.search("q", engines: [down, Fake(name: "Brave") { throw WebTools.Failure.engine("Bad key.") }], gate: gate); return "" }
        catch { return (error as? LocalizedError)?.errorDescription ?? "" }
    }
    check(allDown.contains("SearXNG: The server answered with error 502.") && allDown.contains("Brave: Bad key."), "search: every engine's reason when all fail", allDown)

    // Which engines are set up, in the saved order.
    eq(SearchEngines.configured(order: SearchEngineKind.defaultOrder, searxURL: "", braveKey: nil).map(\.name), ["DuckDuckGo"], "engines: nothing set up, DuckDuckGo only")
    eq(SearchEngines.configured(order: SearchEngineKind.defaultOrder, searxURL: "searx.example", braveKey: "k").map(\.name), ["SearXNG", "Brave", "DuckDuckGo"], "engines: default order, DuckDuckGo last")
    eq(SearchEngines.configured(order: ["brave", "duckduckgo", "gone"], searxURL: "searx.example", braveKey: "k").map(\.name), ["Brave", "DuckDuckGo", "SearXNG"], "engines: saved order, unknown names dropped, new ones at the end")

    // At most three searches at once.
    actor Peak { var now = 0, most = 0
        func enter() { now += 1; most = max(most, now) }
        func leave() { now -= 1 } }
    let peak = Peak()
    let slow = Fake(name: "Slow") { await peak.enter(); try await Task.sleep(for: .milliseconds(30)); await peak.leave(); return hit }
    let most = wait { () -> Int in
        await withTaskGroup(of: Void.self) { group in
            for n in 0..<8 { group.addTask { _ = try? await WebTools.search("q\(n)", engines: [slow], gate: gate) } }
        }
        return await peak.most
    }
    eq(most, 3, "search: at most three at the same time")
}

// MARK: Assistant chat history: search, pins, Markdown

do {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("tacet-chats-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    func msg(_ user: Bool, _ text: String, links: [AssistantHistory.SavedLink] = [], sources: [AssistantHistory.SavedLink] = []) -> AssistantHistory.SavedMessage {
        .init(user: user, text: text, images: [], activity: [], links: links, sources: sources)
    }
    let wal = UUID(), pasta = UUID(), old = UUID()
    let db = folder.appendingPathComponent("Search.sqlite")
    let search = AssistantSearch(database: db, chats: folder)
    func found(_ s: AssistantSearch, _ q: String) -> [UUID] {
        var out: [UUID]?
        Task { out = await s.search(q).map(\.id) }
        while out == nil { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
        return out ?? []
    }
    search.index(id: wal, title: "SQLite question", messages: [msg(true, "What is WAL mode?"), msg(false, "Write-ahead logging keeps readers and the writer apart.")])
    search.index(id: pasta, title: "Dinner", messages: [msg(true, "Carbonara?"), msg(false, "Guanciale, uova e pecorino, perché la panna no.")])
    eq(found(search, "readers writer"), [wal], "chat search: finds a chat by words in an answer")
    eq(found(search, "perche guan"), [pasta], "chat search: accents don't matter, a word's start is enough")
    eq(found(search, "dinner"), [pasta], "chat search: finds a chat by its title")
    var snippet = ""
    Task { snippet = await search.search("logging").first?.snippet ?? "-" }
    while snippet.isEmpty { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
    check(snippet.contains("\u{2}logging\u{3}"), "chat search: the passage marks the word found", snippet)
    search.index(id: wal, title: "SQLite question", messages: [msg(true, "Something else entirely")])
    eq(found(search, "readers"), [], "chat search: a chat saved again replaces what was kept")
    eq(found(search, "entirely"), [wal], "chat search: the chat saved again is found by its new text")
    search.remove(pasta)
    eq(found(search, "guanciale"), [], "chat search: a deleted chat isn't found")
    // A chat saved before the index existed (its file only) is added; one no longer saved is dropped.
    let oldChat = AssistantHistory.Saved(summary: .init(id: old, title: "Old chat", date: Date(), provider: "anthropic"),
                                         messages: [msg(true, "Tell me about fermata signs")], transcript: [], model: nil)
    try? AssistantHistory.fileData(oldChat)?.write(to: folder.appendingPathComponent(old.uuidString + ".json"))
    search.sync(with: [(old, "Old chat")])
    eq(found(search, "fermata"), [old], "chat search: chats saved earlier are indexed from their files")
    eq(found(search, "entirely"), [], "chat search: chats no longer saved are dropped from the index")
    var n = -1
    Task { n = await search.count() }
    while n < 0 { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
    eq(n, 1, "chat search: the index holds exactly the saved chats")
    search.flush()
    let reopened = AssistantSearch(database: db, chats: folder)
    eq(found(reopened, "fermata"), [old], "chat search: the index is kept between launches")
    check(AssistantSearch.body([msg(true, String(repeating: "a", count: AssistantSearch.charLimit + 50))]).count == AssistantSearch.charLimit, "chat search: text kept per chat is capped")

    // Pinned chats come first, newest first in each group.
    let now = Date()
    let a = AssistantHistory.Summary(id: UUID(), title: "Newest", date: now, provider: "")
    let b = AssistantHistory.Summary(id: UUID(), title: "Pinned old", date: now.addingTimeInterval(-300), provider: "", pinned: true)
    let c = AssistantHistory.Summary(id: UUID(), title: "Middle", date: now.addingTimeInterval(-100), provider: "")
    let d = AssistantHistory.Summary(id: UUID(), title: "Pinned new", date: now.addingTimeInterval(-200), provider: "", pinned: true)
    eq(AssistantHistory.ordered([a, b, c, d]).map(\.title), ["Pinned new", "Pinned old", "Newest", "Middle"], "chat history: pinned chats at the top")
    eq(AssistantHistory.matching([a, b, c, d], query: "middle", found: [:]).map(\.title), ["Middle"], "chat history: search by title")
    eq(AssistantHistory.matching([a, b, c, d], query: "zzz", found: [a.id: "x", b.id: "y"]).map(\.title), ["Pinned old", "Newest"], "chat history: search by text, pinned first")
    let decoded = try? JSONDecoder().decode([AssistantHistory.Summary].self, from: Data(#"[{"id":"\#(UUID().uuidString)","title":"t","date":0,"provider":"p"}]"#.utf8))
    check(decoded?.first != nil && decoded?.first?.pinned == nil, "chat history: chats saved before pins load, not pinned")

    // Markdown export: title, each message under who said it, sources at the bottom once each.
    let src = AssistantHistory.SavedLink(url: URL(string: "https://sqlite.org/wal.html")!, title: "Write-Ahead [Logging]")
    let md = AssistantHistory.markdown(.init(summary: .init(id: wal, title: "SQLite question", date: now, provider: ""),
                                             messages: [msg(true, "What is WAL mode?"),
                                                        msg(false, "It keeps readers apart.", links: [src], sources: [src, .init(url: URL(string: "https://example.com/b")!, title: "")])],
                                             transcript: [], model: nil))
    check(md.hasPrefix("# SQLite question\n"), "chat export: starts with the title", md)
    check(md.contains("**You:**\n\nWhat is WAL mode?"), "chat export: the question under You", md)
    check(md.contains("**Tacet Assistant:**\n\nIt keeps readers apart."), "chat export: the answer under Tacet Assistant", md)
    check(md.contains("## Sources\n\n- [Write-Ahead \\[Logging\\]](https://sqlite.org/wal.html)\n- [https://example.com/b](https://example.com/b)\n"), "chat export: sources at the bottom, once each", md)
    check(md.range(of: "## Sources")!.lowerBound > md.range(of: "It keeps readers apart.")!.lowerBound, "chat export: sources after the messages")
    check(!AssistantHistory.markdown(.init(summary: a, messages: [msg(true, "hi")], transcript: [], model: nil)).contains("## Sources"), "chat export: no Sources heading without sources")
    eq(AssistantExport.fileName("a/b: c…"), "a-b- c", "chat export: file name without characters a file name can't hold")
    eq(AssistantExport.fileName("..."), "Untitled chat", "chat export: an empty file name gets a default")
    try? FileManager.default.removeItem(at: folder)
}

// MARK: Tabs attached with @, the model for small jobs, and the tokens an answer used

do {
    eq(AssistantChat.mentionQuery(in: "compare @gi"), "gi", "@: the query after the @")
    eq(AssistantChat.mentionQuery(in: "@"), "", "@: a lone @ opens the list")
    eq(AssistantChat.mentionQuery(in: "write to a@b"), nil, "@: an e-mail address isn't a mention")
    eq(AssistantChat.mentionQuery(in: "compare @github and"), nil, "@: a space ends the mention")
    eq(AssistantChat.removingMention(from: "compare @gi"), "compare ", "@: the query leaves the draft when a tab is chosen")
    eq(AssistantChat.removingMention(from: "no mention"), "no mention", "@: a draft without a mention stays")
    let tabs: [(title: String, url: URL?)] = [("GitHub · Tacet", URL(string: "https://github.com/x")),
                                              ("Città di Roma", URL(string: "https://www.comune.roma.it")),
                                              ("News", URL(string: "https://bbc.co.uk/news"))]
    eq(AssistantChat.mentionMatches(tabs, query: ""), [0, 1, 2], "@: every tab with nothing typed")
    eq(AssistantChat.mentionMatches(tabs, query: "git"), [0], "@: matches the title, ignoring case")
    eq(AssistantChat.mentionMatches(tabs, query: "citta"), [1], "@: ignores accents")
    eq(AssistantChat.mentionMatches(tabs, query: "bbc"), [2], "@: matches the address")
    eq(AssistantChat.mentionMatches(tabs, query: "zzz"), [], "@: nothing matches")
    var ids: [UUID] = []
    for _ in 0..<7 { ids = AssistantChat.adding(UUID(), to: ids) }
    eq(ids.count, AssistantChat.maxMentionedTabs, "@: at most five tabs go with one message")
    eq(AssistantChat.adding(ids[0], to: Array(ids.prefix(2))).count, 2, "@: a tab isn't attached twice")
    eq(AssistantChat.mentionLimit(tabs: 1, pageChars: 60_000), 60_000, "@: one tab may send a whole page")
    eq(AssistantChat.mentionLimit(tabs: 3, pageChars: 60_000), 40_000, "@: several tabs share two pages' worth")
    check(AssistantChat.mentionLimit(tabs: 5, pageChars: 60_000) * 5 <= 120_000, "@: five tabs stay within two pages")
    eq(AssistantChat.mentionLimit(tabs: 5, pageChars: 1_000), 500, "@: a small model still gets the start of each tab")

    eq(Settings.smallModel(chosen: nil, main: "claude-opus-5-5"), "claude-opus-5-5", "small jobs: the default model when none is chosen")
    eq(Settings.smallModel(chosen: "  ", main: "gpt-5"), "gpt-5", "small jobs: a blank choice is none")
    eq(Settings.smallModel(chosen: "claude-haiku-5-5", main: "claude-opus-5-5"), "claude-haiku-5-5", "small jobs: the chosen model")
    eq(AssistantChat.cleanTitle("\"Il web di Tim Berners-Lee.\"\nAltro"), "Il web di Tim Berners-Lee", "small jobs: a title without quotes, full stop or second line")
    eq(AssistantChat.cleanTitle("  “ ” "), nil, "small jobs: an empty title is dropped")

    let anthropic = AIClient.Usage.anthropic(["input_tokens": 10, "cache_read_input_tokens": 2000, "cache_creation_input_tokens": 50, "output_tokens": 42])
    eq(anthropic, AIClient.Usage(input: 2060, output: 42, cached: 2000, cacheWrite: 50), "tokens (Anthropic): cache reads and writes count as input")
    eq(AIClient.Usage.anthropic(["service_tier": "standard"]), nil, "tokens (Anthropic): no counts, no usage")
    let openAI = AIClient.Usage.openAI(["prompt_tokens": 120, "completion_tokens": 7, "prompt_tokens_details": ["cached_tokens": 100]])
    eq(openAI, AIClient.Usage(input: 120, output: 7, cached: 100), "tokens (OpenAI): cached tokens are part of the input")
    eq(AIClient.Usage.openAI(["prompt_tokens": 30, "completion_tokens": 3, "prompt_cache_hit_tokens": 20])?.cached, 20, "tokens (DeepSeek): its cache hits")
    eq(AIClient.Usage.openAI([:]), nil, "tokens (OpenAI): no counts, no usage")
    eq(((anthropic ?? .init()) + (anthropic ?? .init())).output, 84, "tokens: an answer's requests add up")
    eq(AIClient.Usage(input: 1234, output: 5).summary(locale: Locale(identifier: "en_US")), "1,234 in · 5 out", "tokens: no cache, not shown")
    eq(AIClient.Usage(input: 1234, output: 5, cached: 900).summary(locale: Locale(identifier: "en_US")), "1,234 in · 5 out · 900 cached", "tokens: the summary")
    check(AIClient.reportsStreamUsage(.openAI) && !AIClient.reportsStreamUsage(.custom) && !AIClient.reportsStreamUsage(.ollama),
          "tokens: stream_options only to providers known to take it")
}

do {
    let server = fakeServer(reply: sse([
        #"{"type":"message_start","message":{"id":"m","type":"message","role":"assistant","content":[],"usage":{"input_tokens":12,"cache_read_input_tokens":3000,"cache_creation_input_tokens":40,"output_tokens":1}}}"#,
        #"{"type":"content_block_start","index":0,"content_block":{"type":"text","text":""}}"#,
        #"{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"Sì."}}"#,
        #"{"type":"content_block_stop","index":0}"#,
        #"{"type":"message_delta","delta":{"stop_reason":"end_turn"},"usage":{"output_tokens":25}}"#,
        #"{"type":"message_stop"}"#,
    ]))
    var answer: AIClient.Result?
    var failure: String?
    Task { @MainActor in
        do {
            answer = try await AIClient.stream(provider: .anthropic, base: "http://127.0.0.1:\(server.port)/v1", key: "test",
                                               model: "claude-haiku-5-5", transcript: [["role": "user", "content": "ok?"]],
                                               tools: false, web: false, control: false,
                                               onText: { _ in }, onServerTool: { _ in })
        } catch { failure = error.localizedDescription }
    }
    let deadline = Date().addingTimeInterval(10)
    while answer == nil && failure == nil && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
    check(failure == nil, "tokens (Anthropic stream): the request goes through", failure ?? "")
    eq(answer?.usage, AIClient.Usage(input: 3052, output: 25, cached: 3000, cacheWrite: 40), "tokens (Anthropic stream): read from the start and the end")
}

do {
    let server = fakeServer(reply: sse([
        #"{"choices":[{"index":0,"delta":{"role":"assistant","content":"Ciao"}}],"usage":null}"#,
        #"{"choices":[{"index":0,"delta":{},"finish_reason":"stop"}],"usage":null}"#,
        #"{"choices":[],"usage":{"prompt_tokens":200,"completion_tokens":9,"prompt_tokens_details":{"cached_tokens":128}}}"#,
        "[DONE]",
    ]))
    var answer: AIClient.Result?
    var failure: String?
    Task { @MainActor in
        do {
            answer = try await AIClient.stream(provider: .openAI, base: "http://127.0.0.1:\(server.port)/v1", key: "test",
                                               model: "gpt-5-mini", transcript: [["role": "user", "content": "ciao"]],
                                               tools: false, web: false, control: false,
                                               onText: { _ in }, onServerTool: { _ in })
        } catch { failure = error.localizedDescription }
    }
    let deadline = Date().addingTimeInterval(10)
    while answer == nil && failure == nil && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
    check(failure == nil, "tokens (OpenAI stream): the request goes through", failure ?? "")
    eq(answer?.usage, AIClient.Usage(input: 200, output: 9, cached: 128), "tokens (OpenAI stream): read from the last chunk")
    let sent = server.body().flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
    eq((sent["stream_options"] as? [String: Any])?["include_usage"] as? Bool, true, "tokens (OpenAI stream): the counts are asked for")
}

do {
    let server = fakeServer(reply: sse([
        #"{"choices":[{"index":0,"delta":{"role":"assistant","content":"Ciao"}}]}"#,
        #"{"choices":[{"index":0,"delta":{},"finish_reason":"stop"}]}"#,
        "[DONE]",
    ]))
    var answer: AIClient.Result?
    var failure: String?
    Task { @MainActor in
        do {
            answer = try await AIClient.stream(provider: .custom, base: "http://127.0.0.1:\(server.port)/v1", key: nil,
                                               model: "llama", transcript: [["role": "user", "content": "ciao"]],
                                               tools: false, web: false, control: false,
                                               onText: { _ in }, onServerTool: { _ in })
        } catch { failure = error.localizedDescription }
    }
    let deadline = Date().addingTimeInterval(10)
    while answer == nil && failure == nil && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
    check(failure == nil, "tokens (other servers): the request goes through", failure ?? "")
    check(answer != nil && answer?.usage == nil, "tokens (other servers): no counts, nothing shown")
    let sent = server.body().flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
    check(sent["stream_options"] == nil, "tokens (other servers): stream_options isn't sent")
}

// MARK: The assistant reads PDFs and pages built by JavaScript

do {
    /// A PDF made here, one line of text per page (none when `lines` is empty for that page).
    func makePDF(_ lines: [String]) -> Data {
        let data = NSMutableData()
        var box = CGRect(x: 0, y: 0, width: 400, height: 300)
        let ctx = CGContext(consumer: CGDataConsumer(data: data as CFMutableData)!, mediaBox: &box, nil)!
        for line in lines {
            ctx.beginPDFPage(nil)
            if !line.isEmpty {
                let attr = NSAttributedString(string: line, attributes: [.font: NSFont.systemFont(ofSize: 14)])
                ctx.textPosition = CGPoint(x: 20, y: 150)
                CTLineDraw(CTLineCreateWithAttributedString(attr), ctx)
            }
            ctx.endPDFPage()
        }
        ctx.closePDF()
        return data as Data
    }
    let url = URL(string: "https://example.com/report.pdf")!
    let pdf = makePDF(["First page about apples", "Second page about pears", "Third page about plums"])
    let page = WebTools.pdfPage(pdf, url: url)
    eq(page?.pageCount, 3, "pdf: page count")
    eq(page?.pageStarts.count, 3, "pdf: every page is read")
    check(page?.kind == .pdf, "pdf: marked as a PDF")
    check(page.map { $0.text.contains("[Page 2]") && $0.text.contains("pears") && $0.text.contains("plums") } ?? false,
          "pdf: each page's text, with its number", page?.text ?? "nil")
    eq(page?.title, "report.pdf", "pdf: without a title, its file name")
    if let page {
        let whole = WebTools.format(page)
        check(whole.contains("[PDF, 3 pages.]") && !whole.contains("cut"), "pdf: a whole PDF says how many pages", whole)
        let cut = WebTools.pdfText(page, limit: page.pageStarts[1] + 5)
        check(cut.contains("only up to page 2 of 3") && !cut.contains("plums"), "pdf: a cut PDF says which page it reaches", cut)
        check(WebTools.pdfText(page, limit: 10).contains("only up to page 1 of 3"), "pdf: cut in the first page")
        eq(AssistantChat.readOutcome(page), "PDF · 3 pages", "pdf: the read step says how many pages")
    }
    let scanned = WebTools.pdfPage(makePDF(["", ""]), url: url)
    check(scanned.map { WebTools.format($0).contains("no text to read") } ?? false, "pdf: scans without text say so")
    eq(WebTools.pdfPage(Data("not a pdf".utf8), url: url)?.pageCount, nil, "pdf: a damaged file can't be read")
    check(WebTools.isPDF(type: "application/pdf", url: URL(string: "https://example.com/get?id=1")!), "pdf: by its type")
    check(WebTools.isPDF(type: "application/octet-stream", url: url), "pdf: by its name when the type says nothing")
    check(WebTools.isPDF(type: "", url: URL(string: "https://example.com/file")!, data: pdf), "pdf: by its first bytes")
    check(!WebTools.isPDF(type: "text/html", url: url), "pdf: a web page named .pdf is a web page")

    let script = "<script src=\"app.js\"></script>"
    check(WebTools.needsRendering(text: "Loading…", html: "<html><body>\(script)<div id=app></div></body></html>"),
          "rendering: almost no text with scripts")
    check(!WebTools.needsRendering(text: "Short note.", html: "<html><body><p>Short note.</p></body></html>"),
          "rendering: a short page without scripts is as it is")
    let middling = String(repeating: "Some words in a page. ", count: 50)
    check(WebTools.needsRendering(text: middling, html: "<body>\(script)<noscript>Please enable JavaScript to continue.</noscript></body>"),
          "rendering: a page asking for JavaScript")
    check(WebTools.needsRendering(text: middling + " Per favore attiva JavaScript.", html: "<body>\(script)</body>"),
          "rendering: asking for JavaScript in Italian")
    check(!WebTools.needsRendering(text: middling, html: "<body>\(script)</body>"), "rendering: enough text, no notice")
    let article = String(repeating: "A long article about how to enable JavaScript in browsers. ", count: 80)
    check(!WebTools.needsRendering(text: article, html: "<body>\(script)</body>"), "rendering: a long article that mentions JavaScript")

    var rendered: WebTools.Page?, renderDone = false
    let built = String(repeating: "Text the own script writes. ", count: 30)
    Task { @MainActor in
        rendered = await PageRenderer.render(html: "<html><head><title>App</title></head><body><div id=app></div><script>document.getElementById('app').innerText = '\(built)'</script></body></html>",
                                             baseURL: URL(string: "https://example.com/app")!)
        renderDone = true
    }
    let renderDeadline = Date().addingTimeInterval(20)
    while !renderDone && Date() < renderDeadline { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
    check(rendered?.kind == .rendered && rendered?.text.contains("own script writes") == true,
          "rendering: reads the text a page's script wrote", rendered?.text ?? "nil")
    eq(rendered.flatMap(AssistantChat.readOutcome), "Read with rendering", "rendering: the read step says so")
    var refused: WebTools.Page? = WebTools.Page(url: url, title: "", text: "", links: []), refusedDone = false
    Task { @MainActor in
        refused = await PageRenderer.render(html: "<p>x</p>", baseURL: URL(string: "http://192.168.1.1/")!)
        refusedDone = true
    }
    while !refusedDone { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
    check(refused == nil, "rendering: private addresses aren't opened")
}

// MARK: Personal instructions and memory

do {
    let s = Settings.shared
    let saved = (s.aiAboutMe, s.aiAnswerStyle, s.aiInstructionsInPrivate, s.aiMemory)
    let realMemory = AssistantMemory.shared
    let memFile = FileManager.default.temporaryDirectory.appendingPathComponent("tacet-memory-\(UUID().uuidString).json")
    let memory = AssistantMemory(file: StoredFile(at: memFile))
    AssistantMemory.shared = memory
    defer {
        (s.aiAboutMe, s.aiAnswerStyle, s.aiInstructionsInPrivate, s.aiMemory) = saved
        AssistantMemory.shared = realMemory
        try? FileManager.default.removeItem(at: memFile)
    }
    s.aiAboutMe = "I teach maths in Turin."; s.aiAnswerStyle = "Answer in Italian."
    s.aiInstructionsInPrivate = false; s.aiMemory = false

    let normal = AssistantPrompt.system(web: true, control: false)
    check(normal.contains("<about_user>\nI teach maths in Turin.\n</about_user>") && normal.contains("<answer_style>\nAnswer in Italian."),
          "instructions: both go in the prompt")
    check(normal.contains("never over the rules about pages"), "instructions: labelled as preferences, below the safety rules")
    let priv = AssistantPrompt.system(web: true, control: false, privateWindow: true)
    check(!priv.contains("Turin") && !priv.contains("about_user"), "instructions: left out in private windows by default")
    check(AssistantPrompt.system(web: true, control: false, quick: true).contains("Turin"), "instructions: the quick prompt has them too")
    check(!AssistantPrompt.system(web: true, control: false, quick: true, privateWindow: true).contains("Turin"), "instructions: not in a private quick prompt")
    check(AppleModel.instructions(control: false).contains("Turin"), "instructions: the Apple model has them")
    check(!AppleModel.instructions(control: false, privateWindow: true).contains("Turin"), "instructions: not for the Apple model in private windows")
    s.aiInstructionsInPrivate = true
    check(AssistantPrompt.system(web: true, control: false, privateWindow: true).contains("Turin"), "instructions: in private windows when allowed")
    s.aiInstructionsInPrivate = false
    s.aiAboutMe = ""; s.aiAnswerStyle = ""
    check(!AssistantPrompt.system(web: true, control: false).contains("personal instructions"), "instructions: nothing added when empty")
    let long = String(repeating: "a", count: 5_000)
    let longPart = AssistantPersonal.part(about: long, style: "", memories: nil)
    check(longPart.count < AssistantPersonal.instructionLimit + 400, "instructions: a long text is cut", "\(longPart.count)")
    check(AssistantPersonal.part(about: long, style: "", memories: nil, compact: true).count < AssistantPersonal.compactInstructionLimit + 400,
          "instructions: cut much shorter for the Apple model")

    // The store
    let a = memory.add("  Prefers   trains\nto planes. ")
    eq(a?.text, "Prefers trains to planes.", "memory: saved on one line, trimmed")
    check(memory.add("prefers trains to planes.") == nil, "memory: the same fact isn't saved twice")
    check(memory.add("   ") == nil, "memory: empty text isn't saved")
    let b = memory.add("Has a dog called Olivia.")
    eq(memory.items.map(\.text), ["Has a dog called Olivia.", "Prefers trains to planes."], "memory: newest first")
    eq(AssistantMemory(file: StoredFile(at: memFile)).items.count, 2, "memory: written to its file at once")
    memory.update(a!.id, text: "Prefers trains.")
    eq(memory.items.last?.text, "Prefers trains.", "memory: edited")
    memory.update(b!.id, text: " ")
    eq(memory.items.map(\.text), ["Prefers trains."], "memory: emptied while editing, it's deleted")
    memory.delete(a!.id)
    check(memory.items.isEmpty, "memory: deleted")
    eq(AssistantMemory(file: StoredFile(at: memFile)).items.count, 0, "memory: deletions reach the file")
    eq(AssistantMemory.clean(String(repeating: "x", count: 1_000)).count, AssistantMemory.textLimit, "memory: a fact is cut to its limit")

    // Saving needs the user's yes
    func propose(_ fact: String, allowed: Bool, answer: Bool) -> (AssistantMemory.Proposal, Bool) {
        var out: AssistantMemory.Proposal?
        var asked = false
        Task { @MainActor in out = await memory.propose(fact, allowed: allowed) { _ in asked = true; return answer } }
        while out == nil { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
        return (out!, asked)
    }
    let off = propose("Lives in Turin.", allowed: false, answer: true)
    check(off == (.off, false) && memory.items.isEmpty, "memory: nothing asked or saved when memory is off")
    let no = propose("Lives in Turin.", allowed: true, answer: false)
    check(no == (.declined, true) && memory.items.isEmpty, "memory: the user is asked, and no means nothing is saved")
    let yes = propose("Lives in Turin.", allowed: true, answer: true)
    check(yes == (.saved, true) && memory.items.map(\.text) == ["Lives in Turin."], "memory: saved only after the user agrees")
    let again = propose("lives in turin.", allowed: true, answer: true)
    check(again == (.already, false), "memory: an already remembered fact isn't asked again")
    check(propose(" ", allowed: true, answer: true) == (.empty, false), "memory: an empty fact isn't asked")

    // Memory in the prompt and the tool
    check(!AssistantPrompt.system(web: true, control: false).contains("Lives in Turin"), "memory: off by default, so not in the prompt")
    check(!AssistantPrompt.clientTools(provider: .openAI, web: true, control: false).contains { $0.name == "remember" }, "memory: no remember tool while off")
    s.aiMemory = true
    let withMemory = AssistantPrompt.system(web: true, control: false)
    check(withMemory.contains("<memories>\n- Lives in Turin.\n</memories>") && withMemory.contains("remember:"), "memory: in the prompt when on, with the tool explained")
    check(AssistantPrompt.clientTools(provider: .anthropic, web: true, control: false).contains { $0.name == "remember" }, "memory: remember tool when on")
    check(!AssistantPrompt.clientTools(provider: .openAI, web: true, control: false, privateWindow: true).contains { $0.name == "remember" }, "memory: no remember tool in private windows")
    let privMemory = AssistantPrompt.system(web: true, control: false, privateWindow: true)
    check(!privMemory.contains("Lives in Turin") && !privMemory.contains("remember:"), "memory: never in a private window's prompt")
    s.aiInstructionsInPrivate = true
    check(!AssistantPrompt.system(web: true, control: false, privateWindow: true).contains("Lives in Turin"), "memory: still out of private windows when instructions are allowed there")
    let quickMemory = AssistantPrompt.system(web: true, control: false, quick: true)
    check(quickMemory.contains("Lives in Turin") && !quickMemory.contains("remember:") && !quickMemory.contains("remember saves"),
          "memory: the quick prompt knows the memories but has no remember tool")
    check(AppleModel.tools(web: false, memory: true).contains { $0.name == "remember" } && AppleModel.instructions(control: false).contains("Lives in Turin"),
          "memory: the Apple model gets the tool and the memories")
    check(!AppleModel.instructions(control: false, privateWindow: true).contains("Lives in Turin"), "memory: not for the Apple model in private windows")
    var lines: [String] = []
    for i in 0..<100 { lines.append("Fact number \(i) about the user, long enough to take some room.") }
    check(AssistantPersonal.memoryList(lines, limit: AssistantPersonal.memoryPromptLimit).count <= AssistantPersonal.memoryPromptLimit, "memory: the list stays within its limit")
    check(AssistantPersonal.memoryList(lines, limit: 200).hasPrefix("- Fact number 0 "), "memory: the newest ones are kept first")

    let tool = AssistantPersonal.rememberTool
    let schema = AssistantPrompt.schema(tool)
    check(JSONSerialization.isValidJSONObject(schema), "remember: valid schema")
    eq(schema["required"] as? [String], ["fact"], "remember: needs the fact")
    eq(((schema["properties"] as? [String: Any])?["fact"] as? [String: Any])?["type"] as? String, "string", "remember: the fact is a string")
    check(tool.description.contains("decides whether to save"), "remember: the model knows the user confirms")
}

// MARK: Deep research run by the code, with a made-up model and web

do {
    func wait<T>(_ work: @escaping @MainActor () async -> T) -> T {
        var out: T?
        let sem = DispatchSemaphore(value: 0)
        Task { @MainActor in out = await work(); sem.signal() }
        while sem.wait(timeout: .now()) == .timedOut { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
        return out!
    }

    // The plan: kept to the limit, every sub-question searched, a plan that can't be read falls back to the question.
    let plan = DeepResearch.parsePlan("""
    Sure! ```json
    {"subquestions":[{"question":"What is A?","searches":["a facts","a official"]},{"question":"What is B?","searches":[]},
    {"question":"C?","searches":["c1","c2","c3"]},{"question":"D?","searches":["d"]}]}
    ```
    """, question: "Q", limit: 3)
    eq(plan.count, 3, "research: plan kept to the depth's limit")
    check(plan.allSatisfy { !$0.searches.isEmpty }, "research: no sub-question without a search")
    eq(plan[1].searches, ["What is B?"], "research: a sub-question without searches is searched by its words")
    eq(plan[2].searches.count, 2, "research: at most two searches per sub-question")
    eq(DeepResearch.parsePlan("I can't do that", question: "What is X?", limit: 5), [DeepResearch.SubQuestion(question: "What is X?", searches: ["What is X?"])],
       "research: an invalid plan falls back to the question itself")

    // Choosing: valid picks only, once each, within the limit; without picks, one page per site first.
    eq(DeepResearch.parsePicks(#"{"pick":[3,3,0,99,"2",1]}"#, count: 5, limit: 3), [2, 1, 0], "research: picks are valid, once each, within the limit")
    let r = { (t: String, u: String) in WebTools.SearchResult(title: t, url: u, snippet: "") }
    let found: [(sub: Int, results: [WebTools.SearchResult])] = [
        (0, [r("a1", "https://a.com/1"), r("a2", "https://a.com/2"), r("b1", "https://www.b.org/1")]),
        (1, [r("c1", "https://c.net/1"), r("a1 again", "https://a.com/1#top")]),
    ]
    let fallback = DeepResearch.fallbackChoice(found, limit: 3)
    eq(fallback.map(\.url.absoluteString), ["https://a.com/1", "https://c.net/1", "https://www.b.org/1"], "research: fallback takes one page per site and every sub-question first")
    eq(DeepResearch.candidates(found).count, 4, "research: the same page found twice is a candidate once")

    // Notes: a quote that isn't in the page is dropped.
    let page = "The bridge opened in 1937. It is 2,737 metres long, according to the city’s records."
    let notes = DeepResearch.parseNotes(#"{"notes":[{"sub":1,"fact":"Opened 1937","quote":"The bridge opened in 1937."},{"sub":2,"fact":"Length","quote":"it is 2,737   metres long, according to the city's records"},{"sub":1,"fact":"Made up","quote":"The bridge was painted blue in 1990"}]}"#, page: page, subs: 2)
    eq(notes.map(\.fact), ["Opened 1937", "Length"], "research: notes whose quote isn't in the page are dropped")
    eq(notes.map(\.sub), [0, 1], "research: notes keep their sub-question")

    // Checking: confirmed only with two different sites, decided by the code.
    let n = { (id: Int, u: String) in DeepResearch.Note(id: id, sub: 0, fact: "f\(id)", quote: "q", url: URL(string: u)!, title: "") }
    let all = [n(1, "https://a.com/x"), n(2, "https://www.a.com/y"), n(3, "https://b.com/z")]
    let (claims, conflicts) = DeepResearch.parseCheck(#"{"claims":[{"claim":"same site twice","notes":[1,2]},{"claim":"two sites","notes":[1,3,42]}],"conflicts":[{"about":"x","notes":[2,3]}]}"#, notes: all)
    eq(claims.map(\.confirmed), [false, true], "research: a claim is confirmed only by two different sites")
    eq(claims[1].notes, [1, 3], "research: note numbers that don't exist are dropped")
    eq(conflicts.count, 1, "research: conflicts kept")

    // A whole research with a made-up web and model.
    var prompts: [String] = []
    var written = ""
    let pages = (1...12).map { i in (URL(string: "https://site\(i).com/p")!, "Page \(i) says the answer is \(i * 10). Other text \(String(repeating: "x", count: 3_000)).") }
    var running: Task<DeepResearch.Report, Never>?
    func backend(cancelAfterReads: Int? = nil) -> DeepResearch.Backend {
        var reads = 0
        return DeepResearch.Backend(
            search: { q in (pages.map { WebTools.SearchResult(title: "T", url: $0.0.absoluteString, snippet: q) }, "Test") },
            read: { url, limit in
                reads += 1
                if let c = cancelAfterReads, reads > c { running?.cancel() }
                let text = pages.first { $0.0 == url }!.1
                return ("Title", String(text.prefix(limit)))
            },
            ask: { system, prompt in
                prompts.append(prompt)
                if system == DeepResearch.plannerSystem { return #"{"subquestions":[{"question":"S1","searches":["s1"]},{"question":"S2","searches":["s2"]}]}"# }
                if system == DeepResearch.chooserSystem { return #"{"pick":[1,2,3,4,5,6,7,8,9,10,11,12]}"# }
                if system == DeepResearch.noteSystem, let r = prompt.range(of: "Page "), let num = Int(prompt[r.upperBound...].prefix { $0.isNumber }) {
                    return #"{"notes":[{"sub":1,"fact":"answer \#(num * 10)","quote":"Page \#(num) says the answer is \#(num * 10)."}]}"#
                }
                if system == DeepResearch.checkerSystem { return #"{"claims":[{"claim":"answer","notes":[1,2]}]}"# }
                return "{}"
            },
            write: { system, prompt, onText in written = prompt; onText("Report"); return "Report" })
    }
    var events: [DeepResearch.Event] = []
    let report = wait {
        await DeepResearch(question: "Q?", depth: .standard, pageChars: 2_000, backend: backend()) { events.append($0) }.run { _ in }
    }
    eq(report.sources.count, ResearchDepth.standard.sources, "research: reads at most the depth's number of sources")
    eq(report.notes.count, 8, "research: one note per page read")
    check(!report.stopped && report.text == "Report", "research: a whole run writes the report")
    check(written.contains("answer 10") && written.contains("Confirmed by at least two different sites"), "research: the writer gets the notes and what's confirmed")
    check(!written.contains(String(repeating: "x", count: 200)), "research: the writer never gets whole pages, only notes")
    check(prompts.filter { $0.contains("<page>") }.allSatisfy { $0.count < 2_000 + 1_000 }, "research: a page goes to the model in pieces sized for it")
    let stages = events.compactMap { if case .stage(let s, _) = $0 { return s } else { return nil } }
    eq(stages, [.planning, .searching, .reading, .verifying, .writing], "research: the timeline shows each stage in order")
    check(events.contains { if case .progress(_, let t) = $0 { return t.contains("8") } else { return false } }, "research: progress counts the pages read")

    // Stop: the task running the research is cancelled from outside, as the chat's Stop does.
    let stopped = wait { () async -> DeepResearch.Report in
        let t = Task { @MainActor in
            await DeepResearch(question: "Q?", depth: .standard, pageChars: 2_000, backend: backend(cancelAfterReads: 5)).run { _ in }
        }
        running = t
        return await t.value
    }
    check(stopped.stopped, "research: Stop in the middle returns what was found, marked as stopped")
    check(stopped.text.contains(L("Research stopped. Here is what it had found so far.")), "research: the stopped report says so")
    check(stopped.notes.count >= 1 && stopped.notes.count < 8, "research: notes found before Stop are kept", "\(stopped.notes.count)")

    let quick = wait { await DeepResearch(question: "Q?", depth: .quick, pageChars: 2_000, backend: backend()).run { _ in } }
    eq(quick.sources.count, 4, "research: a quick research reads about four sources")
    eq(DeepResearch.pieces(String(repeating: "word. ", count: 1_000), size: 1_500, max: 2).count, 2, "research: pieces never go past their number")
}

// MARK: Research report export

do {
    let report = """
    Prices rose 3% in 2025 ([Istat](https://www.istat.it/a_b?x=1&y=2)).

    ### What changed
    - Energy, **up** the most
      - Gas in _winter_
    - Food, see `a<b>`
    1. First
    2. Second

    ### What's uncertain
    <script>alert(1)</script> and [bad](javascript:alert(1)).
    """
    let sources: [(url: URL, title: String)] = [
        (URL(string: "https://www.istat.it/a_b?x=1&y=2")!, "Istat"),
        (URL(string: "https://example.com/page")!, "Example"),
        (URL(string: "https://example.com/page/#top")!, "Example again"),
        (URL(string: "https://www.istat.it/a_b?x=1&y=2")!, "Istat"),
        (URL(string: "https://news.example.org/x")!, ""),
    ]
    let date = Date(timeIntervalSince1970: 1_780_000_000)
    let md = ResearchExport.markdown(report: report, question: "How much did prices rise in Italy?", sources: sources, date: date)
    check(md.hasPrefix("# How much did prices rise in Italy?\n"), "report export: the question is the title when the report has no heading of its own", md)
    eq(ResearchExport.title(report: "## Inflation in Italy\n\nText", question: "q"), "Inflation in Italy", "report export: the first heading is the title")
    check(!ResearchExport.markdown(report: "# Own title\n\nText", question: "q", sources: [], date: date).contains("# q"), "report export: no second title")
    let sourcesPart = md.components(separatedBy: "## Sources").last ?? ""
    check(md.components(separatedBy: "## Sources").count == 2, "report export: one Sources section")
    check(md.range(of: "## Sources")!.lowerBound > md.range(of: "What's uncertain")!.lowerBound, "report export: sources after the report")
    eq(sourcesPart.components(separatedBy: "istat.it").count - 1, 1, "report export: a source listed once")
    eq(sourcesPart.components(separatedBy: "example.com/page").count - 1, 1, "report export: the same page with a fragment or slash listed once")
    check(sourcesPart.contains("- [Istat](https://www.istat.it/a_b?x=1&y=2)\n") && sourcesPart.contains("- [news.example.org](https://news.example.org/x)\n"),
          "report export: title and address of each source, the host when untitled", sourcesPart)

    let html = ResearchExport.html(report: report, question: "Prices & <wages>?", sources: sources, date: date)
    check(html.contains("<h1>Prices &amp; &lt;wages&gt;?</h1>") && html.contains("<title>Prices &amp; &lt;wages&gt;?</title>"), "report pdf: title escaped")
    check(html.contains("<h3>What changed</h3>") && html.contains("<h3>What's uncertain</h3>"), "report pdf: headings")
    check(html.contains("<a href=\"https://www.istat.it/a_b?x=1&amp;y=2\">Istat</a>"), "report pdf: link with its address escaped, underscore kept", html)
    check(html.contains("<ul>\n<li>Energy, <strong>up</strong> the most<ul>\n<li>Gas in <em>winter</em></li></ul></li>\n<li>Food, see <code>a&lt;b&gt;</code>"),
          "report pdf: nested bullets, bold, italics and code", html)
    check(html.contains("<ol>\n<li value=\"1\">First</li>\n<li value=\"2\">Second</li></ol>"), "report pdf: numbered list", html)
    check(!html.contains("<script>") && html.contains("&lt;script&gt;"), "report pdf: HTML in the report is escaped")
    check(!html.contains("javascript:") && html.contains("and bad."), "report pdf: only web links are links", html)
    check(html.contains("<section class=\"sources\"><h2>Sources</h2>") && html.components(separatedBy: "<span class=\"url\">").count - 1 == 3,
          "report pdf: sources once each, with their address written out")
    eq(ResearchExport.inline("a_b_c and snake_case_name"), "a_b_c and snake_case_name", "report pdf: underscores inside words stay")
    eq(ResearchExport.inline("[Wiki](https://en.wikipedia.org/wiki/Rome_(city))"), "<a href=\"https://en.wikipedia.org/wiki/Rome_(city)\">Wiki</a>",
       "report pdf: an address with parentheses")

    // A long report, printed for real in a hidden web view, fills more than one page.
    var long = "# A long report\n\n"
    for i in 1...40 { long += "### Part \(i)\n\nSome findings about part \(i), with a [source](https://example.com/\(i)) and enough words to fill a line or two of the page.\n\n- One point\n- Another point\n\n" }
    var pdfData: Data?, pdfDone = false
    Task { @MainActor in
        ResearchExport.pdf(html: ResearchExport.html(report: long, question: nil, sources: sources, date: date), paper: NSSize(width: 595.28, height: 841.89)) {
            pdfData = $0; pdfDone = true
        }
    }
    let pdfDeadline = Date().addingTimeInterval(30)
    while !pdfDone && Date() < pdfDeadline { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
    let pages = pdfData.flatMap { CGDataProvider(data: $0 as CFData) }.flatMap { CGPDFDocument($0) }
    check(pdfData.map { $0.starts(with: Array("%PDF".utf8)) } ?? false, "report pdf: a PDF is written")
    check((pages?.numberOfPages ?? 0) > 1, "report pdf: a long report is paginated", "\(pages?.numberOfPages ?? 0) pages")
    if let box = pages?.page(at: 1)?.getBoxRect(.mediaBox) { check(abs(box.width - 595.28) < 1 && abs(box.height - 841.89) < 1, "report pdf: A4 pages", "\(box)") }
}

// MARK: Diagnostics

do {
    let sites = [
        ("https://www.bbc.co.uk/news/article-123?id=42&token=secret#top", "bbc.co.uk"),
        ("https://user:pass@mail.example.com:8443/inbox/private.pdf?q=me", "example.com"),
        ("http://192.168.1.10/admin?x=1", "192.168.1.10"),
        ("file:///Users/someone/Documents/taxes.pdf", "file"),
        ("data:text/html,<b>secret</b>", "data"),
    ]
    for (s, want) in sites {
        let got = Diagnostics.site(URL(string: s))
        eq(got, want, "diagnostics: site of \(s)")
        check(!got.contains("/") && !got.contains("?") && !got.contains("secret") && !got.contains("pass"),
              "diagnostics: site has no path, query or credentials", got)
    }
    eq(Diagnostics.site(nil), "-", "diagnostics: no address")
    let pdf = Diagnostics.file("Bank statement March.pdf", size: 1_200_000)
    check(pdf.hasPrefix("pdf ") && !pdf.contains("Bank"), "diagnostics: a file shows only its type and size", pdf)
    eq(Diagnostics.file("notes.my-private-project"), "other", "diagnostics: an odd extension is hidden")
    eq(Diagnostics.code(NSError(domain: NSURLErrorDomain, code: -1001, userInfo: [NSURLErrorFailingURLStringErrorKey: "https://x.com/a?b"])),
       "NSURLErrorDomain -1001", "diagnostics: errors only by domain and code")

    let ring = LogRing(capacity: 5)
    for i in 1...12 { ring.append("event \(i)") }
    eq(ring.lines.count, 5, "diagnostics: the log keeps only its capacity")
    check(ring.lines.first?.hasSuffix("event 8") == true && ring.lines.last?.hasSuffix("event 12") == true,
          "diagnostics: the oldest lines go first", "\(ring.lines)")
    let one = LogRing(capacity: 300)
    one.append("one", at: Date(timeIntervalSince1970: 0))
    check(one.lines.count == 1 && one.lines[0].range(of: #"^\d{4}-\d\d-\d\d \d\d:\d\d:00\.000 one$"#, options: .regularExpression) != nil,
          "diagnostics: lines carry their time", "\(one.lines)")
    eq(Diagnostics.recent.capacity, 300, "diagnostics: the app keeps 300 lines")

    let report = Diagnostics.report(["2026-01-01 00:00:00.000 [downloads] started example.com"])
    let head = report.components(separatedBy: "\n")
    check(head.count >= 4 && head[0] == "Tacet \(UpdateChecker.currentVersion)" && head[1].hasPrefix("macOS ")
          && head[2].hasPrefix("Architecture: "), "diagnostics: the log starts with version, macOS and architecture", report)
    check(report.hasSuffix("[downloads] started example.com"), "diagnostics: the events follow the header", report)
    Diagnostics.log(.downloads, "test event", site: URL(string: "https://www.example.com/secret/path?q=1"))
    check(Diagnostics.recent.lines.last?.hasSuffix("[downloads] test event example.com") == true,
          "diagnostics: events go to the in-memory log", Diagnostics.recent.lines.last ?? "nil")
}

// MARK: "Site not working?" turns Shield off for now (a list of its own, so your allowlist isn't touched)

do {
    var trial = ShieldExceptions()
    check(trial.add("www.Example.com"), "shield trial: a site is added")
    check(!trial.add("example.com"), "shield trial: the same site isn't added twice")
    eq(trial.sites, ["example.com"], "shield trial: kept as the allowlist keeps it")
    check(trial.covers("example.com") && trial.covers("shop.example.com") && trial.covers("WWW.example.com"), "shield trial: off on the site and its subdomains")
    check(!trial.covers("notexample.com") && !trial.covers("example.org") && !trial.covers(nil), "shield trial: other sites keep Shield")
    let allowlist = ["news.site"]
    eq(trial.keep("shop.example.com", in: allowlist), ["example.com", "news.site"], "shield trial: Keep Off moves the site into the allowlist")
    check(!trial.covers("example.com") && trial.sites.isEmpty, "shield trial: kept sites leave the list for now")
    eq(trial.keep("other.com", in: allowlist), allowlist, "shield trial: Keep Off with nothing for now leaves the allowlist alone")
    trial.add("a.com"); trial.add("b.com")
    eq(trial.remove("www.a.com"), ["a.com"], "shield trial: Turn Shield Back On ends the exception")
    check(!trial.covers("a.com") && trial.covers("b.com"), "shield trial: only that site gets Shield back")
    eq(trial.remove("c.com"), [], "shield trial: nothing to end on another site")
    check(ShieldExceptions.covers(["example.com"], "x.example.com") && !ShieldExceptions.covers(["example.com"], "xexample.com"),
          "shield trial: the allowlist's own match")
}

// MARK: A proxy for each profile

do {
    eq(ProfileProxy(kind: .socks5, host: "proxy.example.com", port: 1080).isValid, true, "proxy: SOCKS5 host and port")
    eq(ProfileProxy(kind: .httpConnect, host: " 10.0.0.2 ", port: 65535).address, "10.0.0.2:65535", "proxy: host trimmed, top port")
    eq(ProfileProxy(kind: .socks5, host: "[::1]", port: 9050).address, "[::1]:9050", "proxy: IPv6 shown in brackets")
    eq(ProfileProxy(kind: .socks5, host: "proxy.example.com", port: 0).isValid, false, "proxy: port 0 is off")
    eq(ProfileProxy(kind: .socks5, host: "proxy.example.com", port: 65536).isValid, false, "proxy: port above 65535 is off")
    eq(ProfileProxy(kind: .socks5, host: "  ", port: 1080).isValid, false, "proxy: empty host is off")
    eq(ProfileProxy(kind: .socks5, host: "a b", port: 1080).isValid, false, "proxy: host with a space is off")
    eq(ProfileProxy(kind: .none, host: "proxy.example.com", port: 1080).address, nil, "proxy: kind none is off")
    eq(ProfileProxy(kind: .socks5, host: "proxy.example.com", port: 1080).configurations.count, 1, "proxy: one SOCKS5 configuration")
    eq(ProfileProxy(kind: .httpConnect, host: "proxy.example.com", port: 8080).configurations.count, 1, "proxy: one HTTP CONNECT configuration")
    eq(ProfileProxy(kind: .httpConnect, host: "", port: 8080).configurations.count, 0, "proxy: invalid means a direct connection")

    // Profiles saved before proxies existed still read, and so do kinds from a newer Tacet.
    let old = #"[{"id":"6F9619FF-8B86-D011-B42D-00C04FC964FF","name":"Work","color":2}]"#
    let profiles = try? JSONDecoder().decode([Profile].self, from: Data(old.utf8))
    eq(profiles?.first?.name, "Work", "proxy: old profile still reads")
    eq(profiles?.first?.proxy, nil, "proxy: old profile has no proxy")
    let newer = #"[{"id":"6F9619FF-8B86-D011-B42D-00C04FC964FF","name":"Work","color":2,"proxy":{"kind":"quic","host":"h","port":1}}]"#
    let read = try? JSONDecoder().decode([Profile].self, from: Data(newer.utf8))
    eq(read?.first?.proxy?.kind, ProfileProxy.Kind.none, "proxy: unknown kind reads as none")
    let saved = Profile(name: "Home", proxy: ProfileProxy(kind: .socks5, host: "127.0.0.1", port: 9050))
    let again = (try? JSONEncoder().encode([saved])).flatMap { try? JSONDecoder().decode([Profile].self, from: $0) }
    eq(again?.first?.proxy, saved.proxy, "proxy: saved and read back")

    // Private windows' stores never get a proxy.
    let privateStore = WKWebsiteDataStore.nonPersistent()
    check(!ProfileProxies.apply(saved.proxy, to: privateStore), "proxy: refused for a private store")
    eq(privateStore.proxyConfigurations.count, 0, "proxy: private store stays direct")
}

print("\(passed) passed, \(failures) failed")
exit(failures == 0 ? 0 : 1)
