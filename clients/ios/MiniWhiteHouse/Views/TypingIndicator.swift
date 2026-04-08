import SwiftUI

struct TypingIndicator: View {
    @State private var phase = 0.0

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
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

            VStack(alignment: .leading, spacing: 4) {
                Text("NanoClaw")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color(hex: 0x888888))

                HStack(spacing: 5) {
                    ForEach(0..<3) { index in
                        Circle()
                            .fill(Color(hex: 0x7C3AED).opacity(0.6))
                            .frame(width: 7, height: 7)
                            .offset(y: dotOffset(for: index))
                    }
                }
                .padding(.top, 4)
            }

            Spacer(minLength: 0)
        }
        .padding(.vertical, 4)
        .onAppear {
            withAnimation(.linear(duration: 1.2).repeatForever(autoreverses: false)) {
                phase = 1.0
            }
        }
    }

    private func dotOffset(for index: Int) -> CGFloat {
        let delay = Double(index) / 3.0
        let adjustedPhase = (phase + delay).truncatingRemainder(dividingBy: 1.0)
        return -5 * sin(adjustedPhase * .pi * 2)
    }
}
