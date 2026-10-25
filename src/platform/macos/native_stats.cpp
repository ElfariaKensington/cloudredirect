#include "native_stats.h"
#include "native_profile.h"
#include "live_playtime.h"
#include "cloud_intercept.h"
#include "cloud_storage.h"
#include "stats_store.h"
#include "stats_handlers.h"
#include "metadata_sync.h"
#include "json.h"
#include "log.h"
#include <dobby.h>
#include <mach/mach.h>
#include <mach/mach_vm.h>
#include <atomic>
#include <thread>
#include <condition_variable>
#include <mutex>
namespace {
struct State {
    std::atomic<bool> active{false};
    std::atomic<int> observers{0};
    StatsHooks::SerializeFn serialize;
    MacProfile::Profile profile;
    std::thread seed,poller;
    std::mutex mutex;std::condition_variable cv;
    void* send=nullptr;
};
State* state=nullptr;
template<class T> bool Read(uintptr_t address,T& value){mach_vm_size_t size=0;return address&&mach_vm_read_overwrite(mach_task_self(),address,sizeof(T),(mach_vm_address_t)&value,&size)==KERN_SUCCESS&&size==sizeof(T);}
void OnSend(void*,DobbyRegisterContext* context){
    auto* s=state;if(!s||!s->active)return;
    s->observers.fetch_add(1);
    struct Scope {State* s;~Scope(){s->observers.fetch_sub(1);}}scope{s};
    if(!s->active)return;
    uintptr_t message=context->general.regs.x0,body=0;uint32_t emsg=0;
    if(!Read(message+0x28,emsg))return;emsg&=0x7fffffff;
    const bool games=emsg==742||emsg==715||emsg==5410;
    const bool stats=emsg==5466;
    if((!games||!MetadataSync::PlaytimeEnabled())&&(!stats||!MetadataSync::AchievementsEnabled()))return;
    if(!Read(message+0x38,body)||!body)return;
    uintptr_t vtable=0,method=0;
    if(!Read(body,vtable)||!Read(vtable+9*sizeof(void*),method))return;
    if(!s->profile.Executable((void*)method))return;
    auto size=((size_t(*)(void*))method)((void*)body);
    if(size>64*1024*1024)return;
    if(size==0&&games){auto ended=StatsHandlers::ObserveGamesPlayed(nullptr,0);if(!ended.empty())LivePlaytime::Queue(StatsHandlers::BuildLastPlayedNotificationBody(ended).Data());LivePlaytime::DrainOnNetThread();LOG("[Stats] ARM64 empty GamesPlayed observed: sessions ended");return;}
    auto bytes=s->serialize((void*)body);if(bytes.empty())return;
    if(games){auto ended=StatsHandlers::ObserveGamesPlayed(bytes.data(),bytes.size());if(!ended.empty())LivePlaytime::Queue(StatsHandlers::BuildLastPlayedNotificationBody(ended).Data());LivePlaytime::DrainOnNetThread();LOG("[Stats] ARM64 GamesPlayed observed (emsg=%u)",emsg);}
    else {StatsHandlers::ObserveStoreUserStats(bytes.data(),bytes.size());LOG("[Stats] ARM64 StoreUserStats observed");}
}
}
namespace NativeStats {
bool Initialize(const std::string& cloudRedirectRoot,StatsHooks::SerializeFn serialize,StatsHooks::ParseFn parse){
    if(!MetadataSync::AchievementsEnabled()&&!MetadataSync::PlaytimeEnabled())return true;
    MacProfile::Profile profile;std::string error;
    if(!MacProfile::Resolve(profile,error))return false;
    void* send=profile.UniquePattern("FF 03 02 D1 F6 57 05 A9 F4 4F 06 A9 FD 7B 07 A9 FD C3 01 91 F3 03 01 AA F4 03 00 AA 08 2B 00 F0 08 15 40 F9 08 01 40 B9 E8 00 00 34 40 27 00 B0 00 D0 13 91 A2 A3 00 D1 01 02 80 52 D2 6D 06 94");
    if(!send){LOG("[Stats] ARM64 BAsyncSend did not resolve uniquely; stats hooks inactive");return false;}
    state=new State;state->serialize=std::move(serialize);state->send=send;state->profile=profile;
        StatsStore::SetCloudProvider(
            // pullAll: one download of the account blob, split into per-app entries.
            [](std::unordered_map<uint32_t, std::string>& out) -> bool {
                uint32_t accountId = CloudIntercept::GetAccountId();
                if (accountId == 0) return false;
                std::vector<uint8_t> data;
                auto fetch = CloudStorage::FetchCloudMetadataStatus(
                    accountId, CloudIntercept::kAccountScopeAppId, "stats.json", data);
                if (fetch == CloudStorage::MetadataFetch::Error)
                    return false; // transient failure -> keep the existing cloud cache
                if (fetch == CloudStorage::MetadataFetch::Missing || data.empty())
                    return true;  // no account blob yet -> empty (not a failure)
                Json::Value root = Json::Parse(
                    std::string(reinterpret_cast<const char*>(data.data()), data.size()));
                if (root.type != Json::Type::Object) return true;
                for (const auto& [appIdStr, appVal] : root.objVal) {
                    uint32_t appId = (uint32_t)strtoul(appIdStr.c_str(), nullptr, 10);
                    if (appId == 0) continue;
                    out[appId] = Json::Stringify(appVal);
                }
                return true;
            },
            // pushAll: RMW-merge our snapshot onto the live blob (don't clobber
            // another device) and upload once; skip if nothing changed.
            [](const std::unordered_map<uint32_t, std::string>& all) {
                // Detached worker: register with the in-flight drain so
                // CloudStorage::Shutdown waits for the provider read below before
                // tearing g_provider down (UAF guard).
                CloudStorage::InflightSyncScope guard;
                if (!guard.entered) return;

                uint32_t accountId = CloudIntercept::GetAccountId();
                if (accountId == 0) return;

                Json::Value root = Json::Object();
                std::vector<uint8_t> cur;
                if (CloudStorage::DownloadCloudMetadataWithLegacyFallback(
                        accountId, CloudIntercept::kAccountScopeAppId, "stats.json",
                        nullptr, cur) && !cur.empty()) {
                    Json::Value parsed = Json::Parse(
                        std::string(reinterpret_cast<const char*>(cur.data()), cur.size()));
                    if (parsed.type == Json::Type::Object) root = std::move(parsed);
                }

                auto resetApps = StatsStore::ConsumeResetApps();

                bool changed = false;
                for (const auto& [appId, json] : all) {
                    if (appId == 0) continue;
                    std::string key = std::to_string(appId);
                    std::string mergedEntry;
                    if (resetApps.count(appId)) {
                        mergedEntry = json;
                    } else {
                        std::string baseEntry = root.has(key)
                            ? Json::Stringify(root.objVal[key]) : std::string();
                        mergedEntry = StatsStore::MergeAppStatsJson(baseEntry, json);
                    }
                    Json::Value appVal = Json::Parse(mergedEntry);
                    if (!root.has(key) || !Json::DeepEqual(root.objVal[key], appVal)) {
                        root.objVal[key] = std::move(appVal);
                        changed = true;
                    }
                }
                if (!changed) return;

                std::string merged = Json::Stringify(root);
                CloudStorage::UploadCloudMetadataTextAsync(
                    accountId, CloudIntercept::kAccountScopeAppId, "stats.json", merged);
            },
            // pullLegacy: read one app's old per-app blob for migration into the account blob.
            [](uint32_t appId) -> std::string {
                CloudStorage::InflightSyncScope guard;
                if (!guard.entered) return std::string();
                uint32_t accountId = CloudIntercept::GetAccountId();
                if (accountId == 0) return std::string();
                std::vector<uint8_t> data;
                if (CloudStorage::DownloadCloudMetadataWithLegacyFallback(
                        accountId, appId, "stats.json", nullptr, data) && !data.empty())
                    return std::string(reinterpret_cast<const char*>(data.data()), data.size());
                return std::string();
            },
            // pullLegacyPlaytime: read one app's first-format Playtime/<appId>.bin from cloud.
            [](uint32_t appId) -> std::string {
                CloudStorage::InflightSyncScope guard;
                if (!guard.entered) return std::string();
                uint32_t accountId = CloudIntercept::GetAccountId();
                if (accountId == 0) return std::string();
                std::vector<uint8_t> data;
                if (CloudStorage::DownloadLegacyPlaytimeBlob(accountId, appId, data))
                    return std::string(reinterpret_cast<const char*>(data.data()), data.size());
                return std::string();
            });

    StatsHandlers::SetNamespacePredicate([](uint32_t id){return CloudIntercept::IsNamespaceApp(id);});
    StatsStore::SetNamespacePredicate([](uint32_t id){return CloudIntercept::IsNamespaceApp(id);});
    StatsStore::SetAccountIdProvider([](){return CloudIntercept::GetAccountId();});
    StatsStore::Init(cloudRedirectRoot,CloudIntercept::GetSteamPath());StatsHandlers::Init();
    StatsHooks::SetProtobufHelpers(state->serialize,std::move(parse));
    if(DobbyInstrument(send,OnSend)!=0){LOG("[Stats] Could not instrument native protobuf sends");return false;}
    if(LivePlaytime::Resolve(0,0,profile.parse))LivePlaytime::InstallUserCapture();
    state->active=true;
    state->seed=std::thread([]{StatsStore::SeedApps(CloudIntercept::GetNamespaceApps());});
    state->poller=std::thread([]{
        std::unique_lock<std::mutex> lock(state->mutex);
        while(state->active){
            if(state->cv.wait_for(lock,std::chrono::seconds(60),[]{return !state->active;}))break;
            lock.unlock();auto changed=StatsStore::RefreshFromCloud(CloudIntercept::GetNamespaceApps());if(!changed.empty())LivePlaytime::Queue(StatsHandlers::BuildLastPlayedNotificationBody(changed).Data());lock.lock();
        }
    });
    LOG("[Stats] Native achievement/playtime storage, cloud merge and send observation initialized");return true;
}
void Shutdown(){
    if(!state || !state->active.exchange(false)) return;
    state->cv.notify_all();
    if(state->send){DobbyDestroy(state->send);state->send=nullptr;}
    if(state->seed.joinable())state->seed.join();if(state->poller.joinable())state->poller.join();
    for(int i=0;i<300&&state->observers;++i)std::this_thread::sleep_for(std::chrono::milliseconds(10));
    LivePlaytime::RemoveUserCapture();
    StatsHandlers::Shutdown();StatsStore::FlushAll();
    // Keep callback state alive until process exit if a network callback is draining.
}
}
