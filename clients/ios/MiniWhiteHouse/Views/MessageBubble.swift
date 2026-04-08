import SwiftUI
import MarkdownUI

struct MessageRow: View {
    let message: Message

    private var isUser: Bool { message.role == .user }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            avatar
            VStack(alignment: .leading, spacing: 4) {
                nameLabel
                contentView
                timestampLabel
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 4)
        .contextMenu {
            Button {
                UIPasteboard.general.string = message.text
            } label: {
                Label("Copy", systemImage: "doc.on.doc")
            }
        }
    }

    // MARK: - Avatar

    private var avatar: some View {
        Group {
            if isUser {
                Circle()
                    .fill(
                        LinearGradient(
                            colors: [Color(hex: 0x7C3AED), Color(hex: 0x5B21B6)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .frame(width: 28, height: 28)
                    .overlay(
                        Text("U")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(.white)
                    )
            } else {
                Circle()
                    .fill(Color(hex: 0x1C1C1C))
                    .frame(width: 28, height: 28)
                    .overlay(
                        Circle().stroke(Color(hex: 0x2A2A2A), lineWidth: 1)
                    )
                    .overlay(
                        Text("🤖")
                            .font(.system(size: 13))
                    )
            }
        }
    }

    // MARK: - Name

    private var nameLabel: some View {
        Text(isUser ? "You" : "NanoClaw")
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(isUser ? Color(hex: 0xC4B5FD) : Color(hex: 0x888888))
    }

    // MARK: - Content

    @ViewBuilder
    private var contentView: some View {
        if isUser {
            Text(message.text)
                .font(.body)
                .foregroundStyle(.white)
        } else {
            Markdown(message.text)
                .markdownTheme(.nanoClaw)
        }
    }

    // MARK: - Timestamp

    private var timestampLabel: some View {
        Text(message.timestamp, style: .time)
            .font(.system(size: 10))
            .foregroundStyle(Color(hex: 0x555555))
    }
}

// MARK: - MarkdownUI Theme

extension MarkdownUI.Theme {
    static let nanoClaw = Theme()
        .text {
            ForegroundColor(.init(hex: 0xD4D4D4))
            FontSize(15)
        }
        .strong {
            ForegroundColor(.white)
        }
        .link {
            ForegroundColor(.init(hex: 0xA78BFA))
        }
        .code {
            FontFamilyVariant(.monospaced)
            FontSize(.em(0.88))
            ForegroundColor(.init(hex: 0xC4B5FD))
            BackgroundColor(.init(hex: 0x1A1A1A))
        }
        .heading1 { configuration in
            configuration.label
                .markdownMargin(top: 12, bottom: 4)
                .markdownTextStyle {
                    FontWeight(.bold)
                    FontSize(20)
                    ForegroundColor(.white)
                }
        }
        .heading2 { configuration in
            configuration.label
                .markdownMargin(top: 10, bottom: 4)
                .markdownTextStyle {
                    FontWeight(.bold)
                    FontSize(17)
                    ForegroundColor(.white)
                }
        }
        .heading3 { configuration in
            configuration.label
                .markdownMargin(top: 8, bottom: 4)
                .markdownTextStyle {
                    FontWeight(.semibold)
                    FontSize(15)
                    ForegroundColor(.white)
                }
        }
        .codeBlock { configuration in
            VStack(alignment: .leading, spacing: 0) {
                if let language = configuration.language, !language.isEmpty {
                    HStack {
                        Text(language)
                            .font(.system(size: 11, weight: .medium, design: .monospaced))
                            .foregroundStyle(Color(hex: 0x888888))
                        Spacer()
                        Button {
                            UIPasteboard.general.string = configuration.content
                        } label: {
                            Image(systemName: "doc.on.doc")
                                .font(.system(size: 11))
                                .foregroundStyle(Color(hex: 0x666666))
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.horizontal, 12)
                    .padding(.top, 8)
                    .padding(.bottom, 2)
                }
                ScrollView(.horizontal, showsIndicators: false) {
                    configuration.label
                        .markdownTextStyle {
                            FontFamilyVariant(.monospaced)
                            FontSize(13)
                            ForegroundColor(.init(hex: 0xE0E0E0))
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 10)
                }
            }
            .background(Color(hex: 0x141414))
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(Color(hex: 0x222222), lineWidth: 1)
            )
        }
        .listItem { configuration in
            configuration.label
                .markdownMargin(top: 2, bottom: 2)
        }
        .paragraph { configuration in
            configuration.label
                .markdownMargin(top: 0, bottom: 6)
        }
        .blockquote { configuration in
            HStack(spacing: 0) {
                RoundedRectangle(cornerRadius: 1)
                    .fill(Color(hex: 0x7C3AED).opacity(0.6))
                    .frame(width: 3)
                configuration.label
                    .markdownTextStyle {
                        ForegroundColor(.init(hex: 0x999999))
                    }
                    .padding(.leading, 12)
            }
            .padding(.vertical, 4)
        }
        .table { configuration in
            configuration.label
                .markdownTableBorderStyle(.init(color: .secondary.opacity(0.3)))
                .markdownTableBackgroundStyle(.alternatingRows(Color(hex: 0x141414), Color(hex: 0x1A1A1A)))
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
