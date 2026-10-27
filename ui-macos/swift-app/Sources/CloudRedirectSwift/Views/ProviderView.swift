import SwiftUI
import AppKit

struct ProviderView: View {
    @ObservedObject var backend: BackendStore
    @State private var account = ""
    @State private var access = ""
    @State private var secret = ""
    @State private var bucket = ""
    @State private var prefix = ""
    @State private var endpoint = ""
    @State private var region = "us-east-1"
    @State private var ca = ""
    @State private var folder = ""
    @State private var hasSecret = false
    @State private var signPayload = false
    @State private var insecureHTTP = false
    @State private var insecureTLS = false
    private var provider: String { backend.text("providerName") }
    var body: some View {
        PageLayout(title: "Cloud Provider", subtitle: "Choose where CloudRedirect syncs your save files.") {
            Panel {
                Text("Provider").fontWeight(.medium)
                ChoiceMenu(title: "Cloud storage", selection: Binding(get: { provider.isEmpty ? "local" : provider }, set: { backend.set("providerName", $0) }), options: providers).frame(maxWidth: 420, alignment: .leading)
                Text(description).font(.caption).foregroundStyle(.secondary)
            }
            if provider != "local" { Panel {
                Text("Status").fontWeight(.medium)
                Label(backend.bool("providerAuthenticated") ? "Connected" : "Not connected", systemImage: backend.bool("providerAuthenticated") ? "checkmark.circle.fill" : "exclamationmark.circle").foregroundStyle(backend.bool("providerAuthenticated") ? sageIcon : .secondary)
                if provider == "gdrive" || provider == "onedrive" {
                    HStack {
                        ActionButton(title: backend.bool("providerAuthenticated") ? "Disconnect" : "Sign In in Browser", primary: true) {
                            if backend.bool("providerAuthenticated") { backend.disconnectProvider(provider) }
                            else { backend.signIn(provider) }
                        }.disabled(backend.providerBusy)
                        ActionButton(title: "Check Connection") { backend.call("testProviderConnection", [provider]) }.disabled(backend.providerBusy)
                    }
                } else if provider == "r2" || provider == "s3" {
                    ActionButton(title: backend.bool("providerAuthenticated") ? "Check Connection" : "Connect", primary: !backend.bool("providerAuthenticated")) { saveCredentials() }
                }
                if !backend.status.isEmpty { Text(backend.status).font(.caption).foregroundStyle(.secondary).textSelection(.enabled) }
            } }
            if provider == "folder" { Panel {
                Text("Sync folder").fontWeight(.medium)
                HStack { TextField("Choose a folder", text: $folder).textFieldStyle(RoundedInputStyle()).onSubmit { backend.set("syncFolderPath", folder) }; ActionButton(title: "Choose…") { let picker = NSOpenPanel(); picker.canChooseFiles = false; picker.canChooseDirectories = true; picker.canCreateDirectories = true; if picker.runModal() == .OK, let url = picker.url { folder = url.path; backend.set("syncFolderPath", folder) } } }
            } }
            if provider == "r2" || provider == "s3" { credentialFields }
        }
        .onAppear { folder = backend.text("syncFolderPath"); loadCredentials() }
        .onChange(of: provider) { _, _ in loadCredentials(); backend.call("refreshStatus") }
    }
    private var description: String {
        switch provider { case "local": "Saves stay on this Mac."; case "folder": "Sync to a local folder or network share."; case "gdrive": "Sync saves to your Google Drive account."; case "onedrive": "Sync saves to your OneDrive account."; case "r2": "Sync saves to a Cloudflare R2 bucket."; default: "Sync saves to an S3-compatible service." }
    }
    private var credentialFields: some View {
        Panel {
            Text(provider == "r2" ? "Cloudflare R2 Credentials" : "S3 Credentials").fontWeight(.semibold)
            if provider == "r2" { field("Account ID", $account) }
            field("Access key ID", $access)
            VStack(alignment: .leading, spacing: 5) { Text("Secret access key").fontWeight(.medium); SecureField(hasSecret ? "Saved · leave blank to keep" : "Secret access key", text: $secret).textFieldStyle(RoundedInputStyle()) }
            field("Bucket", $bucket); field("Key prefix (optional)", $prefix); field("Endpoint (optional)", $endpoint)
            if provider == "s3" {
                field("Region", $region); field("CA certificate path (optional)", $ca)
                Toggle("Sign payload", isOn: $signPayload); Toggle("Allow HTTP", isOn: $insecureHTTP); Toggle("Allow unverified TLS", isOn: $insecureTLS)
            }
        }
    }
    private func field(_ name: String, _ binding: Binding<String>) -> some View { VStack(alignment: .leading, spacing: 5) { Text(name).fontWeight(.medium); TextField(name, text: binding).textFieldStyle(RoundedInputStyle()) } }
    private func loadCredentials() {
        guard provider == "r2" || provider == "s3" else { return }
        backend.call(provider == "r2" ? "getR2Credentials" : "getS3Credentials") { value in
            let c = value as? [String: Any] ?? [:]
            account = string(c, "account_id"); access = string(c, "access_key_id"); bucket = string(c, "bucket"); prefix = string(c, "key_prefix"); endpoint = string(c, "endpoint"); region = string(c, "region").isEmpty ? "us-east-1" : string(c, "region"); ca = string(c, "ca_cert_path"); hasSecret = c["has_secret"] as? Bool ?? false; secret = ""; signPayload = c["sign_payload"] as? Bool ?? false; insecureHTTP = c["allow_insecure_http"] as? Bool ?? false; insecureTLS = c["allow_insecure_tls"] as? Bool ?? false
        }
    }
    private func saveCredentials() {
        let args: [Any] = provider == "r2" ? [account, access, secret, bucket, prefix, endpoint] : [access, secret, bucket, endpoint, region, prefix, signPayload, insecureHTTP, insecureTLS, ca]
        backend.call(provider == "r2" ? "saveR2Credentials" : "saveS3Credentials", args) { result in
            guard result as? Bool == true else { backend.error = "Could not save credentials."; return }
            backend.status = "Testing connection…"; backend.call("testProviderConnection", [provider])
        }
    }
}
