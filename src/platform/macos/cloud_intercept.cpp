#include "cloud_intercept.h"
#include "json.h"
#include "log.h"
#include "xdg.h"
#include "lua_namespace.h"
#include <atomic>
#include <fstream>
#include <mutex>
#include <unordered_set>
#include <algorithm>
static std::mutex g_mutex;
static std::string g_steamPath;
static std::atomic<uint32_t> g_accountId{0};
static std::unordered_set<uint32_t> g_apps;
static std::string DetectSteamPath() {
    const char* path=getenv("CLOUDREDIRECT_STEAM_HOME");
    std::string result=path&&path[0]=='/'?path:XdgHome()+"/Library/Application Support/Steam/";
    if(!result.empty()&&result.back()!='/')result+='/';return result;
}
static uint32_t LoadAccountIdFromLoginUsers() {
    std::string steamPath = DetectSteamPath();
    std::string vdfPath = steamPath + "config/loginusers.vdf";

    std::ifstream f(vdfPath);
    if (!f) {
        LOG("[macOS] Cannot open loginusers.vdf at %s", vdfPath.c_str());
        return 0;
    }

    std::string line;
    uint64_t mostRecentSteamId = 0;
    uint64_t autoLoginSteamId = 0;
    uint64_t newestTimestampSteamId = 0;
    uint64_t newestTimestamp = 0;
    uint64_t currentSteamId = 0;
    bool inUser = false;
    int braceDepth = 0;

    while (std::getline(f, line)) {
        // Trim
        size_t start = line.find_first_not_of(" \t\r\n");
        if (start == std::string::npos) continue;
        std::string trimmed = line.substr(start);

        if (trimmed == "{") {
            braceDepth++;
            continue;
        }
        if (trimmed == "}") {
            braceDepth--;
            if (braceDepth == 1) inUser = false;
            continue;
        }

        // At depth 1, look for SteamID64 keys (quoted numbers)
        if (braceDepth == 1 && trimmed.size() > 2 && trimmed[0] == '"') {
            size_t endQuote = trimmed.find('"', 1);
            if (endQuote != std::string::npos) {
                std::string key = trimmed.substr(1, endQuote - 1);
                // Check if it's a numeric SteamID64
                char* endp = nullptr;
                uint64_t sid = strtoull(key.c_str(), &endp, 10);
                if (endp == key.c_str() + key.size() && sid > 76561197960265728ULL) {
                    currentSteamId = sid;
                    inUser = true;
                }
            }
        }

        // At depth 2, look for selection markers
        if (inUser && braceDepth == 2) {
            if (trimmed.find("\"MostRecent\"") != std::string::npos &&
                trimmed.find("\"1\"") != std::string::npos) {
                mostRecentSteamId = currentSteamId;
            }
            if (trimmed.find("\"AutoLogin\"") != std::string::npos &&
                trimmed.find("\"1\"") != std::string::npos) {
                autoLoginSteamId = currentSteamId;
            }
            static const std::string kTimestamp = "\"Timestamp\"";
            if (trimmed.find(kTimestamp) != std::string::npos) {
                size_t vStart = trimmed.find('"', trimmed.find(kTimestamp) + kTimestamp.size());
                if (vStart != std::string::npos) {
                    size_t vEnd = trimmed.find('"', vStart + 1);
                    if (vEnd != std::string::npos) {
                        std::string tsStr = trimmed.substr(vStart + 1, vEnd - vStart - 1);
                        char* endp = nullptr;
                        uint64_t ts = strtoull(tsStr.c_str(), &endp, 10);
                        if (endp == tsStr.c_str() + tsStr.size() && ts > newestTimestamp) {
                            newestTimestamp = ts;
                            newestTimestampSteamId = currentSteamId;
                        }
                    }
                }
            }
        }
    }

    // Priority: MostRecent > AutoLogin > highest Timestamp
    uint64_t selected = mostRecentSteamId;
    const char* method = "MostRecent";
    if (selected == 0) {
        selected = autoLoginSteamId;
        method = "AutoLogin";
    }
    if (selected == 0) {
        selected = newestTimestampSteamId;
        method = "Timestamp";
    }

    if (selected == 0) {
        LOG("[macOS] No user found in loginusers.vdf (tried MostRecent, AutoLogin, Timestamp)");
        return 0;
    }

    uint32_t accountId = (uint32_t)(selected & 0xFFFFFFFF);
    LOG("[macOS] Bootstrapped accountId=%u from SteamID64=%llu via %s (loginusers.vdf)",
        accountId, (unsigned long long)selected, method);
    return accountId;
}

// ── Public API ──────────────────────────────────────────────────────────
namespace CloudIntercept {
void InitLinux() { // Common API name retained; implementation is native macOS.
    std::lock_guard<std::mutex> lock(g_mutex);
    g_steamPath=DetectSteamPath();
    g_accountId=LoadAccountIdFromLoginUsers();
    std::ifstream f(XdgConfigHome()+"/CloudRedirect/config.json");
    std::string text((std::istreambuf_iterator<char>(f)),{});
    auto cfg=Json::Parse(text);
    g_apps.clear();
    for(auto id:LuaNamespace::Discover(g_steamPath+"config/stplug-in"))g_apps.insert(id);
    for(auto& app:cfg["apps"].arrVal) {
        auto id=app.integer(); if(id>0 && id<=0xffffff)g_apps.insert((uint32_t)id);
    }
}
bool IsNamespaceApp(uint32_t appId) { std::lock_guard<std::mutex> lock(g_mutex); return g_apps.count(appId); }
bool HasNamespaceApps(){ std::lock_guard<std::mutex> lock(g_mutex); return !g_apps.empty(); }
std::vector<uint32_t> GetNamespaceApps(){ std::lock_guard<std::mutex> lock(g_mutex); return {g_apps.begin(),g_apps.end()}; }
void RegisterNamespaceApp(uint32_t appId){ if(appId){std::lock_guard<std::mutex> lock(g_mutex);g_apps.insert(appId);} }
std::string GetSteamPath(){ std::lock_guard<std::mutex> lock(g_mutex); return g_steamPath.empty()?DetectSteamPath():g_steamPath; }
void SetSteamPath(const std::string& path){std::lock_guard<std::mutex> lock(g_mutex);g_steamPath=path;if(!g_steamPath.empty()&&g_steamPath.back()!='/')g_steamPath+='/';}
uint32_t GetAccountId(){ return g_accountId; }
void SetAccountId(uint32_t id){g_accountId=id;}
void Shutdown() {}
}
struct CrashContext { const char* hook=nullptr; const char* method=nullptr; uint32_t app=0; };
thread_local CrashContext g_crashContext;
extern "C" void CR_SetCrashContext(const char* hook,const char* method,uint32_t app) {g_crashContext={hook,method,app};}
extern "C" void CR_ClearCrashContext() {g_crashContext={};}
