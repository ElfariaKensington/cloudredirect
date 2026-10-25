#include "steam_kv_injector.h"
#include "log.h"
#include <dlfcn.h>
#include <atomic>
#include <mutex>
namespace SteamKvInjector {
static constexpr uint64_t kMaxPlausibleQuotaBytes=1024ULL*1024*1024*1024;
static constexpr uint64_t kMaxPlausibleMaxFiles=10000000;
static bool QuotaValueLooksValid(uint64_t q,uint64_t f){return q&&f&&q<=kMaxPlausibleQuotaBytes&&f<=kMaxPlausibleMaxFiles;}

using GetAppInfoFn = void* (*)(void* cache, uint32_t appId);
using GetSectionFn = void* (*)(void* appInfo, uint32_t sectionId);
using KvFindKeyFn = void* (*)(void* parent, const char* name, uint8_t bCreate, void* outChild);
using ReadConfigU64Fn = uint64_t (*)(void* cache, uint64_t appId, uint32_t sectionId, const char* keyName, uint64_t defaultVal);
using KvGetUint64Fn = uint64_t (*)(void* kvNode, uint64_t defaultVal, void* outStatus);
using KvGetIntFn = int (*)(void* kvNode, int defaultVal, void* outStatus);
using KvSetUint64Fn = void (*)(void* kvNode, uint64_t value);
using KvSetIntFn = void (*)(void* kvNode, int value);
using KvSetStringFn = void (*)(void* kvNode, const char* value);

struct Resolved {
    void** globalEnginePtrPtr = nullptr;
    GetAppInfoFn     getAppInfo = nullptr;
    GetSectionFn     getSection = nullptr;
    ReadConfigU64Fn  readConfigU64 = nullptr;
    KvFindKeyFn      kvFindKey = nullptr;
    KvGetUint64Fn    kvGetUint64 = nullptr;
    KvGetIntFn       kvGetInt = nullptr;
    KvSetUint64Fn    kvSetUint64 = nullptr;
    KvSetIntFn       kvSetInt = nullptr;
    KvSetStringFn    kvSetString = nullptr;
    uint32_t         appInfoCacheOffset = 0;
};

static Resolved g_r;
static ResolvedKvAddrs g_configured;
static std::atomic<bool> g_configuredSet{false};
static std::atomic<bool> g_ready{false};
static std::once_flag g_initOnce;

// sectionId 10 = "ufs" in the app config KV tree.
static constexpr uint32_t kSectionUfs = 10;

static void* GetCachePtr() {
    if (!g_r.globalEnginePtrPtr) return nullptr;
    void* engine = *g_r.globalEnginePtrPtr;
    if (!engine) return nullptr;
    return reinterpret_cast<uint8_t*>(engine) + g_r.appInfoCacheOffset;
}

void Configure(const ResolvedKvAddrs& addrs) {
    g_configured = addrs;
    g_configuredSet.store(true, std::memory_order_release);
}

bool Init() {
    bool success = false;
    std::call_once(g_initOnce, [&]() {
        if (!g_configuredSet.load(std::memory_order_acquire)) {
            LOG("[KvInjector] Init: Configure() not called; resolver addresses required");
            return;
        }

        const ResolvedKvAddrs& c = g_configured;
        if (!c.globalEnginePtrPtr || !c.getAppInfo || !c.getSection ||
            !c.readConfigU64 || !c.kvFindKey || !c.kvGetUint64 || !c.kvGetInt ||
            !c.kvSetUint64 || !c.kvSetInt || !c.kvSetString || !c.appInfoCacheOffset) {
            LOG("[KvInjector] Init: resolver supplied incomplete addresses "
                "(engine=%p getAppInfo=0x%llX getSection=0x%llX readCfg=0x%llX "
                "find=0x%llX getU64=0x%llX getInt=0x%llX setU64=0x%llX setInt=0x%llX "
                "setStr=0x%llX cacheOff=0x%X); aborting",
                c.globalEnginePtrPtr, (uint64_t)c.getAppInfo, (uint64_t)c.getSection,
                (uint64_t)c.readConfigU64, (uint64_t)c.kvFindKey, (uint64_t)c.kvGetUint64,
                (uint64_t)c.kvGetInt, (uint64_t)c.kvSetUint64, (uint64_t)c.kvSetInt,
                (uint64_t)c.kvSetString, c.appInfoCacheOffset);
            return;
        }

        g_r.globalEnginePtrPtr = c.globalEnginePtrPtr;
        g_r.getAppInfo    = reinterpret_cast<GetAppInfoFn>(c.getAppInfo);
        g_r.getSection    = reinterpret_cast<GetSectionFn>(c.getSection);
        g_r.readConfigU64 = reinterpret_cast<ReadConfigU64Fn>(c.readConfigU64);
        g_r.kvFindKey     = reinterpret_cast<KvFindKeyFn>(c.kvFindKey);
        g_r.kvGetUint64   = reinterpret_cast<KvGetUint64Fn>(c.kvGetUint64);
        g_r.kvGetInt      = reinterpret_cast<KvGetIntFn>(c.kvGetInt);
        g_r.kvSetUint64   = reinterpret_cast<KvSetUint64Fn>(c.kvSetUint64);
        g_r.kvSetInt      = reinterpret_cast<KvSetIntFn>(c.kvSetInt);
        g_r.kvSetString   = reinterpret_cast<KvSetStringFn>(c.kvSetString);
        g_r.appInfoCacheOffset = c.appInfoCacheOffset;

        Dl_info info{};
        if (!dladdr((const void*)g_r.getAppInfo, &info)) return;

        LOG("[KvInjector] Init: using resolver addresses (engine global @ %p, cacheOff 0x%X)",
            g_r.globalEnginePtrPtr, g_r.appInfoCacheOffset);
        g_ready.store(true, std::memory_order_release);
        success = true;
    });
    return success || g_ready.load(std::memory_order_acquire);
}

bool IsReady() {
    return g_ready.load(std::memory_order_acquire);
}

bool ReadAppQuota(uint32_t appId, uint64_t& outQuotaBytes, uint32_t& outMaxNumFiles) {
    if (!g_ready.load(std::memory_order_acquire)) return false;

    void* cache = GetCachePtr();
    if (!cache) return false;

    uint64_t quota = g_r.readConfigU64(cache, appId, kSectionUfs, "quota", 0);
    uint64_t files = g_r.readConfigU64(cache, appId, kSectionUfs, "maxnumfiles", 0);

    if (!QuotaValueLooksValid(quota, files)) {
        if (quota != 0 || files != 0) {
            LOG("[KvInjector] ReadAppQuota app=%u: implausible quota=%llu files=%llu",
                appId, (unsigned long long)quota, (unsigned long long)files);
        }
        outQuotaBytes = 0;
        outMaxNumFiles = 0;
        return true;
    }

    outQuotaBytes  = quota;
    outMaxNumFiles = static_cast<uint32_t>(files);
    return true;
}

bool InjectAppQuota(uint32_t appId, uint64_t quotaBytes, uint32_t maxNumFiles) {
    if (!g_ready.load(std::memory_order_acquire)) return false;
    if (quotaBytes == 0 || maxNumFiles == 0) {
        LOG("[KvInjector] InjectAppQuota app=%u: refusing zero values "
            "(quota=%llu files=%u)",
            appId, (unsigned long long)quotaBytes, maxNumFiles);
        return false;
    }

    void* cache = GetCachePtr();
    if (!cache) {
        LOG("[KvInjector] InjectAppQuota app=%u: cache pointer null", appId);
        return false;
    }

    void* appInfo = g_r.getAppInfo(cache, appId);
    if (!appInfo) {
        LOG("[KvInjector] InjectAppQuota app=%u: no app info entry "
            "(PICS has never returned for this app)", appId);
        return false;
    }

    void* ufs = g_r.getSection(appInfo, kSectionUfs);
    if (!ufs) {
        LOG("[KvInjector] InjectAppQuota app=%u: ufs section missing "
            "(app config has no cloud config at all)", appId);
        // No ufs section -> AutoCloud short-circuits with "no config data"; saves stay intact
        return false;
    }

    // Preserve Steam's PICS values only if plausible; overwrite garbage.
    uint64_t existingQuota = g_r.readConfigU64(cache, appId, kSectionUfs, "quota", 0);
    uint64_t existingFiles = g_r.readConfigU64(cache, appId, kSectionUfs, "maxnumfiles", 0);
    bool existingValid = QuotaValueLooksValid(existingQuota, existingFiles);

    bool wroteQuota = false;
    bool wroteFiles = false;

    bool quotaNeedsWrite = (existingQuota == 0) ||
                           (existingQuota > kMaxPlausibleQuotaBytes) || !existingValid;
    bool filesNeedsWrite = (existingFiles == 0) ||
                           (existingFiles > kMaxPlausibleMaxFiles) || !existingValid;

    if (quotaNeedsWrite) {
        void* quotaKv = g_r.kvFindKey(ufs, "quota", 1, nullptr);
        if (quotaKv) {
            g_r.kvSetUint64(quotaKv, quotaBytes);
            wroteQuota = true;
        }
    }
    if (filesNeedsWrite) {
        void* filesKv = g_r.kvFindKey(ufs, "maxnumfiles", 1, nullptr);
        if (filesKv) {
            g_r.kvSetInt(filesKv, static_cast<int>(maxNumFiles));
            wroteFiles = true;
        }
    }

    if (wroteQuota || wroteFiles) {
        LOG("[KvInjector] InjectAppQuota app=%u: injected quota=%llu files=%u "
            "(wroteQuota=%d wroteFiles=%d, existingQuota=%llu existingFiles=%llu)",
            appId, (unsigned long long)quotaBytes, maxNumFiles,
            wroteQuota ? 1 : 0, wroteFiles ? 1 : 0,
            (unsigned long long)existingQuota, (unsigned long long)existingFiles);
    } else {
        LOG("[KvInjector] InjectAppQuota app=%u: skipped (Steam already has "
            "quota=%llu files=%llu)", appId,
            (unsigned long long)existingQuota, (unsigned long long)existingFiles);
    }
    return true;
}

bool EnsureMaxNumFilesFloor(uint32_t appId, uint32_t floorFiles, uint64_t floorBytes) {
    if (!g_ready.load(std::memory_order_acquire)) return false;
    if (floorFiles == 0) return false;
    if (floorFiles > kMaxPlausibleMaxFiles) return false;  // guard pathological input

    void* cache = GetCachePtr();
    if (!cache) return false;
    void* appInfo = g_r.getAppInfo(cache, appId);
    if (!appInfo) return false;
    void* ufs = g_r.getSection(appInfo, kSectionUfs);
    if (!ufs) return false;

    uint64_t curFiles = g_r.readConfigU64(cache, appId, kSectionUfs, "maxnumfiles", 0);
    uint64_t curQuota = g_r.readConfigU64(cache, appId, kSectionUfs, "quota", 0);

    bool wrote = false;
    if (curFiles < floorFiles) {
        void* filesKv = g_r.kvFindKey(ufs, "maxnumfiles", 1, nullptr);
        if (filesKv) {
            g_r.kvSetInt(filesKv, static_cast<int>(floorFiles));
            wrote = true;
            LOG("[KvInjector] EnsureMaxNumFilesFloor app=%u: raised maxnumfiles %llu -> %u",
                appId, (unsigned long long)curFiles, floorFiles);
        }
    }
    // Cap (not skip): floorBytes derives from real PICS facts; silently dropping
    // the quota raise while still raising maxnumfiles would reopen byte-quota
    // eviction in exactly the multi-root scenario the floor protects.
    if (floorBytes > kMaxPlausibleQuotaBytes) floorBytes = kMaxPlausibleQuotaBytes;
    if (floorBytes > 0 && curQuota < floorBytes) {
        void* quotaKv = g_r.kvFindKey(ufs, "quota", 1, nullptr);
        if (quotaKv) {
            g_r.kvSetUint64(quotaKv, floorBytes);
            wrote = true;
            LOG("[KvInjector] EnsureMaxNumFilesFloor app=%u: raised quota %llu -> %llu",
                appId, (unsigned long long)curQuota, (unsigned long long)floorBytes);
        }
    }
    return wrote;
}

bool InjectSaveFiles(uint32_t appId, const std::vector<SaveFileRule>& rules) {
    if (!g_ready.load(std::memory_order_acquire)) return false;
    if (rules.empty()) return false;

    void* cache = GetCachePtr();
    if (!cache) {
        LOG("[KvInjector] InjectSaveFiles app=%u: cache pointer null", appId);
        return false;
    }

    void* appInfo = g_r.getAppInfo(cache, appId);
    if (!appInfo) {
        LOG("[KvInjector] InjectSaveFiles app=%u: no app info entry", appId);
        return false;
    }

    void* ufs = g_r.getSection(appInfo, kSectionUfs);
    if (!ufs) {
        LOG("[KvInjector] InjectSaveFiles app=%u: ufs section missing", appId);
        return false;
    }

    // Check if savefiles already exists with children. If so, don't clobber.
    void* existing = g_r.kvFindKey(ufs, "savefiles", 0, nullptr);
    if (existing) {
        // KV node exists -- check if it has children by trying to find child "0"
        void* child0 = g_r.kvFindKey(existing, "0", 0, nullptr);
        if (child0) {
            LOG("[KvInjector] InjectSaveFiles app=%u: savefiles already populated, skipping",
                appId);
            return true;
        }
    }

    // Create or get the savefiles subsection
    void* savefiles = g_r.kvFindKey(ufs, "savefiles", 1, nullptr);
    if (!savefiles) {
        LOG("[KvInjector] InjectSaveFiles app=%u: failed to create savefiles key", appId);
        return false;
    }

    int injected = 0;
    for (size_t i = 0; i < rules.size(); ++i) {
        const auto& rule = rules[i];
        std::string idxStr = std::to_string(i);

        // Create numbered subsection: savefiles/"0", savefiles/"1", etc.
        void* entry = g_r.kvFindKey(savefiles, idxStr.c_str(), 1, nullptr);
        if (!entry) continue;

        // Set root
        void* rootKv = g_r.kvFindKey(entry, "root", 1, nullptr);
        if (rootKv) g_r.kvSetString(rootKv, rule.root.c_str());

        // Set path
        if (!rule.path.empty()) {
            void* pathKv = g_r.kvFindKey(entry, "path", 1, nullptr);
            if (pathKv) g_r.kvSetString(pathKv, rule.path.c_str());
        }

        // Set pattern
        void* patternKv = g_r.kvFindKey(entry, "pattern", 1, nullptr);
        if (patternKv) g_r.kvSetString(patternKv, rule.pattern.c_str());

        // Set recursive (only if true, since Steam defaults to false)
        if (rule.recursive) {
            void* recursiveKv = g_r.kvFindKey(entry, "recursive", 1, nullptr);
            if (recursiveKv) g_r.kvSetInt(recursiveKv, 1);
        }

        // Set platforms (only if not all-platforms)
        if (rule.platforms != 0xFFFFFFFFu) {
            void* platformsKv = g_r.kvFindKey(entry, "platforms", 1, nullptr);
            if (platformsKv) {
                // Steam iterates "platforms" children as named strings ("windows", "macos", etc.).
                if (rule.platforms & 1) {
                    void* k = g_r.kvFindKey(platformsKv, "1", 1, nullptr);
                    if (k) g_r.kvSetString(k, "windows");
                }
                if (rule.platforms & 2) {
                    void* k = g_r.kvFindKey(platformsKv, "2", 1, nullptr);
                    if (k) g_r.kvSetString(k, "macos");
                }
                if (rule.platforms & 8) {
                    void* k = g_r.kvFindKey(platformsKv, "3", 1, nullptr);
                    if (k) g_r.kvSetString(k, "linux");
                }
            }
        }

        ++injected;
    }

    LOG("[KvInjector] InjectSaveFiles app=%u: injected %d savefiles rules", appId, injected);
    return injected > 0;
}


void** GetEngineGlobalPtr(){ return g_r.globalEnginePtrPtr; }
}
