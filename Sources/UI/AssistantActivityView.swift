import SwiftUI

/// The line above a reply that says what Tacet Assistant is doing, with a small animation and the time so far. It opens
/// into the list of every step: searches, pages read, steps on the page, research stages and time spent thinking.
/// Thinking is shown only as time spent, never its content.
struct AssistantActivityView: View {
    let steps: [AssistantStep]
    let research: Bool
    let started: Date?
    let finished: Date?
    /// The reply is still being worked on.
    let running: Bool
    /// Text of the reply is coming in.
    let writing: Bool
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button {
                withAnimation(.snappy(duration: 0.22)) { expanded.toggle() }
            } label: {
                if running {
                    // Four times a second: enough for the dots and the seconds, and only this line redraws.
                    TimelineView(.periodic(from: started ?? .now, by: 0.25)) { context in header(now: context.date) }
                } else {
                    header(now: finished ?? .now)
                }
            }
            .buttonStyle(.plain)
            .help(expanded ? "Hide the steps" : "Show the steps")
            if expanded {
                list.transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
    }

    private func title(now: Date) -> String {
        if running { return AssistantActivity.live(steps, writing: writing) ?? AssistantActivity.summary(steps, research: research, now: now) ?? L("Thinking") }
        return AssistantActivity.summary(steps, research: research, now: now) ?? L("Done")
    }

    private func header(now: Date) -> some View {
        let text = title(now: now)
        let elapsed = started.map { AssistantStep.time(now.timeIntervalSince($0)) }
        let failed = AssistantActivity.failures(steps)
        return HStack(spacing: 7) {
            ActivityDots(active: running, tick: Int(now.timeIntervalSince(started ?? now) * 4))
            if research {
                Image(systemName: "binoculars").font(.system(size: 10.5)).foregroundStyle(.secondary)
            }
            Text(text)
                .font(.system(size: 12.5))
                .foregroundStyle(running ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
                .lineLimit(1).truncationMode(.tail)
            if let elapsed {
                Text(elapsed).font(.system(size: 12)).monospacedDigit().foregroundStyle(.tertiary).fixedSize()
            }
            if failed > 0, !running {
                Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 9.5)).foregroundStyle(.orange)
                    .help(failed == 1 ? L("1 step didn't work") : String(format: L("%d steps didn't work"), failed))
            }
            Image(systemName: "chevron.right")
                .font(.system(size: 8.5, weight: .bold)).foregroundStyle(.tertiary)
                .rotationEffect(.degrees(expanded ? 90 : 0))
            Spacer(minLength: 0)
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel([text, elapsed].compactMap { $0 }.joined(separator: ", "))
        .accessibilityHint(expanded ? L("Hides the steps") : L("Shows the steps"))
        .accessibilityAddTraits(.isButton)
    }

    private var list: some View {
        let shown = AssistantActivity.listed(steps)
        return VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(shown.enumerated()), id: \.element.id) { n, step in
                if n > 0 { Divider().opacity(0.6) }
                AssistantStepRow(step: step)
            }
        }
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.primary.opacity(0.025)))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Color.primary.opacity(0.09)))
    }
}

/// Three dots that pulse one after another while the assistant works, and rest when it's done.
struct ActivityDots: View {
    let active: Bool
    let tick: Int

    var body: some View {
        HStack(spacing: 2.5) {
            ForEach(0..<3, id: \.self) { i in
                Circle()
                    .fill(Color.accentColor)
                    .frame(width: 4.5, height: 4.5)
                    .opacity(active ? (tick % 3 == i ? 1 : 0.3) : (i == 1 ? 0.25 : 0.55))
                    .scaleEffect(active && tick % 3 == i ? 1.2 : 1)
            }
        }
        .animation(.easeInOut(duration: 0.25), value: tick)
        .frame(width: 20)
        .accessibilityHidden(true)
    }
}

/// One step in the opened list: what it was, what it was about, how it went and how long it took. Searches and
/// pages open in a new tab when clicked.
struct AssistantStepRow: View {
    let step: AssistantStep
    @Environment(BrowserState.self) var b

    private var target: URL? {
        switch step.kind {
        case .search: InputResolver.searchURL(step.detail)
        case .read, .browse: step.url
        default: nil
        }
    }

    var body: some View {
        if step.running {
            TimelineView(.periodic(from: step.started, by: 1)) { context in row(now: context.date) }
        } else {
            row(now: step.ended ?? step.started)
        }
    }

    private func row(now: Date) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            icon.frame(width: 14)
            VStack(alignment: .leading, spacing: 2) {
                line
                if let outcome = step.outcome {
                    Text(outcome).font(.system(size: 11))
                        .foregroundStyle(step.status == .failed ? AnyShapeStyle(.orange) : AnyShapeStyle(.tertiary))
                }
            }
            Spacer(minLength: 4)
            let seconds = step.duration(at: now)
            if step.kind != .thinking, step.kind != .note, step.started.timeIntervalSince1970 > 0, seconds >= 1 || step.running {
                Text(AssistantStep.time(seconds)).font(.system(size: 11)).monospacedDigit().foregroundStyle(.tertiary)
            }
            if target != nil {
                Image(systemName: "arrow.up.right").font(.system(size: 9, weight: .semibold)).foregroundStyle(.tertiary)
            }
        }
        .font(.system(size: 12))
        .padding(.horizontal, 10).padding(.vertical, 6)
        .contentShape(Rectangle())
        .onTapGesture { if let target { b.newTab(url: target) } }
        .help(target?.absoluteString ?? "")
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(target != nil ? .isLink : [])
    }

    @ViewBuilder private var line: some View {
        switch step.kind {
        case .note:
            Text(step.detail).italic().foregroundStyle(.secondary).lineLimit(4)
        case .stage:
            VStack(alignment: .leading, spacing: 2) {
                Text(step.title ?? "").fontWeight(.medium)
                if !step.detail.isEmpty {
                    Text(step.detail).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
        default:
            HStack(spacing: 5) {
                if let title = step.title { Text(title).foregroundStyle(.secondary).fixedSize() }
                if !step.detail.isEmpty {
                    Text(step.detail).lineLimit(1).truncationMode(.middle)
                }
            }
        }
    }

    @ViewBuilder private var icon: some View {
        switch step.status {
        case .running:
            ProgressView().controlSize(.mini).scaleEffect(0.8)
        case .failed:
            Image(systemName: "exclamationmark.circle").foregroundStyle(.orange)
        case .stopped:
            Image(systemName: "stop.circle").foregroundStyle(.secondary)
        case .done:
            Image(systemName: Self.symbol(step.kind)).foregroundStyle(.secondary)
        }
    }

    static func symbol(_ kind: AssistantStep.Kind) -> String {
        switch kind {
        case .thinking: "ellipsis.bubble"
        case .search: "magnifyingglass"
        case .read: "doc.text"
        case .browse: "cursorarrow.click"
        case .tool: "wrench.and.screwdriver"
        case .stage: "checklist"
        case .note: "text.bubble"
        }
    }
}

// MARK: - Markdown

/// A reply in Markdown, laid out block by block: headings, lists, code with a copy button, quotes, rules and tables.
struct AssistantMarkdown: View {
    let text: String
    /// Normalised links the assistant never read, shown dimmed with a mark after them.
    var unverified: Set<String> = []

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(MarkdownBlocks.parse(text).enumerated()), id: \.offset) { _, block in
                view(for: block)
            }
        }
    }

    @ViewBuilder private func view(for block: MarkdownBlock) -> some View {
        switch block {
        case .heading(let level, let text):
            Self.inline(text, unverified)
                .font(.system(size: level == 1 ? 16 : level == 2 ? 14.5 : 13.5, weight: .semibold))
                .padding(.top, 4)
                .accessibilityAddTraits(.isHeader)
        case .paragraph(let text):
            Self.inline(text, unverified)
        case .list(let items):
            VStack(alignment: .leading, spacing: 4) {
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(item.marker).foregroundStyle(.secondary).monospacedDigit()
                            .frame(minWidth: item.marker == "•" ? 8 : 16, alignment: .trailing)
                        Self.inline(item.text, unverified)
                    }
                    .padding(.leading, CGFloat(item.level) * 14)
                }
            }
        case .code(let language, let code):
            CodeBlock(language: language, code: code)
        case .quote(let text):
            HStack(alignment: .top, spacing: 8) {
                RoundedRectangle(cornerRadius: 1).fill(Color.secondary.opacity(0.4)).frame(width: 3)
                Self.inline(text, unverified).foregroundStyle(.secondary)
            }
            .fixedSize(horizontal: false, vertical: true)
        case .rule:
            Divider().padding(.vertical, 2)
        case .table(let header, let rows):
            ScrollView(.horizontal, showsIndicators: false) {
                Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 5) {
                    GridRow { ForEach(Array(header.enumerated()), id: \.offset) { _, c in Self.inline(c, unverified).fontWeight(.semibold) } }
                    Divider()
                    ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                        GridRow { ForEach(Array(row.enumerated()), id: \.offset) { _, c in Self.inline(c, unverified) } }
                    }
                }
                .padding(.vertical, 2)
            }
        }
    }

    /// Inline Markdown (bold, italics, code, links), keeping the model's line breaks. A link to a page the assistant
    /// never read still opens, but is dimmed with a question mark after it, so a made-up source doesn't pass for a
    /// checked one. SwiftUI text has no tooltip for part of it, so the explanation is on the whole paragraph.
    @ViewBuilder static func inline(_ text: String, _ unverified: Set<String> = []) -> some View {
        let (shown, marked) = styled(text, unverified)
        if marked {
            shown.textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                .help(L("Source not read by the assistant"))
                .accessibilityHint(L("Source not read by the assistant"))
        } else {
            shown.textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
        }
    }

    private static func styled(_ text: String, _ unverified: Set<String>) -> (Text, Bool) {
        var attributed = AssistantBubble.markdown(text)
        guard !unverified.isEmpty else { return (Text(attributed), false) }
        let ranges = attributed.runs[\.link].compactMap { link, range in
            link.map { AssistantCitations.isUnverified($0, in: unverified) } == true ? range : nil
        }
        guard !ranges.isEmpty else { return (Text(attributed), false) }
        for range in ranges { attributed[range].foregroundColor = .secondary }
        let mark = Text(Image(systemName: "questionmark.circle")).foregroundStyle(.secondary)
        var shown = Text(verbatim: "")
        var start = attributed.startIndex
        for range in ranges {
            shown = Text("\(shown)\(Text(AttributedString(attributed[start..<range.upperBound])))\u{2009}\(mark)")
            start = range.upperBound
        }
        shown = Text("\(shown)\(Text(AttributedString(attributed[start...])))")
        return (shown, true)
    }
}

struct CodeBlock: View {
    let language: String
    let code: String
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(language.isEmpty ? L("Code") : language).font(.system(size: 10.5, weight: .medium)).foregroundStyle(.secondary)
                Spacer()
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(code, forType: .string)
                    copied = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { copied = false }
                } label: {
                    Label(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc")
                        .font(.system(size: 10.5)).labelStyle(.titleAndIcon)
                }
                .buttonStyle(.plain).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 10).padding(.vertical, 5)
            Divider().opacity(0.5)
            ScrollView(.horizontal, showsIndicators: false) {
                Text(code).font(.system(size: 11.5, design: .monospaced)).textSelection(.enabled)
                    .fixedSize(horizontal: true, vertical: true)
                    .padding(10)
            }
        }
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.primary.opacity(0.05)))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Color.primary.opacity(0.07)))
    }
}

// MARK: - Sources

/// The pages an answer drew on, as small chips that open in a new tab.
struct AssistantSourceChips: View {
    let sources: [(url: URL, title: String)]
    @Environment(BrowserState.self) var b
    @State private var showAll = false
    private static let first = 8

    var body: some View {
        let shown = showAll ? sources : Array(sources.prefix(Self.first))
        VStack(alignment: .leading, spacing: 5) {
            Text(sources.count == 1 ? L("1 source") : String(format: L("%d sources"), sources.count))
                .font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
            FlowLayout(spacing: 5) {
                ForEach(Array(shown.enumerated()), id: \.offset) { n, source in
                    Button { b.newTab(url: source.url) } label: {
                        HStack(spacing: 4) {
                            Text("\(n + 1)").foregroundStyle(.tertiary).monospacedDigit()
                            Text(InputResolver.displayHost(source.url)).lineLimit(1)
                        }
                        .font(.system(size: 11))
                        .padding(.horizontal, 7).padding(.vertical, 3)
                        .background(Capsule().fill(Color.primary.opacity(0.07)))
                    }
                    .buttonStyle(.plain)
                    .help(source.title + "\n" + source.url.absoluteString)
                    .accessibilityLabel(source.title)
                    .accessibilityAddTraits(.isLink)
                }
                if sources.count > Self.first && !showAll {
                    Button(String(format: L("%d more"), sources.count - Self.first)) { showAll = true }
                        .buttonStyle(.link).font(.system(size: 11))
                }
            }
        }
        .padding(.top, 2)
    }
}

/// Lays out its views in rows, wrapping to the next row when one is full.
struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(width: proposal.width ?? .infinity, subviews: subviews)
        return CGSize(width: rows.width, height: rows.height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let rows = arrange(width: bounds.width, subviews: subviews)
        for (n, point) in rows.points.enumerated() {
            subviews[n].place(at: CGPoint(x: bounds.minX + point.x, y: bounds.minY + point.y), proposal: .unspecified)
        }
    }

    private func arrange(width: CGFloat, subviews: Subviews) -> (points: [CGPoint], width: CGFloat, height: CGFloat) {
        var points: [CGPoint] = []
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0, widest: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > 0, x + size.width > width {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            points.append(CGPoint(x: x, y: y))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
            widest = max(widest, x - spacing)
        }
        return (points, min(widest, width), y + rowHeight)
    }
}
