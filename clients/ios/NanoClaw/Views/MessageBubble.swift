import SwiftUI
import MarkdownUI

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
            Markdown(message.text)
                .markdownTheme(.nanoclaw)
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

// MARK: - Markdown Theme

extension MarkdownUI.Theme {
    static let nanoclaw = Theme()
        .text {
            ForegroundColor(.white)
            FontSize(16)
        }
        .code {
            FontFamilyVariant(.monospaced)
            FontSize(14)
            ForegroundColor(Color(hex: 0xE0E0E0))
            BackgroundColor(Color(hex: 0x1A1A1A))
        }
        .codeBlock { configuration in
            ScrollView(.horizontal, showsIndicators: false) {
                configuration.label
                    .markdownTextStyle {
                        FontFamilyVariant(.monospaced)
                        FontSize(13)
                        ForegroundColor(Color(hex: 0xE0E0E0))
                    }
                    .padding(12)
            }
            .background(Color(hex: 0x1A1A1A))
            .clipShape(RoundedRectangle(cornerRadius: 8))
        }
        .link {
            ForegroundColor(.purple)
        }
        .heading1 { configuration in
            configuration.label
                .markdownTextStyle {
                    FontWeight(.bold)
                    FontSize(22)
                    ForegroundColor(.white)
                }
                .markdownMargin(top: 16, bottom: 8)
        }
        .heading2 { configuration in
            configuration.label
                .markdownTextStyle {
                    FontWeight(.semibold)
                    FontSize(18)
                    ForegroundColor(.white)
                }
                .markdownMargin(top: 12, bottom: 6)
        }
        .heading3 { configuration in
            configuration.label
                .markdownTextStyle {
                    FontWeight(.semibold)
                    FontSize(16)
                    ForegroundColor(.white)
                }
                .markdownMargin(top: 8, bottom: 4)
        }
        .listItem { configuration in
            configuration.label
                .markdownTextStyle {
                    ForegroundColor(.white)
                }
        }
        .blockquote { configuration in
            HStack(spacing: 0) {
                Rectangle()
                    .fill(Color.purple.opacity(0.6))
                    .frame(width: 3)
                configuration.label
                    .markdownTextStyle {
                        ForegroundColor(Color(hex: 0xBBBBBB))
                        FontStyle(.italic)
                    }
                    .padding(.leading, 12)
            }
        }
}
