#include "launch_preparation.h"
#include "cloud_intercept.h"
#include "autocloud_scan.h"
#include "file_util.h"
#include "json.h"
#include "log.h"
#include <atomic>
#include <charconv>
#include <chrono>
#include <condition_variable>
#include <cstring>
#include <filesystem>
#include <fstream>
#include <map>
#include <mutex>
#include <thread>
#include <unistd.h>
namespace LaunchPreparation {
namespace {
struct Entry {
    uint32_t app = 0;
    uint64_t client = 0, action = 0;
    bool claimed = false, canceled = false;
    std::condition_variable changed;
    std::promise<CloudStorage::SessionAcquireResult> result;
    std::shared_future<CloudStorage::SessionAcquireResult> ready = result.get_future().share();
    std::promise<void> finished;
    std::shared_future<void> done = finished.get_future().share();
};
std::mutex mutex;
std::atomic<bool> stopping{true};
std::atomic<uint64_t> ownClient{0};
uint32_t account = 0;
std::string clientPath, steamRoot;
std::mutex startupMutex;
std::thread startupWarm;
bool startupStarted = false;
std::map<uint32_t, std::shared_ptr<Entry>> entries;
std::thread watcher;
std::vector<std::pair<std::shared_future<void>, std::thread>> workers;

void Prepare(uint32_t app, uint64_t action) {
    const auto client = ownClient.load();
    LOG("[LaunchPrep] early launch app=%u (known-client=%d, selected=%d)", app, client != 0, CloudIntercept::IsNamespaceApp(app));
    if (!client || !CloudIntercept::IsNamespaceApp(app)) return;
    std::lock_guard<std::mutex> lock(mutex);
    if (stopping) return;
    std::shared_ptr<Entry> previous;
    if (auto it = entries.find(app); it != entries.end()) {
        if (it->second->action == action) return;
        previous = it->second;
        previous->canceled = true;
        previous->changed.notify_all();
    }
    auto entry = std::make_shared<Entry>(); entry->app = app; entry->client = client; entry->action = action;
    entries[app] = entry;
    workers.emplace_back(entry->done, std::thread([entry, previous] {
        if (previous) previous->done.wait();
        auto started = std::chrono::steady_clock::now();
        CloudStorage::SessionAcquireResult result;
        bool run;
        { std::lock_guard<std::mutex> lock(mutex); run = !stopping && !entry->canceled; }
        if (run) try {
            char host[256] = {};
            gethostname(host, sizeof(host) - 1);
            CloudStorage::SessionLock session{entry->client, host,
                static_cast<uint64_t>(time(nullptr)), "active"};
            result = CloudStorage::AcquireCloudSession(account, entry->app, session,
                                                       false, /*allowPrepared=*/false);
        } catch (...) {}
        const bool acquired = result.status == CloudStorage::SessionAcquireStatus::Acquired;
        entry->result.set_value(std::move(result));
        LOG("[LaunchPrep] app=%u prepared in %lldms (acquired=%d)", entry->app,
            (long long)std::chrono::duration_cast<std::chrono::milliseconds>(
                std::chrono::steady_clock::now() - started).count(), acquired);
        bool release = false;
        {
            std::unique_lock<std::mutex> lock(mutex);
            entry->changed.wait_for(lock, std::chrono::seconds(90), [&] {
                return entry->claimed || entry->canceled || stopping;
            });
            release = acquired && !entry->claimed;
            if (!entry->claimed) entry->canceled = true;
        }
        // Canceled/failed launches must never leave a remote game-running lock.
        if (release) {
            try { CloudStorage::ReleaseCloudSession(account, entry->app, entry->client); }
            catch (...) {}
        }
        {
            std::lock_guard<std::mutex> lock(mutex);
            auto it = entries.find(entry->app);
            if (it != entries.end() && it->second == entry) entries.erase(it);
        }
        entry->finished.set_value();
    }));
}

std::shared_ptr<Entry> Find(uint32_t requestedAccount, uint32_t app) {
    if (requestedAccount != account || stopping) return {};
    std::lock_guard<std::mutex> lock(mutex);
    const auto it = entries.find(app);
    return it == entries.end() ? nullptr : it->second;
}
}

void WarmStartup(uint32_t requestedAccount, uint32_t firstApp) {
    if (stopping || requestedAccount != account) return;
    std::lock_guard<std::mutex> lock(startupMutex);
    if (stopping || startupStarted) return;
    startupStarted = true;
    startupWarm = std::thread([firstApp] {
        const auto started = std::chrono::steady_clock::now();
        std::vector<uint32_t> apps{firstApp};
        for (const auto app : CloudIntercept::GetNamespaceApps())
            if (app != firstApp && AutoCloudScan::IsAppInstalled(steamRoot, app)) apps.push_back(app);
        std::atomic<size_t> next{0};
        auto fetch = [&] {
            while (!stopping) {
                const auto index = next.fetch_add(1);
                if (index >= apps.size()) break;
                CloudStorage::FetchCloudStateBounded(account, apps[index], 12000);
            }
        };
        std::vector<std::thread> pool;
        for (size_t i = 1; i < std::min<size_t>(4, apps.size()); ++i) pool.emplace_back(fetch);
        fetch();
        for (auto& worker : pool) worker.join();
        LOG("[StartupSync] Prepared %zu installed game inventories in %lldms", apps.size(),
            (long long)std::chrono::duration_cast<std::chrono::milliseconds>(
                std::chrono::steady_clock::now() - started).count());
    });
}

void RememberClient(uint64_t client) {
    if (!client || stopping || ownClient.exchange(client) == client) return;
    auto value = Json::Object();
    value.objVal["account"] = Json::Number(account);
    // Client IDs can exceed JSON's exact floating-point integer range.
    value.objVal["client"] = Json::String(std::to_string(client));
    FileUtil::AtomicWriteText(clientPath, Json::Stringify(value));
}

std::optional<CloudStorage::StateFetchResult> State(uint32_t requestedAccount, uint32_t app) {
    auto entry = Find(requestedAccount, app);
    if (!entry) return {};
    bool canceled;
    {
        std::lock_guard<std::mutex> lock(mutex);
        canceled = entry->canceled;
    }
    if (canceled) { entry->done.wait(); return {}; }
    const auto result = entry->ready.get();
    if (result.status != CloudStorage::SessionAcquireStatus::Acquired) return {};
    LOG("[LaunchPrep] app=%u using reserved cloud state for launch sync", app);
    return CloudStorage::StateFetchResult{CloudStorage::StateFetchStatus::Ok, result.state};
}

std::optional<CloudStorage::SessionAcquireResult> Take(uint32_t requestedAccount, uint32_t app,
                                                      uint64_t client, bool force) {
    auto entry = Find(requestedAccount, app);
    if (!entry) return {};
    bool cancel;
    {
        std::lock_guard<std::mutex> lock(mutex);
        cancel = entry->canceled || entry->client != client;
        if (cancel) entry->canceled = true;
        else { entry->claimed = true; entries.erase(app); }
        entry->changed.notify_all();
    }
    if (cancel) { entry->done.wait(); return {}; }
    auto result = entry->ready.get();
    if (force && result.status != CloudStorage::SessionAcquireStatus::Acquired) return {};
    LOG("[LaunchPrep] app=%u consumed prepared session", app);
    return result;
}

void Start(const std::string& root, const std::string& steam, uint32_t currentAccount) {
    if (!stopping.exchange(false)) return;
    account = currentAccount;
    steamRoot = steam;
    startupStarted = false;
    clientPath = root + "/launch-client.json";
    std::ifstream saved(clientPath);
    std::string json((std::istreambuf_iterator<char>(saved)), {});
    const auto value = Json::Parse(json);
    if (value["account"].integer() == currentAccount) {
        try { ownClient = std::stoull(value["client"].str()); } catch (...) {}
    }
    if (auto client = ownClient.load()) CloudStorage::NoteOwnClientId(client);
    watcher = std::thread([steam] {
        const std::string path = steam + "/logs/console_log.txt";
        std::error_code initialError;
        uint64_t offset = std::filesystem::file_size(path, initialError);
        if (initialError) offset = 0;
        std::string pending;
        std::map<uint32_t, uint64_t> seenActions;
        while (!stopping) {
            std::error_code ec;
            const auto size = std::filesystem::file_size(path, ec);
            if (!ec && size < offset) { offset = 0; pending.clear(); }
            if (!ec && size > offset) {
                std::ifstream log(path);
                log.seekg(offset);
                std::string chunk((std::istreambuf_iterator<char>(log)), {});
                offset += chunk.size();
                pending += chunk;
            }
            size_t newline;
            while ((newline = pending.find('\n')) != std::string::npos) {
                std::string line = pending.substr(0, newline);
                pending.erase(0, newline + 1);
                const auto start = line.find("GameAction [AppID ");
                if (start == std::string::npos) continue;
                uint32_t app = 0;
                const auto id = start + strlen("GameAction [AppID ");
                if (std::from_chars(line.data() + id, line.data() + line.size(), app).ec != std::errc()) continue;
                const auto actionPosition = line.find(", ActionID ", id);
                if (actionPosition == std::string::npos) continue;
                uint64_t action = 0;
                if (std::from_chars(line.data() + actionPosition + strlen(", ActionID "),
                    line.data() + line.size(), action).ec != std::errc()) continue;
                const bool early = line.find("LaunchApp changed task to UpdatingAppTicket") != std::string::npos ||
                    line.find("LaunchApp changed task to UpdatingAppInfo") != std::string::npos ||
                    line.find("LaunchApp changed task to ShowLaunchOption") != std::string::npos ||
                    line.find("LaunchApp changed task to ProcessingInstallScript") != std::string::npos ||
                    line.find("LaunchApp changed task to SynchronizingCloud") != std::string::npos;
                if (early) {
                    // Cached tickets skip UpdatingAppTicket entirely. Observe the
                    // first available stage, exactly once per launch action.
                    auto seen = seenActions.find(app);
                    if (seen == seenActions.end() || seen->second != action) {
                        seenActions[app] = action;
                        Prepare(app, action);
                    }
                } else if (line.find("LaunchApp") != std::string::npos &&
                         (line.find("Failed") != std::string::npos || line.find("Cancelled") != std::string::npos || line.find("Canceled") != std::string::npos)) {
                    if (auto entry = Find(account, app)) {
                        std::lock_guard<std::mutex> lock(mutex);
                        if (entry->action == action) {
                            entry->canceled = true; entry->changed.notify_all();
                        }
                    }
                }
            }
            for (auto it = workers.begin(); it != workers.end();) {
                if (it->first.wait_for(std::chrono::seconds(0)) == std::future_status::ready) {
                    if (it->second.joinable()) it->second.join();
                    it = workers.erase(it);
                } else ++it;
            }
            std::this_thread::sleep_for(std::chrono::milliseconds(100));
        }
    });
}
void Shutdown() {
    stopping = true;
    if (watcher.joinable()) watcher.join();
    {
        std::lock_guard<std::mutex> lock(startupMutex);
        if (startupWarm.joinable()) startupWarm.join();
    }
    {
        std::lock_guard<std::mutex> lock(mutex);
        for (auto& [app, entry] : entries) entry->changed.notify_all();
    }
    for (auto& worker : workers) if (worker.second.joinable()) worker.second.join();
    workers.clear(); entries.clear(); ownClient = 0;
}
}
