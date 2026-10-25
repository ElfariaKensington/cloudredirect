#pragma once
#include <cstdint>
#include <string>
#include <vector>
namespace MacProfile {
using SerializeFn=void*(*)(void*,void*);
using ParseFn=int(*)(void*,const void*,int);
struct Range { uintptr_t begin,end; bool executable,writable; };
struct Profile {
    intptr_t slide=0;
    std::vector<Range> ranges;
    void** transport=nullptr;
    void** remoteStorage=nullptr;
    SerializeFn serialize=nullptr;
    ParseFn parse=nullptr;
    bool Readable(const void* p,size_t size) const;
    bool Executable(const void* p) const;
    void** FindVtable(const char* name) const;
    void* UniquePattern(const char* hex) const;
};
bool Resolve(Profile& out,std::string& error,bool allowLoad=false);
bool TestProtobuf(const Profile& profile,std::string& error);
bool ReplaceSlots(void** vtable,const std::vector<std::pair<size_t,void*>>& slots);
}
