import SwiftUI

/// A greeting that changes based on time of day
struct DynamicGreeting: View {
    private var timeBasedGreeting: String {
        let hour = Calendar.current.component(.hour, from: Date())
        switch hour {
        case 5..<12:
            return "Good Morning"
        case 12..<17:
            return "Good Afternoon"
        default:
            return "Good Evening"
        }
    }

    var body: some View {
        Text(timeBasedGreeting)
            .font(.largeTitle.weight(.bold))
    }
}

#Preview {
    DynamicGreeting()
        .padding()
}
