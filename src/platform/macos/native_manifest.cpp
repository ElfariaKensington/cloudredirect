#include "native_manifest.h"
#include "log.h"
#include <dobby.h>
#include <mach/mach.h>
#include <mach/mach_vm.h>
#include <filesystem>
#include <fstream>
#include <regex>
#include <unordered_set>
#include <atomic>
namespace NativeManifest {
namespace {
using Builder=uintptr_t(*)(void*,uint32_t,void*,void*,void*,void*,uint32_t*,uint8_t*);
struct State {AppPins pins;Builder original=nullptr;void* target=nullptr;std::atomic<bool> enabled{false};};
State* state=nullptr;
template<class T>bool Read(uintptr_t address,T& value){mach_vm_size_t size=0;return address&&mach_vm_read_overwrite(mach_task_self(),address,sizeof(T),(mach_vm_address_t)&value,&size)==KERN_SUCCESS&&size==sizeof(T);}
uintptr_t Build(void* manager,uint32_t app,void* a3,void* primary,void* secondary,void* a6,uint32_t* a7,uint8_t* a8){
    if(!state||!state->original)return 0;
    auto result=state->original(manager,app,a3,primary,secondary,a6,a7,a8);
    if(result&&state->enabled){auto it=state->pins.find(app);if(it!=state->pins.end()){PatchVector(primary,it->second);PatchVector(secondary,it->second);}}
    return result;
}
}
AppPins LoadPins(const Json::Value& config,const std::string& directory){
    AppPins result;if(!config["manifest_pinning"].boolean())return result;
    const bool autoComment=!config.has("auto_comment")||config["auto_comment"].boolean();
    std::unordered_set<uint32_t> selected;
    for(const auto& value:config["pinned_apps"].arrVal){auto id=value.integer();if(id>0&&id<=0xffffff)selected.insert((uint32_t)id);}
    const std::regex pattern(R"PIN(setManifestid\s*\(\s*([0-9]+)\s*,\s*"([0-9]+)")PIN",std::regex::icase);
    std::error_code error;
    for(const auto& file:std::filesystem::directory_iterator(directory,std::filesystem::directory_options::skip_permission_denied,error)){
        if(file.path().extension()!=".lua"||!file.is_regular_file(error)||file.file_size(error)>4*1024*1024)continue;
        std::string stem=file.path().stem().string();if(stem.empty()||stem.find_first_not_of("0123456789")!=std::string::npos)continue;
        uint64_t id=0;try{id=std::stoull(stem);}catch(...){continue;}if(!id||id>0xffffff||(autoComment&&!selected.count((uint32_t)id)))continue;
        std::ifstream input(file.path());std::string line;
        while(std::getline(input,line)){
            auto comment=line.find("--");if(comment!=std::string::npos)line.resize(comment);
            for(std::sregex_iterator it(line.begin(),line.end(),pattern),end;it!=end;++it){
                try{auto depot=std::stoull((*it)[1].str()),manifest=std::stoull((*it)[2].str());if(depot&&depot<=UINT32_MAX&&manifest)result[(uint32_t)id][(uint32_t)depot]=manifest;}catch(...){}
            }
        }
    }
    return result;
}
bool PatchVector(void* vector,const DepotPins& pins){
    if(!vector)return true;
    uintptr_t data=0;int count=0;
    if(!Read((uintptr_t)vector,data)||!Read((uintptr_t)vector+16,count)||count<0||count>4096)return false;
    if(count&&!data)return false;
    for(int i=0;i<count;++i){
        uintptr_t entry=data+(size_t)i*32;uint32_t depot=0;uint64_t old=0;
        if(!Read(entry,depot)||!Read(entry+8,old))return false;
        auto it=pins.find(depot);if(it==pins.end()||!it->second||old==it->second)continue;
        auto value=it->second;if(mach_vm_write(mach_task_self(),entry+8,(vm_offset_t)&value,sizeof(value))!=KERN_SUCCESS)return false;
        LOG("[ManifestPin] Native depot %u: %llu -> %llu",depot,(unsigned long long)old,(unsigned long long)value);
    }
    return true;
}
bool Initialize(const MacProfile::Profile& profile,const Json::Value& config,const std::string& steamPath){
    if(!config["manifest_pinning"].boolean())return true;
    void* target=profile.UniquePattern("FC 6F BA A9 FA 67 01 A9 F8 5F 02 A9 F6 57 03 A9 F4 4F 04 A9 FD 7B 05 A9 FD 43 01 91 FF C3 08 D1 FB 03 07 AA F9 03 06 AA E5 33 00 F9 F8 03 04 AA F4 03 03 AA F3 03 02 AA F5 03 01 AA F6 03 00 AA C8 87 00 90 08 B1 40 F9 08 01 40 F9 A8 03 1A F8");
    if(!target){LOG("[ManifestPin] Native dependency builder did not resolve uniquely");return false;}
    state=new State;state->pins=LoadPins(config,steamPath+"config/stplug-in");state->target=target;
    if(DobbyHook(target,(void*)Build,(void**)&state->original)!=0)return false;
    state->enabled=true;LOG("[ManifestPin] Native depot hook installed for %zu app(s)",state->pins.size());return true;
}
void Shutdown(){if(!state)return;state->enabled=false;if(state->target){DobbyDestroy(state->target);state->target=nullptr;}}
}
