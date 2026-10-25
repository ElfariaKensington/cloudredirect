// Explicit optional test against an installed Steam. All save/config I/O uses
// a fresh temporary directory, including the synthetic Steam installation.
#include "native_profile.h"
#include "cloud_hooks.h"
#include "cloud_intercept.h"
#include "cloud_storage.h"
#include "rpc_handlers.h"
#include "http_server.h"
#include <filesystem>
#include <fstream>
#include <cstdio>
#include <cstdlib>
#include <unistd.h>
extern "C" int hook_BYieldingSend(void*,const char*,void*,void*,int*);
extern "C" int hook_SyncSend2(void*,const char*,void*,unsigned int,void*,int*);
static int calls=0;
static int Original(void*,const char*,void*,void*,int*){++calls;return 92;}
static int RawOriginal(void*,const char*,void*,unsigned int,void*,int*){++calls;return 93;}
int main(){
    MacProfile::Profile p;std::string error;
    if(!MacProfile::Resolve(p,error,true)||!MacProfile::TestProtobuf(p,error)){fprintf(stderr,"%s\n",error.c_str());fflush(stderr);_Exit(1);}
    char name[]="/tmp/cr-native-rpc-XXXXXX";char* dir=mkdtemp(name);if(!dir)_Exit(1);
    std::string root=dir;setenv("CLOUDREDIRECT_CONFIG_HOME",dir,1);setenv("CLOUDREDIRECT_STEAM_HOME",(root+"/steam").c_str(),1);
    std::filesystem::create_directories(root+"/CloudRedirect");
    std::ofstream(root+"/CloudRedirect/config.json")<<"{\"enabled\":true,\"provider\":\"folder\",\"sync_path\":\""<<root<<"/remote\",\"apps\":[620]}";
    CloudIntercept::InitLinux();CloudIntercept::SetAccountId(4242);CloudIntercept::SetSteamPath(root+"/steam");
    CloudHooks::SetOriginals((void*)Original,nullptr,(void*)RawOriginal);
    bool ok=CloudHooks::ResolveProtobufHelpers(nullptr,0) && CloudHooks::InitializeStorage();
    auto** reqvt=p.FindVtable("35CCloud_GetAppFileChangelist_Request");
    auto** resvt=p.FindVtable("36CCloud_GetAppFileChangelist_Response");
    ok=ok&&reqvt&&resvt;
    if(ok){
        auto req=((void*(*)(void*))reqvt[3])(nullptr);auto res=((void*(*)(void*))resvt[3])(nullptr);
        uint8_t selected[]={0x08,0xec,0x04},other[]={0x08,0x14};int flags[4]={};
        ok=p.parse(req,selected,sizeof(selected))&&hook_BYieldingSend(nullptr,CloudIntercept::RPC_GET_CHANGELIST,req,res,flags)==1&&flags[2]==1&&flags[3]==1&&calls==0;
        ok=ok&&p.parse(req,other,sizeof(other))&&hook_BYieldingSend(nullptr,CloudIntercept::RPC_GET_CHANGELIST,req,res,flags)==92&&calls==1;
        ok=ok&&hook_SyncSend2(nullptr,CloudIntercept::RPC_GET_CHANGELIST,selected,sizeof(selected),res,flags)==1&&calls==1;
        ok=ok&&hook_SyncSend2(nullptr,CloudIntercept::RPC_GET_CHANGELIST,other,sizeof(other),res,flags)==93&&calls==2;
        ((void(*)(void*))reqvt[1])(req);((void(*)(void*))resvt[1])(res);
    }
    CloudHooks::BeginShutdown();HttpServer::Stop();CloudIntercept::ShutdownRpcHandlers();CloudStorage::Shutdown();
    std::filesystem::remove_all(root);
    printf("Native ARM64 cloud RPC interception and unselected-game passthrough: %s\n",ok?"PASS":"FAIL");fflush(stdout);_Exit(ok?0:1);
}
