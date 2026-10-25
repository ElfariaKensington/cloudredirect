// cloud760_tool - view/delete Steam Cloud files for a single AppID (default 760).
// Resolves flat C exports from a bundled native Steam client at runtime.

#include <dlfcn.h>
#include <unistd.h>
#define __cdecl
using HMODULE=void*;
#include <cstdio>
#include <cstdint>
#include <cstring>
#include <cstdlib>
#include <string>
#include <vector>

// ── Flat Steamworks API typedefs (subset we use) ───────────────────────
// Signatures match steam_api_flat.h from the Steamworks SDK.
typedef int32_t HSteamUser;
typedef int32_t HSteamPipe;
using ISteamRemoteStorage = void;

typedef bool   (__cdecl* SteamAPI_Init_t)();
typedef void   (__cdecl* SteamAPI_Shutdown_t)();
typedef HSteamUser (__cdecl* SteamAPI_GetHSteamUser_t)();
typedef HSteamPipe (__cdecl* SteamAPI_GetHSteamPipe_t)();
// Old-style interface acquisition (matches the bundled steam_api.dll, which
// predates SteamInternal_FindOrCreateUserInterface):
//   SteamClient() -> ISteamClient* ; then GetISteamRemoteStorage(client, user, pipe, ver).
typedef void*  (__cdecl* SteamClient_t)();
typedef void*  (__cdecl* SteamAPI_ISteamClient_GetISteamRemoteStorage_t)(void* client, HSteamUser, HSteamPipe, const char*);

typedef int32_t (__cdecl* RS_GetFileCount_t)(ISteamRemoteStorage*);
typedef const char* (__cdecl* RS_GetFileNameAndSize_t)(ISteamRemoteStorage*, int32_t, int32_t*);
typedef int32_t (__cdecl* RS_GetFileSize_t)(ISteamRemoteStorage*, const char*);
typedef int64_t (__cdecl* RS_GetFileTimestamp_t)(ISteamRemoteStorage*, const char*);
typedef bool   (__cdecl* RS_FileExists_t)(ISteamRemoteStorage*, const char*);
typedef bool   (__cdecl* RS_FilePersisted_t)(ISteamRemoteStorage*, const char*);
typedef bool   (__cdecl* RS_FileDelete_t)(ISteamRemoteStorage*, const char*);
typedef bool   (__cdecl* RS_FileForget_t)(ISteamRemoteStorage*, const char*);
typedef bool   (__cdecl* RS_IsCloudEnabledForAccount_t)(ISteamRemoteStorage*);
typedef bool   (__cdecl* RS_IsCloudEnabledForApp_t)(ISteamRemoteStorage*);
typedef bool   (__cdecl* RS_GetQuota_t)(ISteamRemoteStorage*, uint64_t*, uint64_t*);

static const char* REMOTESTORAGE_VERSION = "STEAMREMOTESTORAGE_INTERFACE_VERSION014";

struct SteamApi {
    HMODULE mod = nullptr;
    SteamAPI_Init_t Init = nullptr;
    SteamAPI_Shutdown_t Shutdown = nullptr;
    SteamAPI_GetHSteamUser_t GetHSteamUser = nullptr;
    SteamAPI_GetHSteamPipe_t GetHSteamPipe = nullptr;
    SteamClient_t SteamClient = nullptr;
    SteamAPI_ISteamClient_GetISteamRemoteStorage_t GetISteamRemoteStorage = nullptr;

    RS_GetFileCount_t GetFileCount = nullptr;
    RS_GetFileNameAndSize_t GetFileNameAndSize = nullptr;
    RS_GetFileSize_t GetFileSize = nullptr;
    RS_GetFileTimestamp_t GetFileTimestamp = nullptr;
    RS_FileExists_t FileExists = nullptr;
    RS_FilePersisted_t FilePersisted = nullptr;
    RS_FileDelete_t FileDelete = nullptr;
    RS_FileForget_t FileForget = nullptr;
    RS_IsCloudEnabledForAccount_t IsCloudEnabledForAccount = nullptr;
    RS_IsCloudEnabledForApp_t IsCloudEnabledForApp = nullptr;
    RS_GetQuota_t GetQuota = nullptr;

    ISteamRemoteStorage* rs = nullptr;
};

// Public versioned Steamworks interfaces, verified against ValveSoftware/Proton
// lsteamclient/steamworks_sdk_165/isteamclient.h and isteamremotestorage.h.
// No bundled Steamworks binary or Windows DLL is required.
static void* g_client=nullptr;static int g_pipe=0,g_user=0;
template<class F> F Method(void* object,int slot){return reinterpret_cast<F>((*reinterpret_cast<void***>(object))[slot]);}
static void ShutdownNative(){
    if(g_client&&g_user)Method<void(*)(void*,int,int)>(g_client,4)(g_client,g_pipe,g_user);
    if(g_client&&g_pipe)Method<bool(*)(void*,int)>(g_client,1)(g_client,g_pipe);
    g_user=g_pipe=0;
}
static bool LoadSteamApi(SteamApi& api){
    api.Shutdown=ShutdownNative;
    api.GetFileCount=[](void* rs){return Method<int32_t(*)(void*)>(rs,18)(rs);};
    api.GetFileNameAndSize=[](void* rs,int32_t i,int32_t* n){return Method<const char*(*)(void*,int32_t,int32_t*)>(rs,19)(rs,i,n);};
    api.GetFileSize=[](void* rs,const char* n){return Method<int32_t(*)(void*,const char*)>(rs,15)(rs,n);};
    api.GetFileTimestamp=[](void* rs,const char* n){return Method<int64_t(*)(void*,const char*)>(rs,16)(rs,n);};
    api.FileExists=[](void* rs,const char* n){return Method<bool(*)(void*,const char*)>(rs,13)(rs,n);};
    api.FilePersisted=[](void* rs,const char* n){return Method<bool(*)(void*,const char*)>(rs,14)(rs,n);};
    api.FileDelete=[](void* rs,const char* n){return Method<bool(*)(void*,const char*)>(rs,6)(rs,n);};
    api.FileForget=[](void* rs,const char* n){return Method<bool(*)(void*,const char*)>(rs,5)(rs,n);};
    api.IsCloudEnabledForAccount=[](void* rs){return Method<bool(*)(void*)>(rs,21)(rs);};
    api.IsCloudEnabledForApp=[](void* rs){return Method<bool(*)(void*)>(rs,22)(rs);};
    api.GetQuota=[](void* rs,uint64_t* a,uint64_t* b){return Method<bool(*)(void*,uint64_t*,uint64_t*)>(rs,20)(rs,a,b);};
    return true;
}
static bool Connect(SteamApi& api,uint32_t appId){
    std::string id=std::to_string(appId);for(auto name:{"SteamAppId","SteamAppID","SteamGameId"})setenv(name,id.c_str(),1);
    const char* home=getenv("HOME");if(!home)return false;
    std::string path=std::string(home)+"/Library/Application Support/Steam/Steam.AppBundle/Steam/Contents/MacOS/steamclient.dylib";
    api.mod=dlopen(path.c_str(),RTLD_NOW|RTLD_LOCAL);if(!api.mod){fprintf(stderr,"Could not load the native Steam client: %s\n",dlerror());return false;}
    auto factory=(void*(*)(const char*,int*))dlsym(api.mod,"CreateInterface");if(!factory)return false;
    g_client=factory("SteamClient023",nullptr);
    if(!g_client){fprintf(stderr,"SteamClient023 unavailable; update Steam before using its cloud manager.\n");return false;}
    g_pipe=Method<int(*)(void*)>(g_client,0)(g_client);
    if(g_pipe)g_user=Method<int(*)(void*,int)>(g_client,2)(g_client,g_pipe);
    if(!g_pipe||!g_user){fprintf(stderr,"Could not connect to Steam. Start Steam and sign in first.\n");ShutdownNative();return false;}
    auto* utils=Method<void*(*)(void*,int,const char*)>(g_client,9)(g_client,g_pipe,"SteamUtils010");
    if(!utils||Method<uint32_t(*)(void*)>(utils,9)(utils)!=appId){fprintf(stderr,"Steam did not bind the requested AppID; refusing cloud access.\n");ShutdownNative();return false;}
    api.rs=Method<void*(*)(void*,int,int,const char*)>(g_client,17)(g_client,g_user,g_pipe,"STEAMREMOTESTORAGE_INTERFACE_VERSION016");
    if(!api.rs){fprintf(stderr,"Steam remote storage interface unavailable.\n");ShutdownNative();return false;}
    return true;
}

static void PrintCloudStatus(SteamApi& api, uint32_t appId, bool porcelain) {
    bool acct = api.IsCloudEnabledForAccount(api.rs);
    bool app  = api.IsCloudEnabledForApp(api.rs);
    uint64_t total = 0, avail = 0;
    bool haveQuota = api.GetQuota(api.rs, &total, &avail);

    if (porcelain) {
        printf("CLOUD\t%d\t%d\n", acct ? 1 : 0, app ? 1 : 0);
        if (haveQuota)
            printf("QUOTA\t%llu\t%llu\n",
                   (unsigned long long)total,
                   (unsigned long long)(total - avail));
        return;
    }

    printf("AppID %u  cloud(account)=%s  cloud(app)=%s\n",
           appId, acct ? "on" : "off", app ? "on" : "off");
    if (haveQuota) {
        printf("Quota: %llu / %llu bytes used (%.1f%%)\n",
               (unsigned long long)(total - avail), (unsigned long long)total,
               total ? (double)(total - avail) * 100.0 / (double)total : 0.0);
    }
}

static int CmdList(SteamApi& api, uint32_t appId, bool porcelain) {
    PrintCloudStatus(api, appId, porcelain);
    int count = api.GetFileCount(api.rs);
    if (porcelain) {
        printf("COUNT\t%d\n", count);
        for (int i = 0; i < count; ++i) {
            int32_t size = 0;
            const char* name = api.GetFileNameAndSize(api.rs, i, &size);
            if (!name) name = "";
            bool persisted = api.FilePersisted(api.rs, name);
            printf("FILE\t%s\t%d\t%d\n", name, size, persisted ? 1 : 0);
        }
        return 0;
    }
    printf("\n%d cloud file(s) for AppID %u:\n", count, appId);
    printf("%-50s %12s  %s\n", "NAME", "SIZE", "PERSISTED");
    for (int i = 0; i < count; ++i) {
        int32_t size = 0;
        const char* name = api.GetFileNameAndSize(api.rs, i, &size);
        if (!name) name = "(null)";
        bool persisted = api.FilePersisted(api.rs, name);
        printf("%-50s %12d  %s\n", name, size, persisted ? "yes" : "no");
    }
    return 0;
}

static int CmdQuota(SteamApi& api, uint32_t appId, bool porcelain) {
    PrintCloudStatus(api, appId, porcelain);
    return 0;
}

static int CmdDelete(SteamApi& api, uint32_t appId, const std::vector<std::string>& names, bool porcelain) {
    int failures = 0;
    for (const auto& n : names) {
        bool ok = api.FileDelete(api.rs, n.c_str());
        // FileForget stops it from re-syncing back from any local cache.
        api.FileForget(api.rs, n.c_str());
        if (porcelain)
            printf("DEL\t%s\t%s\n", n.c_str(), ok ? "OK" : "FAIL");
        else
            printf("delete %-50s %s\n", n.c_str(), ok ? "OK" : "FAILED");
        if (!ok) ++failures;
    }
    if (!porcelain)
        printf("\nDeleted %zu file(s), %d failure(s) for AppID %u.\n",
               names.size() - failures, failures, appId);
    return failures ? 1 : 0;
}

static int CmdDeleteAll(SteamApi& api, uint32_t appId, bool assumeYes, bool porcelain) {
    int count = api.GetFileCount(api.rs);
    std::vector<std::string> names;
    for (int i = 0; i < count; ++i) {
        int32_t size = 0;
        const char* name = api.GetFileNameAndSize(api.rs, i, &size);
        if (name) names.emplace_back(name);
    }

    if (names.empty()) {
        if (!porcelain) printf("No cloud files for AppID %u; nothing to delete.\n", appId);
        return 0;
    }

    if (!porcelain) {
        printf("About to delete %zu file(s) from AppID %u cloud:\n", names.size(), appId);
        for (const auto& n : names) printf("  %s\n", n.c_str());

        if (!assumeYes) {
            printf("\nType 'yes' to confirm: ");
            char line[16] = {};
            if (!fgets(line, sizeof(line), stdin) ||
                (strncmp(line, "yes", 3) != 0)) {
                printf("Aborted.\n");
                return 1;
            }
        }
    }
    return CmdDelete(api, appId, names, porcelain);
}

static void Usage() {
    fprintf(stderr,
        "cloud760_tool - view/delete Steam Cloud files for an AppID (default 760)\n\n"
        "Usage:\n"
        "  cloud760_tool list [appid]\n"
        "  cloud760_tool quota [appid]\n"
        "  cloud760_tool delete [appid] <file> [<file> ...]\n"
        "  cloud760_tool delete-all [appid] [--yes]\n\n"
        "Global: --porcelain  emit tab-separated machine output for the UI.\n"
        "Steam must be running and logged in. steam_api.dll must be next to this exe.\n");
}

// Parse an optional leading appid token; default 760. Returns remaining args.
static uint32_t ParseAppId(std::vector<std::string>& args, uint32_t def) {
    if (!args.empty()) {
        char* end = nullptr;
        unsigned long v = strtoul(args[0].c_str(), &end, 10);
        if (end && *end == '\0' && v > 0) {
            args.erase(args.begin());
            return (uint32_t)v;
        }
    }
    return def;
}

static int Run(int argc, char** argv) {
    if (argc < 2) { Usage(); return 2; }

    std::string cmd = argv[1];
    std::vector<std::string> rest;
    bool assumeYes = false;
    bool porcelain = false;
    for (int i = 2; i < argc; ++i) {
        if (strcmp(argv[i], "--yes") == 0 || strcmp(argv[i], "-y") == 0)
            assumeYes = true;
        else if (strcmp(argv[i], "--porcelain") == 0)
            porcelain = true;
        else
            rest.emplace_back(argv[i]);
    }

    uint32_t appId = ParseAppId(rest, 760);

    SteamApi api;
    if (!LoadSteamApi(api)) return 1;
    if (!Connect(api, appId)) { api.Shutdown(); return 1; }

    int rc = 2;
    if (cmd == "list")            rc = CmdList(api, appId, porcelain);
    else if (cmd == "quota")      rc = CmdQuota(api, appId, porcelain);
    else if (cmd == "delete") {
        if (rest.empty()) { fprintf(stderr, "Error: 'delete' needs at least one filename.\n"); rc = 2; }
        else              rc = CmdDelete(api, appId, rest, porcelain);
    }
    else if (cmd == "delete-all") rc = CmdDeleteAll(api, appId, assumeYes, porcelain);
    else { Usage(); rc = 2; }

    api.Shutdown();
    return rc;
}

int main(int argc,char**argv){int result=Run(argc,argv);fflush(nullptr);_Exit(result);}
