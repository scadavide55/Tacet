<div align="center">

<img src="docs/assets/icon.png" alt="Tacet icon" width="128" height="128">

# Tacet

*formerly Lumen*

**The quiet browser for your Mac.**

A minimal, fast and private macOS browser built on WebKit, with a native ad blocker you can turn off in one click.

[![Release](https://img.shields.io/github/v/release/scadavide55/Tacet?include_prereleases&label=release&style=flat-square&color=6e56cf)](https://github.com/scadavide55/Tacet/releases)
[![Downloads](https://img.shields.io/github/downloads/scadavide55/Tacet/total?style=flat-square&color=2ea44f)](https://github.com/scadavide55/Tacet/releases)
[![macOS](https://img.shields.io/badge/macOS-14%2B-000000?style=flat-square&logo=apple&logoColor=white)](#requirements)
[![Universal](https://img.shields.io/badge/Apple%20silicon%20%2B%20Intel-universal-555555?style=flat-square)](#requirements)
[![Swift](https://img.shields.io/badge/Swift-SwiftUI-F05138?style=flat-square&logo=swift&logoColor=white)](Sources)
[![WebKit](https://img.shields.io/badge/engine-WebKit-1f6feb?style=flat-square&logo=safari&logoColor=white)](https://webkit.org)
[![Website](https://img.shields.io/badge/website-online-0a7cff?style=flat-square)](https://scadavide55.github.io/Tacet/)

[**Download**](https://github.com/scadavide55/Tacet/releases) · [**Website**](https://scadavide55.github.io/Tacet/) · [**Release notes**](https://github.com/scadavide55/Tacet/releases)

*Image from Tacet 1.6.2( old website and logo)*
<img src="docs/assets/screenshot.jpg" alt="Tacet with its website open and Tacet Assistant summarising the page" width="860">

<img src="docs/assets/groups.png" alt="Tab groups along the top of the Tacet window, each in its own colour" width="860">

</div>

> [!NOTE]
> **Lumen is now Tacet.** Same browser, new name: there were already other browsers called Lumen, and the name sounded too much like an AI product. Updating keeps all your tabs, passwords and settings.
>
> **1.8** brings Deep research and a tidy activity line to Tacet Assistant, which is no longer a beta, with links checked against what it read, PDFs and JavaScript pages, SearXNG and Brave Search, models on your Mac that get the context they need, personal instructions, an optional memory, @ to send tabs, and chat search; pages that can't lock Tacet with dialogs, a camera and microphone indicator, addresses completed as you type, unit conversions, Find with a match count, sign-ins inside embedded frames, anti-fingerprinting that can't be detected, full-text history search, whole-page screenshots, a fuller Site Information panel, a proxy per profile and a search field in Settings. **1.7.1** adds Developer Mode (Web Inspector, page source, Responsive Design Mode and more), downloads with speed, pause and resume and a list that lasts, a quicker Tacet Assistant with a voice of its own, Reopen Closed Window, and fixes that make Tacet faster and steadier. **1.7** brings Spaces, search by what pages said, link previews, highlights and notes, opening rules, unsent text recovery, automations, a Safari route for passkeys and a security pass. **1.6.5** had a new icon, Seal, corona, with sixteen others to pick in Settings › Appearance, plus fixes for the compact layout, Reddit sign-ins and importing from Safari. **1.6.4** brought Tacet Plugins (beta), a verified store with Cutout, Focus Timer, Smart Dark Mode and more, an extensions menu, a Tacet Assistant that knows all of Tacet and runs on Ollama or LM Studio, and better tabs. **1.6.3** brought your Arc sidebar across, a stronger Tacet Shield, tab previews, translation on your Mac and a password check. **1.6.2** has a new icon and a few fixes. **1.6.1** brought web extensions, an offline Reading List, Customize Site, tab organising and a much more capable Tacet Assistant, including Apple's on-device model. Deep research and Browser use are still in beta; if something doesn't work, please report it in [Issues](https://github.com/scadavide55/Tacet/issues).

## Features

**Tacet Assistant**
- An AI assistant in a panel beside the page (⇧⌘A): summaries, answers and explanations about what you're reading
- Bring your own key: Anthropic, OpenAI, OpenRouter, DeepSeek, or run models on your Mac with Ollama or LM Studio (no key; Tacet finds their models), or any OpenAI-compatible server
- Knows everything about Tacet (every feature, menu and shortcut) and uses your Tacet Plugins when you ask, such as "remove the background of this picture"
- **Apple's on-device model** (macOS 26 with Apple Intelligence): free, offline and private, with no key. It's smaller, so it's best for short tasks
- Reads your other tabs without switching to them, searches your history and bookmarks, and takes screenshots of the page when the layout matters
- Full transcripts of YouTube videos, to summarise or ask about a video
- Select text and right-click for Tacet Assistant › Explain, Translate, Summarise or Ask About It
- Ask from the command bar for a quick answer that searches the web only when it needs to and starts answering almost at once, then continue in the full chat if you want
- Short, direct answers in a calm voice of its own, or detailed and neutral ones if you prefer (Settings › AI › Answers)
- **Web access** (on by default): searches the web and reads pages, with the sources listed under each answer
- **Deep research** (beta): plans the question, runs many searches, reads the best pages in full, checks facts in more than one source and writes a report with its sources linked and what's still uncertain
- An activity line above each reply says what it's doing (Searching the web, Reading 3 pages, Thinking) with the time, and opens into every step
- Replies with headings, lists, tables and code you can copy, sources as chips, Copy and Ask Again
- Opens pages and searches in new tabs, switches between your tabs and groups them when you ask
- **Browser use** (beta, off by default): clicks, types, scrolls and drags on the current page for you. It never fills in passwords or card numbers, and asks before sending, buying or deleting anything
- Chat history on your Mac (not in private windows), a full-window chat view, and a panel you can resize
- Off by default; page content is treated as data, never as instructions

**Tacet Plugins (beta)**
- A store of plugins made for Tacet and checked by its developer (⇧⌘P), that work on every Mac: each says who made it and whether it's verified
- Cutout removes picture backgrounds on your Mac, offline: hover a picture and click ✂ Cutout, or right-click it
- YouTube without Shorts, YouTube Focus, Copy as Markdown, Smart Dark Mode, Focus Timer, Keyboard Navigation, Video Speed, Picture in Picture, Clean Links on Copy, Google Just Results, Old Reddit and more
- The puzzle button lists every plugin and extension: a click opens, runs, turns on or off, or explains it; pin any to the toolbar, or turn one off for a single site
- Signed and checked file by file; plugins run in their own space that pages can't reach, and update by themselves

**Extensions**
- Web extensions on macOS 15.4 or later, the same kind Safari, Chrome and Firefox use
- Add the Safari extensions that come with your apps in one click, or add a folder, .zip, .crx (Chrome) or .xpi (Firefox) file
- See what an extension can do before adding it; extensions never run in private windows
- Toolbar buttons with badges and popups, right-click menu items and settings pages

**Tacet Shield**
- Built-in ad and tracker blocking that works offline, toggled with ⇧⌘B
- Optional EasyList and EasyPrivacy filter lists, converted to WebKit rules and refreshed weekly
- Turn protection off for a single site from the shield button
- Shows what it blocked on the page, on the site and since you opened Tacet
- Hides cookie consent banners, rejects optional cookies for you, and skips YouTube ads
- Protects against fingerprinting: canvas, WebGL and audio readings change slightly for each site
- Optional AdGuard Base, Fanboy Annoyances and hidden (CNAME) tracker lists
- Blocks third-party cookies

**Privacy**
- Removes tracking parameters (`utm_`, `fbclid`, `gclid` and more) from links
- Upgrades connections to HTTPS and falls back when a site doesn't support it
- Sends Global Privacy Control
- Private windows that forget everything when you close them
- Optionally clears cookies, cache and history when you quit
- HTTPS-only mode, confirmation before downloading apps and scripts, and Touch ID lock for private windows

**Passwords**
- Saves passwords in the macOS Keychain and fills them after Touch ID
- Suggests strong passwords on sign-up pages (optional)
- Imports and exports CSV for Apple Passwords, and works alongside 1Password, KeePassXC and others
- Password check: finds passwords from data breaches (only a 5-character hash prefix is sent), reused or weak ones

**Moving in**
- Imports bookmarks, history and sign-ins from Safari, Chrome, Firefox, Opera, Brave, Edge, Arc and other Chromium browsers
- From Arc, also your Spaces, Favorites, pinned tabs and folders, as tab groups and pinned tabs
- A guided setup on first launch, in English, Italian or French

**Tabs and windows**
- Tab groups: drag a tab onto another, or let Tacet group tabs from the same site once there are 2, 3 or 5 of them, except sites you exclude
- Save a group and close it, then open it again later with all its tabs; open a new tab inside a group
- Pick several tabs with ⌘-click and ⇧-click to group, move, pin or close them together
- Move tabs or whole groups to another window or profile
- Sort tabs by site, title or last opened, and close duplicate tabs in one click
- Tacet Assistant can group tabs by topic when you ask, such as "Rome trip"
- Sidebar, separate or compact tab layouts
- Install any site as an app with its own window and Dock icon
- Vertical tabs in a resizable sidebar, or tabs along the top
- Pinned tabs, drag to reorder, split view, reopen closed tabs
- Background tabs hibernate to save memory, shown in grey, and wake up showing the page as you left it, scrolled to the same place
- Hover over a tab for a preview with its page, site and memory use; search tabs with ⌥⌘F
- Pinned tabs keep their site, as in Arc; ⇧⌘T brings back tabs closed together; middle-click closes a tab
- With profiles, Tacet asks who's browsing when it opens; move settings and plugins to another Mac in one file
- Windows and tabs come back when you reopen Tacet

**Getting around**
- Command bar (⌘L / ⌘K) for addresses, searches, open tabs, bookmarks, history and commands, and sums worked out as you type
- Search shortcuts, for example `yt lofi` searches YouTube
- Choice of search engine: DuckDuckGo, Google, Bing, Brave, Startpage, Ecosia, Kagi or your own
- Reader mode, find on page, per-site zoom
- Translate pages on your Mac with Apple's translation, have them read aloud, or hide everything but the page with Focus Mode
- Reading List: save articles in Reader with their images to read later, even offline
- Bookmarks with HTML import and export, searchable history
- Downloads with speed and time left, pause and resume (even after quitting), Download Again, and a list kept in the Library

**For developers**
- Developer Mode (Settings › Advanced) adds a Develop menu and Inspect Element: the Web Inspector and JavaScript console, page source (or type `view-source:` and an address), page load times and sizes
- Responsive Design Mode shows the page at iPhone, Pixel, iPad and laptop sizes with their user agents, turned sideways if you like
- Switch user agent, open the page in another browser, turn off JavaScript or styles, outline every element, edit the page's text, empty caches or clear one site's data

**Make it yours**
- Light, dark or system appearance and any accent colour
- Sidebar on the left or right, floating page with rounded corners, compact tabs
- Window tint that follows the site's colour
- Start page with clock, greeting, favourites and backgrounds: gradients, animated gradients, your own photo or a short video
- Customize Site: per-site theme, font and width, hide floating bars, images or anything you click on, and your own CSS or JavaScript

## Keyboard shortcuts

| Shortcut | Action |
| --- | --- |
| ⌘T / ⌘W | New tab / close tab |
| ⇧⌘T | Reopen closed tab (or window) |
| ⌘N / ⇧⌘N | New window / new private window |
| ⌘L or ⌘K | Command bar |
| ⌘S | Show or hide the sidebar |
| ⌃Tab / ⌃⇧Tab | Next / previous tab |
| ⌘1 … ⌘9 | Go to tab |
| ⌘[ / ⌘] | Back / forward |
| ⌘F, ⌘G | Find on page, find next |
| ⇧⌘R | Reader |
| ⌥⌘S | Split view |
| ⌘D | Bookmark the page |
| ⌘Y | History |
| ⇧⌘B | Turn the ad blocker on or off |
| ⌥⌘I / ⌥⌘U | Web Inspector / page source (Developer Mode) |

## Requirements

- macOS 14 Sonoma or later
- Apple silicon or Intel
- Xcode command line tools (to build from source)

## Build

```sh
./build.sh
open Tacet.app
```

`tools/test.sh` runs the logic tests (addresses, link cleaning, password sites, CSV, filter lists, history database, and WebKit compiling Shield's rules). `build.sh` compiles everything in `Sources` for Apple silicon and Intel, assembles a universal `Tacet.app` and signs it ad hoc. `tools/make-dmg.sh` then packages it as a disk image. Translations live in `tools/translations.py`; run it to regenerate the `.lproj` files. The app icons are drawn as SVGs in `docs/assets/logo-prototypes`; `python3 tools/make-icons.py` (needs Pillow) renders the default icon set and `Tacet.icns`, the alternatives you can pick in Settings › Appearance into `Resources/AppIcons`, and the site's icon and favicon.

## Installing a downloaded build

Open the `.dmg` and drag Tacet to Applications. Release builds are not notarized yet, so on recent versions of macOS the first launch says Tacet "is damaged and can't be opened". The download is fine: macOS blocks apps from the internet that Apple hasn't notarized. Run this once in Terminal, then open Tacet normally:

```bash
xattr -dr com.apple.quarantine /Applications/Tacet.app
```

After that, Tacet tells you about new versions and can install them for you.

## License

Tacet is free software, released under the [GNU General Public License v3.0](LICENSE).
