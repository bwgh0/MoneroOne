import SwiftUI

struct WelcomeView: View {
    @State private var showCreate = false
    @State private var showRestore = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 32) {
                Spacer()

                // Logo
                Image(systemName: "shield.checkered")
                    .font(.system(size: 80))
                    .foregroundColor(.orange)

                VStack(spacing: 8) {
                    Text("Monero One")
                        .font(.largeTitle)
                        .fontWeight(.bold)

                    Text("Simple. Private. Secure.")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }

                Spacer()

                VStack(spacing: 16) {
                    Button {
                        showCreate = true
                    } label: {
                        Text("Create New Wallet")
                            .fontWeight(.semibold)
                            .frame(maxWidth: .infinity)
                            .padding()
                            .background(Color.orange)
                            .foregroundColor(.white)
                            .cornerRadius(14)
                    }

                    Button {
                        showRestore = true
                    } label: {
                        Text("Restore Wallet")
                            .fontWeight(.semibold)
                            .frame(maxWidth: .infinity)
                            .padding()
                            .background(Color(.secondarySystemBackground))
                            .foregroundColor(.primary)
                            .cornerRadius(14)
                    }
                }
                .padding(.horizontal)
                .padding(.bottom, 32)
            }
            .navigationDestination(isPresented: $showCreate) {
                CreateWalletView()
            }
            .navigationDestination(isPresented: $showRestore) {
                RestoreWalletView()
            }
        }
    }
}

#Preview {
    WelcomeView()
}
