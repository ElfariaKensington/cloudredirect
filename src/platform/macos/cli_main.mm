#include "cli.h"
#include "cloud_provider_base.h"
#include "xdg.h"
#include "json.h"
#include "native_profile.h"
#include "native_kv.h"
#include "live_playtime.h"
#include "credential_broker.h"
#include "app_state.h"
#include "cloud_storage.h"
#include "cloud_provider.h"
#include <fstream>
#include <unistd.h>
#include <Security/Security.h>
#include <iostream>
#include <iterator>
#include <string>
int main(int argc,char**argv) {
    if(argc==5 && std::string(argv[1])=="list-cloud-save-files") {
        auto result=Json::Object();result.objVal["success"].type=Json::Type::Bool;
        auto fail=[&](const std::string& message){result.objVal["error"]=Json::String(message);std::cout<<Json::Stringify(result)<<std::endl;return 1;};
        std::string name=argv[2],root=XdgConfigHome()+"/CloudRedirect/";
        std::ifstream cfgFile(root+"config.json");std::string input((std::istreambuf_iterator<char>(cfgFile)),{});auto cfg=Json::Parse(input);
        char* end=nullptr;auto account=strtoul(argv[3],&end,10);if(!account||*end||account>UINT32_MAX)return fail("Invalid account");
        auto app=strtoul(argv[4],&end,10);if(!app||*end||app>0xffffff)return fail("Invalid game");
        auto provider=CreateCloudProvider(name);
        if(!provider||!provider->Init(name=="folder"?cfg["sync_path"].str():ResolveProviderTokenPath(root,input,name))||!provider->IsAuthenticated())return fail("Cloud provider is unavailable. Reconnect it in Cloud Provider.");
        const auto prefix=std::to_string(account)+"/"+std::to_string(app)+"/";
        std::vector<uint8_t> bytes;CloudStorage::CloudAppState state;
        if(provider->Download(prefix+"state.cloudredirect",bytes)) {
            if(bytes.size()>16*1024*1024||!CloudStorage::DeserializeState(std::string(bytes.begin(),bytes.end()),state))return fail("Invalid cloud save inventory");
        } else {
            if(provider->CheckExists(prefix+"state.cloudredirect")!=ICloudProvider::ExistsStatus::Missing)return fail("Could not read cloud save inventory");
            if(!provider->Download(prefix+"manifest.cloudredirect",bytes))return fail("No CloudRedirect save inventory found for this game in the selected cloud account.");
            if(bytes.size()>16*1024*1024)return fail("Cloud save inventory is too large");
            auto manifest=Json::Parse(std::string(bytes.begin(),bytes.end()));
            if(manifest.type!=Json::Type::Object)return fail("Invalid legacy cloud save inventory");
            for(const auto& [filename,value]:manifest.objVal){CloudStorage::FileEntry entry;entry.size=value["size"].integer();state.files[filename]=entry;}
        }
        auto files=Json::Array();uint64_t total=0;
        for(const auto& [filename,entry]:state.files){if(entry.persistState!=0)continue;auto file=Json::Object();file.objVal["name"]=Json::String(filename);file.objVal["size"]=Json::Number(entry.size);file.objVal["persisted"].type=Json::Type::Bool;file.objVal["persisted"].boolVal=true;files.arrVal.push_back(std::move(file));total+=entry.size;}
        provider->Shutdown();result.objVal["files"]=std::move(files);result.objVal["totalSize"]=Json::Number(total);result.objVal["success"].boolVal=true;
        std::cout<<Json::Stringify(result)<<std::endl;return 0;
    }
    if(argc==2 && std::string(argv[1])=="purge-credentials") {
        bool ok=true;
        for(auto service:{CFSTR("com.elfaria.cloudredirect.tokens"),CFSTR("com.elfaria.cloudredirect.credentials.v2")}){
            const void* keys[]={kSecClass,kSecAttrService};const void* values[]={kSecClassGenericPassword,service};
            auto query=CFDictionaryCreate(nullptr,keys,values,2,&kCFTypeDictionaryKeyCallBacks,&kCFTypeDictionaryValueCallBacks);
            auto status=SecItemDelete(query);CFRelease(query);ok=ok&&(status==errSecSuccess||status==errSecItemNotFound);
        }
        return ok?0:1;
    }
    if((argc==3||(argc==4&&std::string(argv[3])=="--background"))&&(std::string(argv[1])=="read-credentials-path"||std::string(argv[1])=="store-credentials-path")) {
        auto store=CreateTokenStore();
        if(std::string(argv[1])=="read-credentials-path") {
            auto value=store->Read(argv[2]);if(value.empty())return 1;
            std::cout<<value;return 0;
        }
        std::string value((std::istreambuf_iterator<char>(std::cin)),{});
        if(value.size()>1024*1024||Json::Parse(value).type!=Json::Type::Object)return 2;
        return (argc==4?store->Write(argv[2],value):MacCredentials::WriteInteractive(argv[2],value))?0:1;
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
        bool ok=MacCredentials::WriteInteractive(ResolveProviderTokenPath(root,config,provider),input);
        std::cout << (ok?"{\"ok\":true}":"{\"error\":\"Could not save credentials in Keychain\"}") << std::endl;
        return ok?0:1;
    }
    std::vector<char*> args{argv[0],(char*)"--cli"};
    for(int i=1;i<argc;++i)args.push_back(argv[i]);
    return CloudRedirect_CliMain((int)args.size(),args.data());
}
