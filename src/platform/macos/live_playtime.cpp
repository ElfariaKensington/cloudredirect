#include "live_playtime.h"
#include "native_profile.h"
#include "log.h"
#include <dobby.h>
#include <atomic>
#include <mutex>
#include <queue>
#include <cstring>
namespace LivePlaytime {
namespace {
MacProfile::Profile profile;
void* writer=nullptr;void** responseVtable=nullptr;
std::atomic<void*> user{nullptr};std::atomic<bool> installed{false};
std::mutex mutex;std::queue<std::vector<uint8_t>> pending;
void Capture(void*,DobbyRegisterContext* context){if(installed)user.store((void*)context->general.regs.x0,std::memory_order_release);}
}
bool Resolve(uintptr_t,size_t,ParseFromArrayFn){
    std::string error;if(!MacProfile::Resolve(profile,error))return false;
    writer=profile.UniquePattern("FF 43 01 D1 F8 5F 01 A9 F6 57 02 A9 F4 4F 03 A9 FD 7B 04 A9 FD 03 01 91 5F 04 00 71 2B 05 00 54 F3 03 01 AA F4 03 00 AA F7 03 02 2A 55 01 80 52 78 02 40 F9 16 0B 43 29 5F 00 15 6B 55 80 95 1A");
    const char* name="CPlayer_GetLastPlayedTimes_Response";
    responseVtable=profile.FindVtable((std::to_string(strlen(name))+name).c_str());
    if(!writer||!responseVtable){LOG("[Stats] Native live-playtime entries did not resolve uniquely");return false;}
    return TestResponseLayout(error);
}
bool TestResponseLayout(std::string& error){
    if(!responseVtable)return false;
    auto* message=((void*(*)(void*))responseVtable[3])(nullptr);if(!message)return false;
    const uint8_t bytes[]={0x0a,0x03,0x08,0xec,0x04};
    bool ok=profile.parse(message,bytes,sizeof(bytes))!=0;
    int count=*(int*)((uint8_t*)message+0x18);auto rep=*(uintptr_t*)((uint8_t*)message+0x20);
    ok=ok&&count==1&&rep;
    if(ok){auto game=*(uintptr_t*)(rep+8);ok=game&&*(uint32_t*)(game+0x18)==620;}
    ((void(*)(void*))responseVtable[1])(message);
    if(!ok)error="Native last-played response layout check failed";return ok;
}
bool InstallUserCapture(){if(!writer)return false;installed=true;if(DobbyInstrument(writer,Capture)!=0){installed=false;return false;}return true;}
void RemoveUserCapture(){installed=false;user=nullptr;if(writer)DobbyDestroy(writer);std::lock_guard<std::mutex> lock(mutex);while(!pending.empty())pending.pop();}
bool Ready(){return installed&&user.load(std::memory_order_acquire);}
void Apply(const std::vector<uint8_t>& body){
    auto* current=user.load(std::memory_order_acquire);if(!installed||!current||!responseVtable||body.empty())return;
    void* message=((void*(*)(void*))responseVtable[3])(nullptr);if(!message)return;
    if(profile.parse(message,body.data(),(int)body.size())){
        int count=*(int*)((uint8_t*)message+0x18);auto rep=*(uintptr_t*)((uint8_t*)message+0x20);
        if(count>0&&count<=100000&&rep){((uint32_t(*)(void*,void*,int))writer)(current,(void*)(rep+8),count);LOG("[Stats] Native live playtime applied for %d game(s)",count);}
    }
    ((void(*)(void*))responseVtable[1])(message);
}
void Queue(const std::vector<uint8_t>& body){if(body.empty())return;std::lock_guard<std::mutex> lock(mutex);pending.push(body);}
void DrainOnNetThread(){if(!Ready())return;std::queue<std::vector<uint8_t>> queue;{std::lock_guard<std::mutex> lock(mutex);queue.swap(pending);}while(!queue.empty()){Apply(queue.front());queue.pop();}}
}
