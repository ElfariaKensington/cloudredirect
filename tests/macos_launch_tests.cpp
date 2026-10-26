#include "app_state.h"
#include "launch_preparation.h"
#include "cloud_intercept.h"
#include <filesystem>
#include <fstream>
#include "cloud_storage.h"
#include "cloud_provider_base.h"
#include <arpa/inet.h>
#include <sys/socket.h>
#include <unistd.h>
#include <chrono>
#include <cstdio>
#include <future>
#include <stdexcept>
#include <thread>
#define CHECK(x) do { if (!(x)) throw std::runtime_error(#x); } while (0)
using namespace CloudStorage;

class MemoryProvider : public ICloudProvider {
public:
    CloudAppState state;
    int reads = 0, writes = 0, cnWrites = 0;
    bool failRead = false, failWrite = false, malformed = false;
    const char* Name() const override { return "test"; }
    bool Init(const std::string&) override { return true; }
    void Shutdown() override {}
    bool IsAuthenticated() const override { return true; }
    bool Upload(const std::string& path, const uint8_t* data, size_t size) override {
        ++writes;
        if (path.find("/cn.cloudredirect") != std::string::npos) ++cnWrites;
        if (failWrite) return false;
        return DeserializeState(std::string(reinterpret_cast<const char*>(data), size), state);
    }
    bool Download(const std::string&, std::vector<uint8_t>& data) override {
        ++reads;
        if (failRead) return false;
        auto json = malformed ? std::string("broken") : SerializeState(state);
        data.assign(json.begin(), json.end());
        return true;
    }
    ExistsStatus CheckExists(const std::string&) override { return ExistsStatus::Error; }
    bool Remove(const std::string&) override { return false; }
    std::vector<FileInfo> List(const std::string&) override { return {}; }
    void ResetCounts() { reads = writes = cnWrites = 0; }
};

static void SessionChecks() {
    MemoryProvider provider;
    AppState_Init(&provider);
    NoteOwnClientId(7);
    provider.state.cn = 42;
    provider.state.appBuildId = 123;
    provider.state.quota.quotaBytes = 1000000;
    FileEntry file; file.sha.assign(20, 0xab); file.size = 5; file.timestamp = 1234;
    provider.state.files["save.bin"] = file;
    SessionLock ours{7, "This Mac", 1700000000, "active"};
    auto result = AcquireCloudSession(4242, 620, ours, false);
    CHECK(result.status == SessionAcquireStatus::Acquired);
    CHECK(provider.reads == 1 && provider.writes == 1 && provider.cnWrites == 0);
    CHECK(provider.state.cn == 42 && provider.state.appBuildId == 123);
    CHECK(provider.state.files.at("save.bin").sha == file.sha);
    CHECK(provider.state.session.clientId == 7);
    // The just-written state remains available to the download/batch serve path.
    CHECK(FetchCloudStateForServe(4242, 620).state.session.clientId == 7);
    CHECK(provider.reads == 1);

    // A foreign device changing the cloud after the cached read must be noticed.
    provider.state.cn = 43;
    provider.state.files["new.bin"] = file;
    provider.state.session = {88, "Other device", 1700000001, "active"};
    provider.ResetCounts();
    result = AcquireCloudSession(4242, 620, ours, false);
    CHECK(result.status == SessionAcquireStatus::Conflict);
    CHECK(result.state.session.clientId == 88 && provider.reads == 1 && provider.writes == 0);
    result = AcquireCloudSession(4242, 620, ours, true);
    CHECK(result.status == SessionAcquireStatus::Acquired);
    CHECK(provider.state.cn == 43 && provider.state.files.count("new.bin"));
    CHECK(provider.state.session.clientId == 7 && provider.cnWrites == 0);

    provider.ResetCounts();
    ReleaseCloudSession(4242, 620, 88);
    CHECK(provider.reads == 1 && provider.writes == 0 && provider.state.session.clientId == 7);
    provider.ResetCounts();
    ReleaseCloudSession(4242, 620, 7);
    CHECK(provider.reads == 1 && provider.writes == 1 && provider.cnWrites == 0);
    CHECK(!provider.state.hasActiveSession() && provider.state.files.count("new.bin"));

    provider.failRead = true; provider.ResetCounts();
    CHECK(AcquireCloudSession(4242, 620, ours, false).status == SessionAcquireStatus::Failed);
    CHECK(provider.writes == 0);
    provider.failRead = false; provider.malformed = true;
    CHECK(AcquireCloudSession(4242, 620, ours, false).status == SessionAcquireStatus::Failed);
    CHECK(provider.writes == 0);
    provider.malformed = false; provider.failWrite = true;
    CHECK(AcquireCloudSession(4242, 620, ours, false).status == SessionAcquireStatus::Failed);
    CHECK(!provider.state.hasActiveSession());
    provider.failWrite = false;

    // A rapid relaunch must wait for the preceding save's deferred publication.
    std::promise<void> published;
    SetPendingPublish(4242, 620, published.get_future().share());
    provider.ResetCounts();
    auto launch = std::async(std::launch::async, [&] { return AcquireCloudSession(4242, 620, ours, false); });
    CHECK(launch.wait_for(std::chrono::milliseconds(20)) == std::future_status::timeout);
    provider.state.cn = 44;
    provider.state.files["just-saved.bin"] = file;
    published.set_value();
    CHECK(launch.get().status == SessionAcquireStatus::Acquired);
    CHECK(provider.state.cn == 44 && provider.state.files.count("just-saved.bin"));
    CHECK(provider.reads == 1 && provider.writes == 1 && provider.cnWrites == 0);
    auto old = provider.state; old.cn = 43;
    provider.ResetCounts();
    CHECK(!PublishCloudState(4242, 620, old, true));
    CHECK(provider.writes == 0 && provider.state.cn == 44);
    AppState_Shutdown();
}

static void PreparationChecks() {
    MemoryProvider provider;
    provider.state.cn = 100;
    FileEntry save; save.size = 123; save.sha.assign(20, 0xcd);
    provider.state.files["save.bin"] = save;
    AppState_Init(&provider);
    CloudIntercept::RegisterNamespaceApp(620);
    char pattern[] = "/tmp/cr-preparation-tests-XXXXXX";
    const auto dir = mkdtemp(pattern); CHECK(dir);
    const std::string root = dir;
    std::filesystem::create_directories(root + "/steam/logs");
    const auto logPath = root + "/steam/logs/console_log.txt";
    std::ofstream(logPath).close();
    struct Cleanup {
        std::string root;
        ~Cleanup() { LaunchPreparation::Shutdown(); AppState_Shutdown(); std::filesystem::remove_all(root); }
    } cleanup{root};
    LaunchPreparation::Start(root, root + "/steam", 4242);
    LaunchPreparation::RememberClient(7);
    std::this_thread::sleep_for(std::chrono::milliseconds(150));
    auto begin = [&] {
        std::ofstream(logPath, std::ios::app) << "GameAction [AppID 620, ActionID 1] : LaunchApp changed task to UpdatingAppTicket with \"\"\n";
    };
    auto prepared = [&] {
        const auto deadline = std::chrono::steady_clock::now() + std::chrono::seconds(3);
        while (std::chrono::steady_clock::now() < deadline) {
            if (auto state = LaunchPreparation::State(4242, 620)) return state;
            std::this_thread::sleep_for(std::chrono::milliseconds(10));
        }
        return std::optional<StateFetchResult>{};
    };
    begin();
    auto state = prepared(); CHECK(state && state->state.cn == 100);
    CHECK(provider.reads == 1 && provider.writes == 1 && provider.cnWrites == 0);
    const auto start = std::chrono::steady_clock::now();
    SessionLock ours{7, "This Mac", 1700000000, "active"};
    CHECK(AcquireCloudSession(4242, 620, ours, false).status == SessionAcquireStatus::Acquired);
    CHECK(std::chrono::steady_clock::now() - start < std::chrono::milliseconds(50));
    CHECK(provider.reads == 1 && provider.writes == 1); // zero network requests on launch
    ReleaseCloudSession(4242, 620, 7);
    provider.ResetCounts();
    begin(); state = prepared(); CHECK(state);
    // A different actual Steam client must cancel/release the old reservation
    // before attempting a new acquisition, never silently accept a stale identity.
    CHECK(!LaunchPreparation::Take(4242, 620, 8, false));
    CHECK(!provider.state.hasActiveSession() && provider.reads == 2 && provider.writes == 2);
    provider.ResetCounts();
    begin(); state = prepared(); CHECK(state);
    std::ofstream(logPath, std::ios::app) << "GameAction [AppID 620, ActionID 1] : LaunchApp changed task to Failed with \"canceled\"\n";
    const auto cancelDeadline = std::chrono::steady_clock::now() + std::chrono::seconds(3);
    while (LaunchPreparation::State(4242, 620) && std::chrono::steady_clock::now() < cancelDeadline)
        std::this_thread::sleep_for(std::chrono::milliseconds(10));
    CHECK(!provider.state.hasActiveSession());
    LaunchPreparation::Shutdown();
    LaunchPreparation::Start(root, root + "/steam", 4242); // restores locally learned client ID
    std::this_thread::sleep_for(std::chrono::milliseconds(150));
    begin(); state = prepared(); CHECK(state);
    LaunchPreparation::Shutdown();
    CHECK(!provider.state.hasActiveSession()); // canceled launch releases on shutdown
}

// A single accepted keep-alive socket must serve requests made on different
// caller threads. Echo them to check reset clears methods, bodies and auth.
static void TransportChecks() {
    const int listener = socket(AF_INET, SOCK_STREAM, 0); CHECK(listener >= 0);
    sockaddr_in address{}; address.sin_family = AF_INET; address.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    CHECK(bind(listener, reinterpret_cast<sockaddr*>(&address), sizeof(address)) == 0);
    CHECK(listen(listener, 4) == 0);
    socklen_t length = sizeof(address);
    CHECK(getsockname(listener, reinterpret_cast<sockaddr*>(&address), &length) == 0);
    std::string host = "127.0.0.1:" + std::to_string(ntohs(address.sin_port));
    std::thread server([&] {
        const int fd = accept(listener, nullptr, nullptr);
        if (fd < 0) return;
        timeval timeout{5, 0}; setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, sizeof(timeout));
        for (int request = 0; request < 3; ++request) {
            std::string wire;
            char buffer[4096];
            size_t end = std::string::npos, bodySize = 0;
            while (true) {
                const auto count = recv(fd, buffer, sizeof(buffer), 0);
                if (count <= 0) { close(fd); return; }
                wire.append(buffer, count);
                end = wire.find("\r\n\r\n");
                if (end == std::string::npos) continue;
                const auto header = wire.find("Content-Length: ");
                if (header != std::string::npos) bodySize = std::stoul(wire.substr(header + 16));
                if (wire.size() >= end + 4 + bodySize) break;
            }
            std::string response = "HTTP/1.1 200 OK\r\nContent-Length: " + std::to_string(wire.size()) +
                "\r\nConnection: keep-alive\r\n\r\n" + wire;
            size_t sent = 0;
            while (sent < response.size()) {
                const auto count = send(fd, response.data() + sent, response.size() - sent, 0);
                if (count <= 0) { close(fd); return; }
                sent += count;
            }
        }
        close(fd);
    });
    bool ok = false;
    {
        auto transport = CreateHttpTransport("[test]");
        TransportOptions opts; opts.allowInsecureHttp = true;
        transport->SetOptions(opts);
        auto first = transport->Request("PATCH", host.c_str(), "/upload", "save-data", {"Authorization: Bearer test-only"});
        auto second = std::async(std::launch::async, [&] { return transport->Request("GET", host.c_str(), "/public", {}, {}); }).get();
        auto third = transport->Request("GET", host.c_str(), "/last", {}, {"X-Test: fresh"});
        ok = first.status == 200 && first.body.find("save-data") != std::string::npos &&
            second.status == 200 && second.body.find("GET /public ") == 0 &&
            second.body.find("Authorization:") == std::string::npos &&
            second.body.find("save-data") == std::string::npos &&
            third.status == 200 && third.body.find("GET /last ") == 0 &&
            third.body.find("Authorization:") == std::string::npos;
    }
    shutdown(listener, SHUT_RDWR); close(listener); server.join();
    CHECK(ok);
}
int main() {
    try { SessionChecks(); PreparationChecks(); TransportChecks(); puts("Session conflicts, save barriers, request counts and connection reuse passed"); }
    catch (const std::exception& e) { fprintf(stderr, "FAIL: %s\n", e.what()); return 1; }
}
