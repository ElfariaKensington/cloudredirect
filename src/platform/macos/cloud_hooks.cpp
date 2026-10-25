#include "cloud_hooks.h"
#include "cloud_intercept.h"

#include "metadata_sync.h"
#include "rpc_handlers.h"
#include "app_state.h"
#include "local_storage.h"
#include "pending_ops_journal.h"
#include "cloud_storage.h"
#include "cloud_provider.h"
#include "cloud_provider_base.h" // g_uploadInFlightCapBytes
#include "http_server.h"
#include "protobuf.h"
#include "json.h"
#include "log.h"
#include "xdg.h"
#include "native_profile.h"
#include "native_stats.h"
#include "native_lua.h"
#include "live_playtime.h"
#include "stats_handlers.h"
#include "stats_hooks.h"

#include <cstring>
#include <climits>
#include <fstream>
#include <atomic>
#include <mutex>
#include <optional>
#include <setjmp.h>
#include <signal.h>
#include <thread>
#include <vector>
#include <unistd.h>
#include <chrono>
#include <condition_variable>

// Native ARM64 member-call ABI.
using BYieldingSend_t     = int(*)(void* pThis, const char* method, void* req, void* resp, int* flags);
using NotificationDirect_t = int(*)(void* pThis, const char* method, void* body, int* flags);
using SyncSend2_t         = int(*)(void* pThis, const char* method, void* buf, unsigned int bufLen, void* resp, int* flags);

static std::atomic<BYieldingSend_t>      g_origBYieldingSend{nullptr};
static std::atomic<NotificationDirect_t> g_origNotificationDirect{nullptr};
static std::atomic<SyncSend2_t>          g_origSyncSend2{nullptr};

static std::atomic<bool> g_initialized{false};
static std::atomic<bool> g_redirectEnabled{false};
static std::atomic<bool> g_shuttingDown{false};
static std::atomic<int>  g_hookRefCount{0};


struct HookGuard {
    HookGuard() { g_hookRefCount.fetch_add(1, std::memory_order_acquire); }
    ~HookGuard() { g_hookRefCount.fetch_sub(1, std::memory_order_release); }
};

extern "C" void CR_SetCrashContext(const char* hook, const char* method, uint32_t appId);
extern "C" void CR_ClearCrashContext();

class CrashContextScope {
public:
    CrashContextScope(const char* hook, const char* method, uint32_t appId) {
        CR_SetCrashContext(hook, method, appId);
    }

    ~CrashContextScope() {
        CR_ClearCrashContext();
    }
};

// CProtoBufMsg vtable layout on 32-bit GCC Linux (google::protobuf::MessageLite):
//   slot[5]  (+20): Clear()
//   slot[9]  (+36): ByteSizeLong() -> int
//   slot[10] (+40): GetCachedSize() -> int
//
// Standalone functions found by signature scan:
//   SerializeToArray(msg, buffer) -> uint8_t* (end pointer)
//   ParseFromArray(msg, data, len) -> int (success)

using SerializeToArray_t = void*(*)(void* msg, void* buffer);
using ParseFromArray_t   = int(*)(void* msg, const void* data, int len);

static SerializeToArray_t g_serializeToArray = nullptr;
static ParseFromArray_t   g_parseFromArray   = nullptr;

bool CloudHooks::ResolveProtobufHelpers(void*,size_t) {
    MacProfile::Profile p;std::string error;
    if(!MacProfile::Resolve(p,error)||!MacProfile::TestProtobuf(p,error)){LOG("[macOS] %s",error.c_str());return false;}
    g_serializeToArray=p.serialize;g_parseFromArray=p.parse;return true;
}

static std::vector<uint8_t> SerializeMessage(void* msg) {
    if (!msg || !g_serializeToArray) return {};

    // vtable[9] = ByteSizeLong (offset +36 on 32-bit)
    uintptr_t* vtable = *(uintptr_t**)msg;
    if (!vtable || !vtable[9]) return {};
    using ByteSizeFn = int(*)(void*);
    int size = ((ByteSizeFn)vtable[9])(msg);
    if (size <= 0 || size > 64 * 1024 * 1024) return {};

    std::vector<uint8_t> buf(size);
    g_serializeToArray(msg, buf.data());
    return buf;
}

static bool ParseIntoMessage(void* msg, const uint8_t* data, size_t len) {
    if (!msg || !g_parseFromArray || !data || len == 0) return false;
    if (len > (size_t)INT_MAX) return false;
    return g_parseFromArray(msg, data, (int)len) != 0;
}

static std::optional<CloudIntercept::RpcResult> DispatchCloudRpc(
    const char* method, uint32_t appId, const std::vector<PB::Field>& reqBody) {
    using namespace CloudIntercept;
    if (strcmp(method, RPC_GET_CHANGELIST) == 0)    return HandleGetChangelist(appId, reqBody);
    if (strcmp(method, RPC_LAUNCH_INTENT) == 0)     return HandleLaunchIntent(appId, reqBody);
    if (strcmp(method, RPC_SUSPEND_SESSION) == 0)   return HandleSuspendSession(appId, reqBody);
    if (strcmp(method, RPC_RESUME_SESSION) == 0)    return HandleResumeSession(appId, reqBody);
    if (strcmp(method, RPC_QUOTA_USAGE) == 0)       return HandleQuotaUsage(appId, reqBody);
    if (strcmp(method, RPC_BEGIN_BATCH) == 0)       return HandleBeginBatch(appId, reqBody);
    if (strcmp(method, RPC_BEGIN_UPLOAD) == 0)      return HandleBeginFileUpload(appId, reqBody);
    if (strcmp(method, RPC_COMMIT_UPLOAD) == 0)     return HandleCommitFileUpload(appId, reqBody);
    if (strcmp(method, RPC_COMPLETE_BATCH) == 0)    return HandleCompleteBatch(appId, reqBody);
    if (strcmp(method, RPC_FILE_DOWNLOAD) == 0)     return HandleFileDownload(appId, reqBody);
    if (strcmp(method, RPC_DELETE_FILE) == 0)       return HandleDeleteFile(appId, reqBody);
    return std::nullopt;
}

static std::atomic<bool> g_initFailed{false};

static void EnsureInitialized() {
    if (g_initialized.load(std::memory_order_acquire)) return;
    if (g_initFailed.load(std::memory_order_acquire)) return;

    static std::once_flag s_initFlag;
    std::call_once(s_initFlag, []() {
        // Initialize the intercept layer (parses SLSsteam config, loginusers.vdf)


        std::string cloudRedirectRoot = XdgConfigHome() + "/CloudRedirect/";
        std::string storageRoot = cloudRedirectRoot + "storage";

        // Initialize CloudStorage with cloud provider from config.json
        std::unique_ptr<ICloudProvider> provider;
        std::string configPath = cloudRedirectRoot + "config.json";
        std::ifstream configFile(configPath);
        if (configFile) {
            std::string configStr((std::istreambuf_iterator<char>(configFile)), {});
            configFile.close();
            auto cfg = Json::Parse(configStr);
            std::string providerName = cfg["provider"].str();
            g_redirectEnabled=cfg["enabled"].boolean();
            MetadataSync::syncLuas=cfg["sync_luas"].boolean();

            const bool statsEnabled=!cfg.has("stats_sync_enabled")||cfg["stats_sync_enabled"].boolean();
            MetadataSync::syncAchievements=statsEnabled&&cfg["sync_achievements"].boolean();
            MetadataSync::syncPlaytime=statsEnabled&&cfg["sync_playtime"].boolean();
            if (!providerName.empty() && providerName != "local") {
                provider = CreateCloudProvider(providerName);
                if (provider) {
                    std::string initPath;
                    if (providerName == "folder") {
                        initPath = cfg["sync_path"].str();
                        LOG("[macOS] Cloud provider 'folder': destination %s",
                            initPath.empty() ? "(unset)" : initPath.c_str());
                    } else {
                        initPath = ResolveProviderTokenPath(
                            cloudRedirectRoot, configStr, providerName);
                        LOG("[macOS] Cloud provider '%s': resolving credentials at %s",
                            providerName.c_str(), initPath.c_str());
                    }

                    if (!initPath.empty() && provider->Init(initPath)) {
                        LOG("[macOS] Cloud provider '%s' initialized (path: %s)",
                            provider->Name(), initPath.c_str());
                        if (!provider->IsAuthenticated()) {
                            LOG("[macOS] WARNING: %s configured but not authenticated -- local-only until signed in",
                                provider->Name());
                            provider.reset();
                        }
                    } else {
                        LOG("[macOS] WARNING: Cloud provider '%s' init FAILED (path: '%s') -- "
                            "falling back to local-only. Check the path exists and is readable.",
                            providerName.c_str(), initPath.c_str());
                        provider.reset();
                    }
                } else {
                    LOG("[macOS] WARNING: Unknown cloud provider '%s', falling back to local-only",
                        providerName.c_str());
                }
            }
        } else {
            LOG("[macOS] No config.json at %s -- local-only mode", configPath.c_str());
        }

        std::ifstream configured(configPath);
        std::string configuredText((std::istreambuf_iterator<char>(configured)),{});
        const auto providerName=Json::Parse(configuredText)["provider"].str();
        if(providerName!="local"&&!provider) {g_initFailed=true;return;}
        CloudStorage::Init(cloudRedirectRoot, std::move(provider));

        LocalStorage::Init(storageRoot);
        LocalMetadataStore::Init(storageRoot);
        PendingOpsJournal::Init(storageRoot);
        if(!HttpServer::Start(storageRoot, CloudIntercept::GetAccountId())){g_initFailed=true;return;}

        if(!NativeStats::Initialize(cloudRedirectRoot,SerializeMessage,ParseIntoMessage)){
            MetadataSync::syncAchievements=false;MetadataSync::syncPlaytime=false;
            LOG("[Stats] Native initialization failed; cloud saves remain available");
        }
        NativeLua::Start();
        g_initialized.store(true, std::memory_order_release);

        LOG("[macOS] Storage initialized: root=%s, accountId=%u, namespaceApps=%zu",
            storageRoot.c_str(), CloudIntercept::GetAccountId(),
            CloudIntercept::GetNamespaceApps().size());

        // Manifest system fetches CN/manifest on-demand; no bulk startup sync.
        if (CloudStorage::IsCloudActive()) {
            LOG("[StartupSync] Cloud active; metadata will be fetched on-demand per app");
        }
    });
}

bool CloudHooks::InitializeStorage() {EnsureInitialized();return g_initialized.load();}

void CloudHooks::SetOriginals(void* origSlot5, void* origSlot7, void* origSlot8) {
    g_origBYieldingSend.store(reinterpret_cast<BYieldingSend_t>(origSlot5), std::memory_order_release);
    g_origNotificationDirect.store(reinterpret_cast<NotificationDirect_t>(origSlot7), std::memory_order_release);
    g_origSyncSend2.store(reinterpret_cast<SyncSend2_t>(origSlot8), std::memory_order_release);
}

static bool IsCloudRpc(const char* methodName) {
    return methodName && strncmp(methodName, "Cloud.", 6) == 0;
}

// Hook: BYieldingSendMessageAndGetReply (slot 5)
//
// ARM64: int(void* this, const char* method, void* req, void* resp, int* flags)
// This is the primary synchronous RPC path.

extern "C" int hook_BYieldingSend(void* pThis, const char* methodName, void* request, void* response, int* flags)
{
    HookGuard guard;
    if (g_shuttingDown.load(std::memory_order_acquire)) {
        auto fn = g_origBYieldingSend.load(std::memory_order_acquire);
        return fn ? fn(pThis, methodName, request, response, flags) : 0;
    }
    CrashContextScope crashContext("BYieldingSend:entry", methodName, 0);
    auto origFn = g_origBYieldingSend.load(std::memory_order_acquire);

    // Spin-wait for originals (installed before hooks in correct order).
    for (int i = 0; !origFn && i < 1000; ++i) {
        usleep(100);
        origFn = g_origBYieldingSend.load(std::memory_order_acquire);
    }
    if (!origFn) return 0;

    if(MetadataSync::PlaytimeEnabled())LivePlaytime::DrainOnNetThread();
    if(methodName&&strcmp(methodName,StatsHandlers::RPC_GET_USER_STATS)==0&&MetadataSync::AchievementsEnabled()){
        EnsureInitialized();if(StatsHooks::TryHandleGetUserStats(methodName,request,response,flags))return 1;
        return origFn(pThis,methodName,request,response,flags);
    }
    if(methodName&&strcmp(methodName,StatsHandlers::RPC_GET_LAST_PLAYED)==0&&MetadataSync::PlaytimeEnabled()){
        EnsureInitialized();int result=origFn(pThis,methodName,request,response,flags);
        if(result)StatsHooks::MergeLastPlayedTimes(methodName,request,response);return result;
    }
    if (!g_redirectEnabled || !IsCloudRpc(methodName) || !g_serializeToArray || !g_parseFromArray)
        return origFn(pThis, methodName, request, response, flags);

    EnsureInitialized();

    // Extract raw protobuf bytes
    auto reqBytes = SerializeMessage(request);
    if (reqBytes.empty()) {
        return origFn(pThis, methodName, request, response, flags);
    }

    auto reqFields = PB::Parse(reqBytes.data(), reqBytes.size());
    uint32_t appId = CloudRpcUtils::ExtractAppId(methodName, reqFields);
    if (appId == 0) {
        return origFn(pThis, methodName, request, response, flags);
    }
    CR_SetCrashContext("BYieldingSend:app", methodName, appId);

    if (!CloudIntercept::IsNamespaceApp(appId)) {
        return origFn(pThis, methodName, request, response, flags);
    }
    CR_SetCrashContext("BYieldingSend:namespace", methodName, appId);

    // FileDownload: call original first (yields), then patch response with our URL.
    if (strcmp(methodName, CloudIntercept::RPC_FILE_DOWNLOAD) == 0) {
        LOG("[Hook] FileDownload app=%u: calling original first", appId);
        int origResult = origFn(pThis, methodName, request, response, flags);
        LOG("[Hook] FileDownload app=%u: original returned %d, patching", appId, origResult);

        auto dispatched = DispatchCloudRpc(methodName, appId, reqFields);
        if (!dispatched.has_value()) {
            return origResult;
        }
        auto& result = *dispatched;

        if (response && result.body.Size() > 0) {
            if (!ParseIntoMessage(response, result.body.Data().data(), result.body.Size())) {
                LOG("[Hook] FileDownload: ParseFromArray failed, keeping original");
                return origResult;
            }
        }
        if (flags) {
            flags[2] = 1;
            flags[3] = result.eresult;
        }
        LOG("[Hook] FileDownload app=%u: patched (eresult=%d, %zu bytes)",
            appId, result.eresult, result.body.Size());
        return 1;
    }

    uint32_t accountId = CloudIntercept::GetAccountId();
    if (accountId == 0) {
        return origFn(pThis, methodName, request, response, flags);
    }

    LocalStorage::InitApp(accountId, appId);
    CR_SetCrashContext("BYieldingSend:metadata-init", methodName, appId);
    LocalMetadataStore::InitApp(accountId, appId);

    CR_SetCrashContext("BYieldingSend:dispatch", methodName, appId);
    auto dispatched = DispatchCloudRpc(methodName, appId, reqFields);
    if (!dispatched.has_value()) {
        return origFn(pThis, methodName, request, response, flags);
    }
    auto& result = *dispatched;

    LOG("[Hook] INTERCEPT BYieldingSend %s app=%u -> %zu bytes, eresult=%d",
        methodName, appId, result.body.Size(), result.eresult);

#ifdef DEBUG_HEX_DUMP
    {
        auto& d = result.body.Data();
        std::string hex;
        for (size_t i = 0; i < d.size() && i < 64; i++) {
            char tmp[4]; snprintf(tmp, sizeof(tmp), "%02X ", d[i]);
            hex += tmp;
        }
        LOG("[Hook]   response hex: %s", hex.c_str());
    }
#endif

    // Parse response bytes into the response protobuf object
    if (response && result.body.Size() > 0) {
        CR_SetCrashContext("BYieldingSend:parse-response", methodName, appId);
        if (!ParseIntoMessage(response, result.body.Data().data(), result.body.Size())) {
            LOG("[Hook] BYieldingSend %s: ParseFromArray failed for response! Falling through.",
                methodName);
            return origFn(pThis, methodName, request, response, flags);
        }
        LOG("[Hook]   ParseFromArray succeeded");
    }

    // Flags layout: [0]=routing, [1]=mode, [2]=transport_success, [3]=eresult
    if (flags) {
        flags[2] = 1;  // transport success
        flags[3] = result.eresult;
    }

    LOG("[Hook]   returning success for %s app=%u", methodName, appId);
    return 1;  // success
}

// Hook: NotificationDirect (slot 7)
//
// Suppress cloud notifications for namespace apps.

static uint32_t CheckNotificationNamespaceApp(const char* methodName, void* body) {
    if (!body || !g_serializeToArray) return 0;

    auto bodyBytes = SerializeMessage(body);
    if (bodyBytes.empty()) {
        LOG("[Hook-Notif] %s: body serialization empty", methodName);
        return 0;
    }

    auto fields = PB::Parse(bodyBytes.data(), bodyBytes.size());
    // For Cloud notifications, appId is field 1
    auto* appField = PB::FindField(fields, 1);
    if (!appField) {
        LOG("[Hook-Notif] %s: no field 1 (appId) in body", methodName);
        return 0;
    }

    uint32_t appId = (uint32_t)appField->varintVal;
    if (CloudIntercept::IsNamespaceApp(appId)) {
        return appId;
    }
    return 0;
}

extern "C" int hook_NotificationDirect(void* pThis, const char* methodName, void* body, int* flags)
{
    HookGuard guard;
    if (g_shuttingDown.load(std::memory_order_acquire)) {
        auto fn = g_origNotificationDirect.load(std::memory_order_acquire);
        return fn ? fn(pThis, methodName, body, flags) : 0;
    }
    CrashContextScope crashContext("NotificationDirect:entry", methodName, 0);
    auto origFn = g_origNotificationDirect.load(std::memory_order_acquire);
    for (int i = 0; !origFn && i < 1000; ++i) {
        usleep(100);
        origFn = g_origNotificationDirect.load(std::memory_order_acquire);
    }
    if (!origFn) return 0;

    // Only intercept Cloud.* notifications
    if (!g_redirectEnabled || !IsCloudRpc(methodName)) {
        return origFn(pThis, methodName, body, flags);
    }

    uint32_t appId = CheckNotificationNamespaceApp(methodName, body);
    CR_SetCrashContext("NotificationDirect:checked", methodName, appId);
    if (appId == 0) {
        // Not a namespace app - pass through to Steam servers
        LOG("[Hook-Notif] %s: not namespace, passing through", methodName);
        return origFn(pThis, methodName, body, flags);
    }

    // ExitSyncDone: let Steam process it (updates remotecache.vdf CN).
    if (strcmp(methodName, CloudIntercept::RPC_EXIT_SYNC) == 0) {
        CR_SetCrashContext("NotificationDirect:exit-sync", methodName, appId);
        auto bodyBytes = SerializeMessage(body);
        auto fields = PB::Parse(bodyBytes.data(), bodyBytes.size());
        uint64_t clientId = 0;
        bool uploadsCompleted = false;
        bool uploadsRequired = false;
        if (auto* f = PB::FindField(fields, 2)) clientId = f->varintVal;
        if (auto* f = PB::FindField(fields, 3)) uploadsCompleted = f->varintVal != 0;
        if (auto* f = PB::FindField(fields, 4)) uploadsRequired = f->varintVal != 0;
        uint32_t accountId = CloudIntercept::GetAccountId();
        if (accountId != 0) {
            PendingOpsJournal::RecordExitSyncState(accountId, appId,
                uploadsCompleted, uploadsRequired, clientId);
            // Native-faithful: ExitSyncDone is fire-and-forget (notification, no
            // response). Dispatch session release off Steam's thread.
            std::thread([accountId, appId, clientId] {
                CloudStorage::InflightSyncScope guard;
                if (!guard.entered) return;  // shutting down, skip session release
                CloudStorage::ReleaseCloudSession(accountId, appId, clientId);
            }).detach();
        }
        LOG("[Hook-Notif] %s app=%u: letting Steam process internally", methodName, appId);
        return origFn(pThis, methodName, body, flags);
    }

    // ConflictResolution: parse chose_local_files so HandleLaunchIntent
    // knows whether to skip pre-restore (user chose "keep local files").
    if (strcmp(methodName, CloudIntercept::RPC_CONFLICT) == 0) {
        auto bodyBytes = SerializeMessage(body);
        auto fields = PB::Parse(bodyBytes.data(), bodyBytes.size());
        bool choseLocal = false;
        if (auto* f = PB::FindField(fields, 2)) choseLocal = f->varintVal != 0;
        CloudIntercept::RecordConflictResolution(appId, choseLocal);
    }

    // Suppress other Cloud notifications for namespace apps
    LOG("[Hook-Notif] SUPPRESSED %s app=%u (notification not sent to server)", methodName, appId);
    return 1;
}

// Hook: SyncSend2 (slot 8)
//
// ARM64: int(void* this, const char* method, void* buf, uint32_t bufLen, void* resp, int* flags)
// Buffer-based variant -- raw protobuf bytes are directly available.

extern "C" int hook_SyncSend2(void* pThis, const char* methodName, void* buf, unsigned int bufLen, void* response, int* flags)
{
    HookGuard guard;
    if (g_shuttingDown.load(std::memory_order_acquire)) {
        auto fn = g_origSyncSend2.load(std::memory_order_acquire);
        return fn ? fn(pThis, methodName, buf, bufLen, response, flags) : 0;
    }
    CrashContextScope crashContext("SyncSend2:entry", methodName, 0);
    auto origFn = g_origSyncSend2.load(std::memory_order_acquire);
    for (int i = 0; !origFn && i < 1000; ++i) {
        usleep(100);
        origFn = g_origSyncSend2.load(std::memory_order_acquire);
    }
    if (!origFn) return 0;

    if (!g_redirectEnabled || !IsCloudRpc(methodName))
        return origFn(pThis, methodName, buf, bufLen, response, flags);

    if (!buf || bufLen == 0)
        return origFn(pThis, methodName, buf, bufLen, response, flags);

    EnsureInitialized();

    auto reqFields = PB::Parse(static_cast<const uint8_t*>(buf), bufLen);
    uint32_t appId = CloudRpcUtils::ExtractAppId(methodName, reqFields);

    if (appId == 0) {
        return origFn(pThis, methodName, buf, bufLen, response, flags);
    }
    CR_SetCrashContext("SyncSend2:app", methodName, appId);

    if (!CloudIntercept::IsNamespaceApp(appId)) {
        return origFn(pThis, methodName, buf, bufLen, response, flags);
    }
    CR_SetCrashContext("SyncSend2:namespace", methodName, appId);

    uint32_t accountId = CloudIntercept::GetAccountId();
    if (accountId == 0) {
        return origFn(pThis, methodName, buf, bufLen, response, flags);
    }

    LocalStorage::InitApp(accountId, appId);
    CR_SetCrashContext("SyncSend2:metadata-init", methodName, appId);
    LocalMetadataStore::InitApp(accountId, appId);

    CR_SetCrashContext("SyncSend2:dispatch", methodName, appId);
    auto dispatched = DispatchCloudRpc(methodName, appId, reqFields);
    if (!dispatched.has_value()) {
        return origFn(pThis, methodName, buf, bufLen, response, flags);
    }
    auto& result = *dispatched;

    LOG("[Hook] INTERCEPT SyncSend2 %s app=%u -> %zu bytes, eresult=%d",
        methodName, appId, result.body.Size(), result.eresult);

    if (response && result.body.Size() > 0 && g_parseFromArray) {
        CR_SetCrashContext("SyncSend2:parse-response", methodName, appId);
        if (!ParseIntoMessage(response, result.body.Data().data(), result.body.Size())) {
            LOG("[Hook] SyncSend2 %s: ParseFromArray failed", methodName);
            return origFn(pThis, methodName, buf, bufLen, response, flags);
        }
    }

    // Flags layout (from IDA): [0]=routing, [1]=mode, [2]=transport_success, [3]=eresult
    if (flags) {
        flags[2] = 1;  // transport success
        flags[3] = result.eresult;
    }

    return 1;
}

// Hook: IsCloudEnabledForApp (CUserRemoteStorage vtable slot 24)
// ARM64: bool(void* this, unsigned int appId)
// Returns true for namespace apps so cloud toggle stays enabled.

using IsCloudEnabledForApp_t = bool(*)(void* pThis, unsigned int appId);
static std::atomic<IsCloudEnabledForApp_t> g_origIsCloudEnabledForApp{nullptr};

void CloudHooks::SetOriginalIsCloudEnabled(void* orig) {
    g_origIsCloudEnabledForApp.store(reinterpret_cast<IsCloudEnabledForApp_t>(orig), std::memory_order_release);
}

extern "C" bool hook_IsCloudEnabledForApp(void* pThis, unsigned int appId)
{
    HookGuard guard;
    if (g_shuttingDown.load(std::memory_order_acquire)) {
        auto fn = g_origIsCloudEnabledForApp.load(std::memory_order_acquire);
        return fn ? fn(pThis, appId) : true;
    }
    CrashContextScope crashContext("IsCloudEnabledForApp:entry", "IsCloudEnabledForApp", appId);
    if (g_redirectEnabled&&CloudIntercept::IsNamespaceApp(appId)) {
        LOG("[Hook] IsCloudEnabledForApp(%u) -> true (namespace app)", appId);
        return true;
    }

    auto origFn = g_origIsCloudEnabledForApp.load(std::memory_order_acquire);
    if (origFn) {
        return origFn(pThis, appId);
    }
    return true;
}

void CloudHooks::BeginShutdown() {
    g_shuttingDown.store(true,std::memory_order_release);
    NativeLua::Shutdown();
    NativeStats::Shutdown();
    for(int i=0;i<300&&g_hookRefCount.load(std::memory_order_acquire)>0;++i)usleep(10000);
}
