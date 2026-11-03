// Tacet's logic tests. Run with: tools/test.sh
// They use only pure functions and temporary files: nothing touches your Tacet data.
import Foundation
import JavaScriptCore
import SQLite3
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
eq(Set(WhatsNew.pages(since: "1.7").map(\.version)), ["1.7.1"], "welcome after 1.7: the 1.7.1 pages")
eq(Set(WhatsNew.pages(since: "1.7.0.3").map(\.version)), ["1.7.1"], "welcome after 1.7.0.3: the 1.7.1 pages")
eq(Set(WhatsNew.pages(since: "1.6.5").map(\.version)), ["1.7", "1.7.1"], "welcome after 1.6.5: 1.7 and 1.7.1 pages")
eq(Set(WhatsNew.pages(since: "1.6.1").map(\.version)), ["1.6.2", "1.6.3", "1.6.4", "1.6.5", "1.7", "1.7.1"], "welcome after 1.6.1: every newer page")
eq(WhatsNew.pages(since: "1.6").count, WhatsNew.all.count, "welcome after 1.6: every page")
eq(WhatsNew.pages(since: "").count, WhatsNew.all.count, "welcome never seen: every page")
check(WhatsNew.pages(since: "1.7.1").isEmpty, "welcome already seen: nothing")

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
        let cutoff = now.addingTimeInterval(-2.5 * 3600)
        eq(hdb.search(["page"], before: cutoff, limit: 10).map(\.title), ["Page 3 100%", "Page 4 100%"], "history: older entries found on disk")
        eq(hdb.search(["site4", "100%"], before: cutoff, limit: 10).count, 1, "history: every word must match, % taken literally")
        eq(hdb.search(["page_"], before: now.addingTimeInterval(60), limit: 10).count, 5, "history: _ taken literally")
        eq(hdb.search(["xx%"], before: now.addingTimeInterval(60), limit: 10).count, 0, "history: % isn't a wildcard")
        eq(hdb.entry(for: URL(string: "https://site2.example/page_2")!)?.visits, 3, "history: an entry found by its address")
    } else {
        check(false, "history: temporary database opens")
    }
    try? FileManager.default.removeItem(at: url)
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
        ("bridge", Scripts.bridge), ("drafts", Scripts.drafts), ("highlights", Scripts.highlights), ("passkeys", Scripts.passkeys),
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
            .replacingOccurrences(of: "__TIP__", with: "\"\"")
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
                                               onText: { streamed += $0 }, onServerTool: { _, _ in })
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
                                          onText: { streamed += $0 }, onServerTool: { _, _ in })
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

print("\(passed) passed, \(failures) failed")
exit(failures == 0 ? 0 : 1)
