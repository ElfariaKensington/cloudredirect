#include "native_manifest.h"
#include <filesystem>
#include <fstream>
#include <stdexcept>
#include <unistd.h>
#include <cstdio>
#define CHECK(x) do{if(!(x))throw std::runtime_error(#x);}while(0)
int main(){char pattern[]="/tmp/cr-manifest-tests-XXXXXX";auto* dir=mkdtemp(pattern);if(!dir)return 1;
 try{
    std::ofstream(std::string(dir)+"/620.lua")<<"addappid(620)\nsetManifestid(621, \"18446744073709551615\")\n-- setManifestid(622,\"42\")\n";
    std::ofstream(std::string(dir)+"/20.lua")<<"setManifestid(21,\"1234567890123456789\")\n";
    auto cfg=Json::Parse("{\"manifest_pinning\":true,\"auto_comment\":true,\"pinned_apps\":[620]}");
    auto pins=NativeManifest::LoadPins(cfg,dir);CHECK(pins.size()==1&&pins[620].size()==1&&pins[620][621]==UINT64_MAX);
    struct Entry {uint32_t depot,padding;uint64_t manifest;uint8_t rest[16];};
    Entry entries[2]={{621,123,50,{1}},{622,321,70,{2}}};
    struct Vec {void* data;int capacity,grow,count;} vector{entries,2,0,2};
    CHECK(NativeManifest::PatchVector(&vector,pins[620]));CHECK(entries[0].manifest==UINT64_MAX&&entries[0].padding==123&&entries[0].rest[0]==1);CHECK(entries[1].manifest==70&&entries[1].padding==321);
    vector.count=4097;CHECK(!NativeManifest::PatchVector(&vector,pins[620]));
    cfg.objVal["auto_comment"].boolVal=false;CHECK(NativeManifest::LoadPins(cfg,dir).size()==2);
    std::filesystem::remove_all(dir);puts("Native manifest selection, 64-bit IDs and depot vector patching passed");return 0;
 }catch(const std::exception&e){std::filesystem::remove_all(dir);fprintf(stderr,"FAIL: %s\n",e.what());return 1;}
}
