import SwiftUI

struct MessageBubble: View {
    let message: Message

    private var isUser: Bool { message.role == .user }

    var body: some View {
        HStack {
            if isUser { Spacer(minLength: 60) }

            bubbleContent
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(bubbleBackground)
                .clipShape(RoundedRectangle(cornerRadius: 16))

            if !isUser { Spacer(minLength: 60) }
        }
    }

    @ViewBuilder
    private var bubbleContent: some View {
        if isUser {
            Text(message.text)
                .foregroundStyle(.white)
                .font(.body)
        } else {
            SimpleMarkdown(text: message.text)
        }
    }

    @ViewBuilder
    private var bubbleBackground: some View {
        if isUser {
            LinearGradient(
                colors: [Color(hex: 0x7B2FBE), Color(hex: 0x5B1FA0)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        } else {
            Color(hex: 0x2A2A2A)
        }
    }
}

// MARK: - Color hex helper

extension Color {
    init(hex: UInt, alpha: Double = 1.0) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255,
            opacity: alpha
        )
    }
}

// MARK: - Lightweight Markdown Renderer

/// Parses and renders markdown without external dependencies.
/// Handles: H1-H3, fenced code blocks, bullet lists, paragraphs,
/// and inline bold/italic/code via iOS AttributedString.
struct SimpleMarkdown: View {
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                renderBlock(block)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: Block model

    private enum Block {
        case h1(String), h2(String), h3(String)
        case codeBlock(lang: String, code: String)
        case bullet(String)
        case paragraph(String)
        case spacer
    }

    // MARK: Parser

    private var blocks: [Block] {
        var result: [Block] = []
        let lines = text.components(separatedBy: "\n")
        var i = 0

        while i < lines.count {
            let line = lines[i]
            if line.hasPrefix("### ") {
                result.append(.h3(String(line.dropFirst(4)))); i += 1
            } else if line.hasPrefix("## ") {
                result.append(.h2(String(line.dropFirst(3)))); i += 1
            } else if line.hasPrefix("# ") {
                result.append(.h1(String(line.dropFirst(2)))); i += 1
            } else if line.hasPrefix("```") {
                let lang = String(line.dropFirst(3)).trimmingCharacters(in: .whitespaces)
                var code: [String] = []
                i += 1
                while i < lines.count && !lines[i].hasPrefix("```") { code.append(lines[i]); i += 1 }
                if i < lines.count { i += 1 }
                result.append(.codeBlock(lang: lang, code: code.joined(separator: "\n")))
            } else if line.hasPrefix("- ") || line.hasPrefix("* ") {
                result.append(.bullet(String(line.dropFirst(2)))); i += 1
            } else if line.trimmingCharacters(in: .whitespaces).isEmpty {
                let lastIsSpacer: Bool
                if let last = result.last, case .spacer = last { lastIsSpacer = true } else { lastIsSpacer = false }
                if !lastIsSpacer { result.append(.spacer) }
                i += 1
            } else {
                result.append(.paragraph(line)); i += 1
            }
        }
        while case .spacer? = result.first { result.removeFirst() }
        while case .spacer? = result.last { result.removeLast() }
        return result
    }

    // MARK: Rendering

    @ViewBuilder
    private func renderBlock(_ block: Block) -> some View {
        switch block {
        case .h1(let t):
            inlineText(t).font(.title2.bold()).foregroundStyle(.white)
                .padding(.top, 4).frame(maxWidth: .infinity, alignment: .leading)
        case .h2(let t):
            inlineText(t).font(.title3.bold()).foregroundStyle(.white)
                .frame(maxWidth: .infinity, alignment: .leading)
        case .h3(let t):
            inlineText(t).font(.headline).foregroundStyle(.white)
                .frame(maxWidth: .infinity, alignment: .leading)
        case .codeBlock(let lang, let code):
            codeBlockView(lang: lang, code: code)
        case .bullet(let t):
            HStack(alignment: .top, spacing: 8) {
                Text("•").foregroundStyle(.white.opacity(0.7)).font(.body)
                inlineText(t).font(.body).foregroundStyle(.white)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        case .paragraph(let t):
            inlineText(t).font(.body).foregroundStyle(.white)
                .frame(maxWidth: .infinity, alignment: .leading)
        case .spacer:
            Color.clear.frame(height: 4)
        }
    }

    private func inlineText(_ t: String) -> Text {
        if let attr = try? AttributedString(
            markdown: t,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        ) { return Text(attr) }
        return Text(t)
    }

    @ViewBuilder
    private func codeBlockView(lang: String, code: String) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            if !lang.isEmpty {
                Text(lang)
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundStyle(Color(hex: 0x888888))
                    .padding(.horizontal, 12).padding(.top, 8).padding(.bottom, 2)
            }
            ScrollView(.horizontal, showsIndicators: false) {
                Text(code)
                    .font(.system(size: 13, design: .monospaced))
                    .foregroundStyle(Color(hex: 0xE0E0E0))
                    .padding(.horizontal, 12).padding(.vertical, 10)
                    .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
            }
        }
        .background(Color(hex: 0x1A1A1A))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}
