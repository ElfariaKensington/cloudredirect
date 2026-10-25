#include "native_profile.h"
#include "native_kv.h"
#include "native_manifest.h"
#include "cloud_hooks.h"
#include "cloud_intercept.h"
#include "cloud_provider.h"
#include "cloud_storage.h"
#include "rpc_handlers.h"
#include "http_server.h"
#include <atomic>
#include "file_util.h"
#include "json.h"
#include "log.h"
#include "xdg.h"
#include <thread>
#include <chrono>
#include <fstream>
#include <unistd.h>
#include <cstring>
extern "C" int hook_BYieldingSend(void*,const char*,void*,void*,int*);
extern "C" int hook_NotificationDirect(void*,const char*,void*,int*);
extern "C" int hook_SyncSend2(void*,const char*,void*,unsigned int,void*,int*);
extern "C" bool hook_IsCloudEnabledForApp(void*,unsigned int);
namespace {
std::atomic<bool> stopping{false};
std::thread* worker=nullptr;
std::atomic<bool> manifestActive{false};
void Status(bool active,const std::string& message) {
    auto value=Json::Object(); value.objVal["active"].type=Json::Type::Bool;
    active=active||manifestActive;
    value.objVal["active"].boolVal=active; value.objVal["pid"]=Json::Number(getpid());
    value.objVal["message"]=Json::String(message);
    FileUtil::AtomicWriteText(XdgConfigHome()+"/CloudRedirect/runtime-status.json",Json::Stringify(value));
    LOG("[macOS] %s",message.c_str());
}
void Start() {
    Log::Init();
    std::string root=XdgConfigHome()+"/CloudRedirect/";
    std::ifstream file(root+"config.json"); std::string input((std::istreambuf_iterator<char>(file)),{});
    auto cfg=Json::Parse(input);
    const bool redirect=cfg["enabled"].boolean();
    const bool pin=cfg["manifest_pinning"].boolean();
    const bool lua=cfg["sync_luas"].boolean();
    const bool stats=(!cfg.has("stats_sync_enabled")||cfg["stats_sync_enabled"].boolean())&&(cfg["sync_achievements"].boolean()||cfg["sync_playtime"].boolean());
    if(!redirect&&!pin&&!stats&&!lua){Status(false,"Redirection and manifest pinning are disabled.");return;}
    CloudIntercept::InitLinux();
    if(pin){
        MacProfile::Profile pinProfile;std::string pinError;bool found=false;
        for(int i=0;i<120&&!stopping;++i){if(MacProfile::Resolve(pinProfile,pinError)){found=true;break;}if(pinError!="ARM64 steamclient.dylib is not loaded")break;std::this_thread::sleep_for(std::chrono::milliseconds(500));}
        if(stopping)return;
        manifestActive=found&&NativeManifest::Initialize(pinProfile,cfg,CloudIntercept::GetSteamPath());
        if(!redirect&&!stats&&!lua){Status(manifestActive,manifestActive?"Manifest pinning active; cloud save redirection disabled.":"Native manifest pinning could not start: "+pinError);return;}
    }
    if((!CloudIntercept::HasNamespaceApps()&&!lua)||!CloudIntercept::GetAccountId()){
        Status(false,"Select game IDs and sign in to Steam before enabling CloudRedirect.");return;
    }
    auto name=cfg["provider"].str();
    if(name!="local") {
        auto provider=CreateCloudProvider(name);
        if(!provider||!provider->Init(name=="folder"?cfg["sync_path"].str():ResolveProviderTokenPath(root,input,name))||!provider->IsAuthenticated()){
            Status(false,"Configured provider is unavailable. Redirection remains inactive.");return;
        }
    }
    MacProfile::Profile profile; std::string error;
    bool found=false;
    for(int i=0;i<120&&!stopping;++i){if(MacProfile::Resolve(profile,error)){found=true;break;}if(error!="ARM64 steamclient.dylib is not loaded")break;std::this_thread::sleep_for(std::chrono::milliseconds(500));}
    if(stopping)return;
    if(!found||!MacProfile::TestProtobuf(profile,error)||!CloudHooks::ResolveProtobufHelpers(nullptr,0)){Status(false,error);return;}
    SteamKvInjector::ResolvedKvAddrs kv;
    if(MacProfile::ResolveKv(profile,kv,error)&&MacProfile::TestKv(kv,error)){SteamKvInjector::Configure(kv);SteamKvInjector::Init();}
    else LOG("[KvInjector] %s",error.c_str());
    if(!CloudHooks::InitializeStorage()){Status(false,"Provider or local blob server could not start; hooks remain inactive.");return;}
    CloudHooks::SetOriginals(profile.transport[5],profile.transport[7],profile.transport[8]);
    if(!MacProfile::ReplaceSlots(profile.transport,{{5,(void*)hook_BYieldingSend},{7,(void*)hook_NotificationDirect},{8,(void*)hook_SyncSend2}})) {
        Status(false,"Could not install cloud RPC hooks.");return;
    }
    // This slot is validated by the audited Mach-O UUID before Resolve succeeds.
    CloudHooks::SetOriginalIsCloudEnabled(profile.remoteStorage[24]);
    if(!MacProfile::ReplaceSlots(profile.remoteStorage,{{24,(void*)hook_IsCloudEnabledForApp}})) {
        CloudHooks::BeginShutdown();Status(false,"Could not enable cloud storage hooks.");return;
    }
    Status(true,redirect?"Cloud save redirection active for the selected game IDs.":"Metadata runtime started. Enabled achievement, playtime and Lua features use the configured provider.");
}
__attribute__((constructor)) void Load() {
    const char* process=getprogname();
    if(process&&strcmp(process,"steam_osx")==0) worker=new std::thread([](){
        try{Start();}catch(const std::exception& e){LOG("[macOS] Runtime initialization failed: %s",e.what());}
    });
}
__attribute__((destructor)) void Unload() {
    if(!worker)return;
    stopping=true;
    if(worker->joinable())worker->join();
    delete worker;worker=nullptr;
    NativeManifest::Shutdown();
    CloudHooks::BeginShutdown();HttpServer::Stop();
    CloudIntercept::ShutdownRpcHandlers();CloudStorage::Shutdown();Log::Shutdown();
}
}
