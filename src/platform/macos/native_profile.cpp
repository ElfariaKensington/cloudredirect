#include "native_profile.h"
#include <mach-o/dyld.h>
#include <mach-o/loader.h>
#include <mach/mach.h>
#include <mach/mach_vm.h>
#include <dlfcn.h>
#include <cstring>
#include <cstdio>
#include <sstream>
#include <atomic>
#include <algorithm>
#include "xdg.h"
namespace MacProfile {
bool Profile::Readable(const void* p,size_t size) const {
    auto a=(uintptr_t)p;for(auto r:ranges)if(a>=r.begin&&a<=r.end&&size<=r.end-a)return true;return false;
}
bool Profile::Executable(const void* p) const {
    auto a=(uintptr_t)p;for(auto r:ranges)if(r.executable&&a>=r.begin&&a<r.end)return true;return false;
}
void** Profile::FindVtable(const char* name) const {
    void** found=nullptr;
    for(auto r:ranges)for(auto p=r.begin;p+strlen(name)+1<=r.end;++p) {
        if(memcmp((void*)p,name,strlen(name)+1))continue;
        for(auto rr:ranges){if(rr.executable)continue;
            for(auto q=(rr.begin+7)&~(uintptr_t)7;q+8<=rr.end;q+=8) {
                if(*(uintptr_t*)q!=p||q<rr.begin+8)continue;auto ti=q-8;
                for(auto rv:ranges){if(rv.executable)continue;
                    for(auto v=((rv.begin+15)&~(uintptr_t)7);v+8*12<=rv.end;v+=8){
                        if(*(uintptr_t*)v!=ti||*(intptr_t*)(v-8)!=0)continue;
                        auto** vt=(void**)(v+8);bool valid=true;
                        for(int k=0;k<10;k++)if(!Executable(vt[k]))valid=false;
                        if(valid){if(found&&found!=vt)return nullptr;found=vt;}
                    }
                }
            }
        }
    }
    return found;
}
void* Profile::UniquePattern(const char* hex) const {
    std::istringstream stream(hex);std::string word;std::vector<int> bytes;
    while(stream>>word)bytes.push_back(word=="??"?-1:std::stoi(word,nullptr,16));
    if(bytes.empty())return nullptr;
    void* found=nullptr;
    for(auto r:ranges){if(!r.executable)continue;for(auto p=r.begin;p+bytes.size()<=r.end;p+=4){
        bool match=true;for(size_t i=0;i<bytes.size();i++)if(bytes[i]>=0&&((uint8_t*)p)[i]!=bytes[i]){match=false;break;}
        if(match){if(found)return nullptr;found=(void*)p;}
    }}return found;
}
bool Resolve(Profile& out,std::string& error,bool allowLoad) {
    const mach_header_64* mh=nullptr;
    auto locate=[&](){for(uint32_t i=0;i<_dyld_image_count();++i){auto n=_dyld_get_image_name(i);if(n&&strstr(n,"/steamclient.dylib")){mh=(const mach_header_64*)_dyld_get_image_header(i);out.slide=_dyld_get_image_vmaddr_slide(i);break;}}};
    locate();
    if(!mh&&allowLoad){std::string path=XdgHome()+"/Library/Application Support/Steam/Steam.AppBundle/Steam/Contents/MacOS/steamclient.dylib";if(!dlopen(path.c_str(),RTLD_NOW|RTLD_LOCAL)){error=dlerror();return false;}locate();}
    if(!mh||mh->magic!=MH_MAGIC_64||mh->cputype!=CPU_TYPE_ARM64){error="ARM64 steamclient.dylib is not loaded";return false;}
    bool audited=false;
    out.ranges.clear();auto* c=(const load_command*)(mh+1);
    for(uint32_t i=0;i<mh->ncmds;++i){if(c->cmd==LC_UUID){const unsigned char expected[]={0x1d,0x28,0x26,0x16,0xb6,0x7e,0x30,0xa6,0xb0,0xaf,0xe4,0xd5,0x88,0x06,0x10,0xe7};audited=!memcmp(((const uuid_command*)c)->uuid,expected,16);}
        if(c->cmd==LC_SEGMENT_64){auto*s=(const segment_command_64*)c;if((s->initprot&VM_PROT_READ)&&s->filesize)out.ranges.push_back({s->vmaddr+out.slide,s->vmaddr+out.slide+s->filesize,(bool)(s->initprot&VM_PROT_EXECUTE),(bool)(s->initprot&VM_PROT_WRITE)});}c=(const load_command*)((const char*)c+c->cmdsize);}
    if(!audited){error="This Steam build has not been validated for ARM64 cloud interception; hooks remain inactive";return false;}
    out.transport=out.FindVtable("30CClientUnifiedServiceTransport");
    out.remoteStorage=out.FindVtable("18CUserRemoteStorage");
    out.serialize=(SerializeFn)out.UniquePattern("FF C3 02 D1 F6 57 08 A9 F4 4F 09 A9 FD 7B 0A A9 FD 83 02 91 F3 03 01 AA F4 03 00 AA ?? ?? ?? ?? ?? ?? ?? ?? 08 01 40 F9 A8 83 1D F8 08 00 40 F9 08 29 40 F9 00 01 3F D6");
    out.parse=(ParseFn)out.UniquePattern("F6 57 BD A9 F4 4F 01 A9 FD 7B 02 A9 FD 83 00 91 E2 01 F8 37 F4 03 01 AA F3 03 00 AA F5 03 02 2A 08 00 40 F9 08 15 40 F9 00 01 3F D6");
    if(!out.transport||!out.remoteStorage||!out.serialize||!out.parse){error=std::string("ARM64 profile missing:")+(out.transport?"":" transport")+(out.serialize?"":" serializer")+(out.parse?"":" parser");return false;}
    return true;
}
bool TestProtobuf(const Profile& p,std::string& error){
    auto** vt=p.FindVtable("35CCloud_GetAppFileChangelist_Request");
    if(!vt||!p.Executable(vt[3])){error="Cloud request factory unavailable";return false;}
    void* object=((void*(*)(void*))vt[3])(nullptr);
    if(!object){error="Cloud request factory failed";return false;}
    const uint8_t input[]={0x08,0xec,0x04}; // AppID 620, no disk/network access.
    bool ok=p.parse(object,input,sizeof(input))!=0;
    auto** actual=*(void***)object;
    size_t size=((size_t(*)(void*))actual[9])(object);
    std::vector<uint8_t> result(size);
    if(size!=sizeof(input))ok=false;
    if(ok){auto end=p.serialize(object,result.data());ok=end==result.data()+result.size()&&!memcmp(result.data(),input,sizeof(input));}
    ((void(*)(void*))actual[1])(object);
    if(!ok)error="Native protobuf round trip failed; hooks remain inactive";
    return ok;
}
bool ReplaceSlots(void** table,const std::vector<std::pair<size_t,void*>>& slots){
    if(!table||slots.empty())return false;
    const auto page=(uintptr_t)&table[slots.front().first]&~(uintptr_t)(vm_page_size-1);
    const auto end=((uintptr_t)&table[slots.back().first]+sizeof(void*)+vm_page_size-1)&~(uintptr_t)(vm_page_size-1);
    mach_vm_address_t region=page;mach_vm_size_t size=0;vm_region_basic_info_data_64_t info{};mach_msg_type_number_t count=VM_REGION_BASIC_INFO_COUNT_64;mach_port_t object=0;
    if(mach_vm_region(mach_task_self(),&region,&size,VM_REGION_BASIC_INFO_64,(vm_region_info_t)&info,&count,&object)!=KERN_SUCCESS)return false;
    if(object)mach_port_deallocate(mach_task_self(),object);
    if(region>page||region+size<end)return false;
    if(mach_vm_protect(mach_task_self(),page,end-page,false,VM_PROT_READ|VM_PROT_WRITE|VM_PROT_COPY)!=KERN_SUCCESS)return false;
    for(auto [slot,fn]:slots)std::atomic_ref<void*>(table[slot]).store(fn,std::memory_order_release);
    return mach_vm_protect(mach_task_self(),page,end-page,false,info.protection)==KERN_SUCCESS;
}
}
