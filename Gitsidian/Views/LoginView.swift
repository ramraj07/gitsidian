import SwiftUI

struct LoginView: View {
    @Environment(AppModel.self) private var app
    @State private var token = ""
    @State private var busy = false
    @State private var error: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    VStack(alignment: .leading, spacing: 10) {
                        Image(systemName: "books.vertical.fill").font(.system(size: 44)).foregroundStyle(Color.accentColor)
                        Text("Gitsidian").font(.largeTitle.bold())
                        Text("Open any GitHub repository as a vault. Edit notes like local files — changes are committed back in batches.")
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 8)
                }
                Section {
                    SecureField("github_pat_…", text: $token)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .font(.system(.body, design: .monospaced))
                    Button {
                        Task {
                            busy = true; error = nil
                            do { try await app.signIn(token: token) } catch { self.error = error.localizedDescription }
                            busy = false
                        }
                    } label: {
                        HStack { Text("Sign in"); Spacer(); if busy { ProgressView() } }
                    }
                    .disabled(token.isEmpty || busy)
                } header: {
                    Text("Personal access token")
                } footer: {
                    VStack(alignment: .leading, spacing: 6) {
                        if let error { Text(error).foregroundStyle(.red) }
                        Text("Create a fine-grained token with **Contents: Read and write** (and Metadata: Read) for the repositories you want to use as vaults. It's stored in the iOS Keychain.")
                        Link("Create a token on GitHub →", destination: URL(string: "https://github.com/settings/personal-access-tokens/new")!)
                    }
                }
            }
        }
    }
}
