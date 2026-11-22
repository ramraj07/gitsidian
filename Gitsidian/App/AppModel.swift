import Foundation
import Observation

@Observable @MainActor
final class AppModel {
    var token: String? = Keychain.read()
    var login: String?
    var vaults: [VaultConfig] = []
    var session: VaultSession?

    private let vaultsKey = "vaults"
    private let lastVaultKey = "lastVault"

    init() {
        if let d = UserDefaults.standard.data(forKey: vaultsKey),
           let v = try? JSONDecoder().decode([VaultConfig].self, from: d) {
            vaults = v
        }
        if token != nil, let last = UserDefaults.standard.string(forKey: lastVaultKey),
           let v = vaults.first(where: { $0.id.uuidString == last }) {
            open(v)
        }
    }

    var client: GitHubClient? { token.map { GitHubClient(token: $0) } }

    func signIn(token: String) async throws {
        let t = token.trimmingCharacters(in: .whitespacesAndNewlines)
        let user = try await GitHubClient(token: t).currentUser()
        Keychain.save(t)
        self.token = t
        self.login = user.login
    }

    func signOut() {
        session = nil
        Keychain.delete()
        token = nil
        login = nil
    }

    private func persist() {
        UserDefaults.standard.set(try? JSONEncoder().encode(vaults), forKey: vaultsKey)
    }

    func addVault(owner: String, repo: String, branch: String) {
        if let existing = vaults.first(where: { $0.owner == owner && $0.repo == repo && $0.branch == branch }) {
            open(existing); return
        }
        let v = VaultConfig(owner: owner, repo: repo, branch: branch)
        vaults.append(v)
        persist()
        open(v)
    }

    func open(_ v: VaultConfig) {
        guard let client else { return }
        session = VaultSession(config: v, client: client)
        UserDefaults.standard.set(v.id.uuidString, forKey: lastVaultKey)
    }

    func closeVault() {
        session = nil
        UserDefaults.standard.removeObject(forKey: lastVaultKey)
    }

    func remove(_ v: VaultConfig) {
        if session?.config.id == v.id { closeVault() }
        vaults.removeAll { $0.id == v.id }
        persist()
        try? FileManager.default.removeItem(at: SyncEngine.vaultDirectory(v.id))
    }
}
