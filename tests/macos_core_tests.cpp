#include "platform.h"
#include "autocloud_util.h"
#include "local_disk_provider.h"
#include "http_server.h"
#include "cloud_work_queue.h"
#include "json.h"
#include <curl/curl.h>
#include <filesystem>
#include <stdexcept>
#include <thread>
#include <cstdio>
#include <unistd.h>
#include <sys/wait.h>
#define CHECK(x) do {if(!(x))throw std::runtime_error(#x);}while(0)
static size_t Discard(char*,size_t a,size_t b,void*){return a*b;}
int main(int argc,char**argv) {
    if(argc==2) {
        auto* curl=curl_easy_init();curl_easy_setopt(curl,CURLOPT_URL,argv[1]);curl_easy_setopt(curl,CURLOPT_TIMEOUT,5L);curl_easy_setopt(curl,CURLOPT_WRITEFUNCTION,Discard);
        long status=0;auto result=curl_easy_perform(curl);curl_easy_getinfo(curl,CURLINFO_RESPONSE_CODE,&status);curl_easy_cleanup(curl);
        return result!=CURLE_OK&&status==0?0:1;
    }
    char pattern[]="/tmp/cr-macos-tests-XXXXXX";auto* directory=mkdtemp(pattern);CHECK(directory);
    std::string root=directory;setenv("CLOUDREDIRECT_CONFIG_HOME",root.c_str(),1);
    try {
        CHECK(AutoCloudUtil::AutoCloudRuleMatchesCurrentPlatform(2));
        CHECK(!AutoCloudUtil::AutoCloudRuleMatchesCurrentPlatform(8));
        auto hash=Platform().SHA1("abc",3);CHECK(hash.size()==20&&hash[0]==0xa9&&hash[19]==0x9d);
        auto provider=CreateCloudProvider("folder");CHECK(provider&&provider->Init(root+"/remote"));
        CloudWorkQueue::SetWorkerThreadCount(1);
        for(int i=0;i<12;i++){CloudWorkQueue::Init(provider.get(),nullptr);CloudWorkQueue::Shutdown();}
        const std::vector<uint8_t> input={'s','a','v','e',0,0xff};std::vector<uint8_t> output;
        CHECK(provider->Upload("1/620/blobs/save",input.data(),input.size()));
        CHECK(provider->Download("1/620/blobs/save",output)&&input==output);
        CHECK(provider->CheckExists("1/620/blobs/save")==ICloudProvider::ExistsStatus::Exists);
        std::vector<ICloudProvider::FileInfo> files;bool complete=false;
        CHECK(provider->ListChecked("1/620/",files,&complete)&&complete&&files.size()==1);
        CHECK(!provider->Upload("../escape",input.data(),input.size()));
        std::filesystem::create_directory_symlink(root,root+"/remote/escape");
        CHECK(!provider->Upload("escape/outside",input.data(),input.size()));
        CHECK(provider->Remove("1/620/blobs/save"));
        CHECK(provider->CheckExists("1/620/blobs/save")==ICloudProvider::ExistsStatus::Missing);
        std::vector<std::thread> writers;
        for(int i=0;i<8;i++)writers.emplace_back([&,i](){for(int j=0;j<20;j++)CHECK(Platform().AtomicWriteText(root+"/atomic",std::string(8192,'a'+i)));});
        for(auto& t:writers)t.join();
        std::ifstream file(root+"/atomic");std::string content((std::istreambuf_iterator<char>(file)),{});
        CHECK(content.size()==8192&&content.find_first_not_of(content[0])==std::string::npos);
        CHECK(HttpServer::Start(root+"/blobs",1));
        std::string url="http://127.0.0.1:"+std::to_string(HttpServer::GetPort())+"/not-found";
        auto* curl=curl_easy_init();curl_easy_setopt(curl,CURLOPT_URL,url.c_str());curl_easy_setopt(curl,CURLOPT_TIMEOUT,5L);curl_easy_setopt(curl,CURLOPT_WRITEFUNCTION,Discard);
        long status=0;CHECK(curl_easy_perform(curl)==CURLE_OK);curl_easy_getinfo(curl,CURLINFO_RESPONSE_CODE,&status);curl_easy_cleanup(curl);
        CHECK(status==404); // Same-process transfer accepted, missing blob.
        auto child=fork();CHECK(child>=0);
        if(child==0){execl(argv[0],argv[0],url.c_str(),nullptr);_Exit(2);}
        int result=0;waitpid(child,&result,0);CHECK(WIFEXITED(result)&&WEXITSTATUS(result)==0); // Other process forbidden.
        HttpServer::Stop();std::filesystem::remove_all(root);puts("macOS storage, concurrency and HTTP isolation checks passed");
    } catch(const std::exception&e){HttpServer::Stop();std::filesystem::remove_all(root);fprintf(stderr,"FAIL: %s\n",e.what());return 1;}
}
