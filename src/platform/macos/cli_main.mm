#include "cli.h"
#include "cloud_provider_base.h"
#include "xdg.h"
#include "json.h"
#include "native_profile.h"
#include "native_kv.h"
#include "live_playtime.h"
#include "cloud_provider.h"
#include <fstream>
#include <unistd.h>
#include <Security/Security.h>
#include <iostream>
#include <iterator>
#include <string>
int main(int argc,char**argv) {
    if(argc==2 && std::string(argv[1])=="purge-credentials") {
        const void* keys[]={kSecClass,kSecAttrService};const void* values[]={kSecClassGenericPassword,CFSTR("com.elfaria.cloudredirect.tokens")};
        auto query=CFDictionaryCreate(nullptr,keys,values,2,&kCFTypeDictionaryKeyCallBacks,&kCFTypeDictionaryValueCallBacks);
        auto status=SecItemDelete(query);CFRelease(query);return status==errSecSuccess||status==errSecItemNotFound?0:1;
    }
    if(argc==3&&(std::string(argv[1])=="read-credentials-path"||std::string(argv[1])=="store-credentials-path")) {
        auto store=CreateTokenStore();
        if(std::string(argv[1])=="read-credentials-path") {
            auto value=store->Read(argv[2]);if(value.empty())return 1;
            std::cout<<value;return 0;
        }
        std::string value((std::istreambuf_iterator<char>(std::cin)),{});
        if(value.size()>1024*1024||Json::Parse(value).type!=Json::Type::Object)return 2;
        return store->Write(argv[2],value)?0:1;
    }
    if(argc==2 && std::string(argv[1])=="diagnose") {
        MacProfile::Profile profile; std::string error;
        SteamKvInjector::ResolvedKvAddrs kv;
        bool ok=MacProfile::Resolve(profile,error,true)&&MacProfile::TestProtobuf(profile,error)&&MacProfile::ResolveKv(profile,kv,error)&&MacProfile::TestKv(kv,error,true)&&LivePlaytime::Resolve(0,0,profile.parse)&&LivePlaytime::TestResponseLayout(error);
        auto result=Json::Object(); result.objVal["ok"].type=Json::Type::Bool;
        result.objVal["ok"].boolVal=ok; result.objVal["message"]=Json::String(ok?"ARM64 Steam cloud interfaces, protobuf, KV and playtime response checks verified":error);
        std::cout<<Json::Stringify(result)<<std::endl;
        _Exit(ok?0:1); // Steam's static destructors expect a real Steam process.
    }
    if(argc==2 && std::string(argv[1])=="check-provider") {
        std::string root=XdgConfigHome()+"/CloudRedirect/";
        std::ifstream file(root+"config.json"); std::string input((std::istreambuf_iterator<char>(file)),{});
        auto cfg=Json::Parse(input); auto name=cfg["provider"].str();
        auto provider=CreateCloudProvider(name);
        bool ok=name=="local";
        if(provider) ok=provider->Init(name=="folder"?cfg["sync_path"].str():ResolveProviderTokenPath(root,input,name))&&provider->IsAuthenticated();
        std::cout<<(ok?"{\"ok\":true}":"{\"ok\":false,\"message\":\"Provider initialization or authentication failed\"}")<<std::endl;
        return ok?0:1;
    }
    if(argc==3 && std::string(argv[1])=="store-credentials") {
        std::string provider=argv[2];
        if(provider!="gdrive"&&provider!="onedrive"&&provider!="s3"&&provider!="r2") return 2;
        std::string input((std::istreambuf_iterator<char>(std::cin)),{});
        if(input.size()>1024*1024||Json::Parse(input).type!=Json::Type::Object)return 2;
        auto store=CreateTokenStore();
        std::string root=XdgConfigHome()+"/CloudRedirect/";
        std::ifstream file(root+"config.json"); std::string config((std::istreambuf_iterator<char>(file)),{});
        bool ok=store->Write(ResolveProviderTokenPath(root,config,provider),input);
        std::cout << (ok?"{\"ok\":true}":"{\"error\":\"Could not save credentials in Keychain\"}") << std::endl;
        return ok?0:1;
    }
    std::vector<char*> args{argv[0],(char*)"--cli"};
    for(int i=1;i<argc;++i)args.push_back(argv[i]);
    return CloudRedirect_CliMain((int)args.size(),args.data());
}
