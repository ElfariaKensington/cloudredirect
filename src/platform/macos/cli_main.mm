#include "cli.h"
#include "cloud_provider_base.h"
#include "xdg.h"
#include "json.h"
#include "native_profile.h"
#include "cloud_provider.h"
#include <fstream>
#include <unistd.h>
#include <iostream>
#include <iterator>
#include <string>
int main(int argc,char**argv) {
    if(argc==2 && std::string(argv[1])=="diagnose") {
        MacProfile::Profile profile; std::string error;
        bool ok=MacProfile::Resolve(profile,error,true)&&MacProfile::TestProtobuf(profile,error);
        auto result=Json::Object(); result.objVal["ok"].type=Json::Type::Bool;
        result.objVal["ok"].boolVal=ok; result.objVal["message"]=Json::String(ok?"ARM64 Steam cloud interfaces and protobuf round trip verified":error);
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
