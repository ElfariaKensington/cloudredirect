#include "native_lua.h"
#include "cloud_storage.h"
#include "cloud_work_queue.h"
#include "cloud_intercept.h"
#include "local_storage.h"
#include "local_metadata_store.h"
#include <filesystem>
#include <fstream>
#include <stdexcept>
#include <unistd.h>
#include <cstdio>
#define CHECK(x) do{if(!(x))throw std::runtime_error(#x);}while(0)
int main(){char name[]="/tmp/cr-lua-tests-XXXXXX";auto* dir=mkdtemp(name);if(!dir)return 1;std::string root=dir;bool initialized=false;
 try{
    auto provider=CreateCloudProvider("folder");CHECK(provider&&provider->Init(root+"/remote"));
    CloudIntercept::SetAccountId(4242);CloudIntercept::SetSteamPath(root+"/steam/");
    std::filesystem::create_directories(root+"/steam/config/stplug-in");
    std::ofstream(root+"/steam/config/stplug-in/620.lua")<<"addappid(620)\nsetManifestid(621,\"1234567890123456789\")\n";
    CloudStorage::Init(root+"/config/",std::move(provider));initialized=true;
    LocalStorage::Init(root+"/config/storage");LocalMetadataStore::Init(root+"/config/storage");LocalStorage::InitApp(4242,0);
    NativeLua::SyncNow();CloudWorkQueue::DrainQueue();
    CHECK(std::filesystem::exists(root+"/remote/4242/0/blobs/LuaArchive.zip"));CHECK(std::filesystem::exists(root+"/remote/4242/0/blobs/LuaManifest.json"));
    std::filesystem::remove(root+"/steam/config/stplug-in/620.lua");
    std::ofstream(root+"/steam/config/stplug-in/20.lua")<<"addappid(20)\n";
    NativeLua::SyncNow();CloudWorkQueue::DrainQueue();
    CHECK(std::filesystem::exists(root+"/steam/config/stplug-in/620.lua"));CHECK(std::filesystem::exists(root+"/steam/config/stplug-in/20.lua"));CHECK(CloudIntercept::IsNamespaceApp(620));
    std::filesystem::remove(root+"/steam/config/stplug-in/20.lua");NativeLua::SyncNow();CloudWorkQueue::DrainQueue();CHECK(std::filesystem::exists(root+"/steam/config/stplug-in/20.lua"));
    CloudStorage::Shutdown();std::filesystem::remove_all(root);puts("Native cross-device Lua archive union and restoration passed");return 0;
 }catch(const std::exception&e){if(initialized)CloudStorage::Shutdown();std::filesystem::remove_all(root);fprintf(stderr,"FAIL: %s\n",e.what());return 1;}
}
