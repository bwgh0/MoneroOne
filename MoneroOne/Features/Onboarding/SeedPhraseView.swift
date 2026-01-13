import SwiftUI

struct SeedPhraseView: View {
    let words: [String]
    let columns = 3

    var body: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: columns), spacing: 8) {
            ForEach(Array(words.enumerated()), id: \.offset) { index, word in
                HStack(spacing: 4) {
                    Text("\(index + 1).")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                        .frame(width: 20, alignment: .trailing)

                    Text(word)
                        .font(.system(.caption, design: .monospaced))
                        .fontWeight(.medium)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                .background(Color(.tertiarySystemBackground))
                .cornerRadius(8)
            }
        }
    }
}

#Preview {
    SeedPhraseView(words: [
        "abandon", "ability", "able", "about", "above",
        "absent", "absorb", "abstract", "absurd", "abuse",
        "access", "accident", "account", "accuse", "achieve",
        "acid", "acoustic", "acquire", "across", "act",
        "action", "actor", "actress", "actual", "adapt"
    ])
    .padding()
}
