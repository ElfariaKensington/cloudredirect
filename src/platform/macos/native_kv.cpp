#include "native_kv.h"
#include <cstring>
namespace MacProfile {
bool ResolveKv(const Profile& profile,SteamKvInjector::ResolvedKvAddrs& out,std::string& error){
    // RVAs apply only after Resolve's exact ARM64 Mach-O UUID check. Each entry
    // additionally verifies its audited instruction bytes before it can be used.
    {const uint8_t bytes[]={0xa,0x68,0x40,0xb9,0x5f,0x5,0x0,0x31,0xe0,0x1,0x0,0x54,0x8,0x40,0x40,0xf9};auto address=profile.slide+0x59fd60;if(!profile.Executable((void*)address)||memcmp((void*)address,bytes,sizeof(bytes))){error="Native KV entry failed validation: getAppInfo";return false;}out.getAppInfo=address;}
    {const uint8_t bytes[]={0x3f,0x14,0x0,0x71,0x2d,0x2,0x0,0x54,0x3f,0x50,0x0,0x71,0xe8,0x3,0x0,0x54};auto address=profile.slide+0x59c108;if(!profile.Executable((void*)address)||memcmp((void*)address,bytes,sizeof(bytes))){error="Native KV entry failed validation: getSection";return false;}out.getSection=address;}
    {const uint8_t bytes[]={0xf6,0x57,0xbd,0xa9,0xf4,0x4f,0x1,0xa9,0xfd,0x7b,0x2,0xa9,0xfd,0x83,0x0,0x91};auto address=profile.slide+0x59fefc;if(!profile.Executable((void*)address)||memcmp((void*)address,bytes,sizeof(bytes))){error="Native KV entry failed validation: readConfigU64";return false;}out.readConfigU64=address;}
    {const uint8_t bytes[]={0xfc,0x6f,0xba,0xa9,0xfa,0x67,0x1,0xa9,0xf8,0x5f,0x2,0xa9,0xf6,0x57,0x3,0xa9};auto address=profile.slide+0x1096b60;if(!profile.Executable((void*)address)||memcmp((void*)address,bytes,sizeof(bytes))){error="Native KV entry failed validation: kvFindKey";return false;}out.kvFindKey=address;}
    {const uint8_t bytes[]={0xff,0xc3,0x0,0xd1,0xf4,0x4f,0x1,0xa9,0xfd,0x7b,0x2,0xa9,0xfd,0x83,0x0,0x91};auto address=profile.slide+0x1097d50;if(!profile.Executable((void*)address)||memcmp((void*)address,bytes,sizeof(bytes))){error="Native KV entry failed validation: kvGetUint64";return false;}out.kvGetUint64=address;}
    {const uint8_t bytes[]={0xff,0xc3,0x0,0xd1,0xf4,0x4f,0x1,0xa9,0xfd,0x7b,0x2,0xa9,0xfd,0x83,0x0,0x91};auto address=profile.slide+0x1097acc;if(!profile.Executable((void*)address)||memcmp((void*)address,bytes,sizeof(bytes))){error="Native KV entry failed validation: kvGetInt";return false;}out.kvGetInt=address;}
    {const uint8_t bytes[]={0xc0,0x1,0x0,0xb4,0xf4,0x4f,0xbe,0xa9,0xfd,0x7b,0x1,0xa9,0xfd,0x43,0x0,0x91};auto address=profile.slide+0x1098644;if(!profile.Executable((void*)address)||memcmp((void*)address,bytes,sizeof(bytes))){error="Native KV entry failed validation: kvSetUint64";return false;}out.kvSetUint64=address;}
    {const uint8_t bytes[]={0xc0,0x1,0x0,0xb4,0xf4,0x4f,0xbe,0xa9,0xfd,0x7b,0x1,0xa9,0xfd,0x43,0x0,0x91};auto address=profile.slide+0x1098608;if(!profile.Executable((void*)address)||memcmp((void*)address,bytes,sizeof(bytes))){error="Native KV entry failed validation: kvSetInt";return false;}out.kvSetInt=address;}
    {const uint8_t bytes[]={0xa0,0x5,0x0,0xb4,0xf6,0x57,0xbd,0xa9,0xf4,0x4f,0x1,0xa9,0xfd,0x7b,0x2,0xa9};auto address=profile.slide+0x1098420;if(!profile.Executable((void*)address)||memcmp((void*)address,bytes,sizeof(bytes))){error="Native KV entry failed validation: kvSetString";return false;}out.kvSetString=address;}
    out.globalEnginePtrPtr=(void**)(profile.slide+0x1876438);
    if(!profile.Readable(out.globalEnginePtrPtr,sizeof(void*))){error="Native engine global is outside the audited image";return false;}
    out.appInfoCacheOffset=0x1518;return true;
}
bool TestKv(const SteamKvInjector::ResolvedKvAddrs& a,std::string& error,bool includeTree){
    // A standalone value node: never references Steam's live app-info cache.
    alignas(16) unsigned char node[64]={};
    auto setInt=(void(*)(void*,int))a.kvSetInt;auto getInt=(int(*)(void*,int,void*))a.kvGetInt;
    auto setU64=(void(*)(void*,uint64_t))a.kvSetUint64;auto getU64=(uint64_t(*)(void*,uint64_t,void*))a.kvGetUint64;
    auto setString=(void(*)(void*,const char*))a.kvSetString;
    setInt(node,12345);bool ok=getInt(node,0,nullptr)==12345;
    setU64(node,0x123456789abcdefULL);ok=ok&&getU64(node,0,nullptr)==0x123456789abcdefULL;
    setString(node,"2468");ok=ok&&getInt(node,0,nullptr)==2468;
    setInt(node,0); // Release any native string allocation before returning.
    if(includeTree){
        alignas(16) unsigned char tree[64]={};
        auto find=(void*(*)(void*,const char*,uint8_t,void*))a.kvFindKey;
        auto* quota=find(tree,"ufs/quota",1,nullptr);
        ok=ok&&quota;
        if(quota){setU64(quota,1073741824ULL);ok=ok&&find(tree,"ufs/quota",0,nullptr)==quota&&getU64(quota,0,nullptr)==1073741824ULL;}
        // Tree nodes are allocated in this short-lived diagnostic process only;
        // the runtime self-test never allocates a tree or touches the live cache.
    }
    if(!ok)error="Native KV value round trip failed";return ok;
}
}
