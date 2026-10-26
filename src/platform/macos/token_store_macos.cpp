#ifdef CR_CREDENTIAL_HELPER
// Credentials are shared by the native app, CLI and injected runtime via Keychain.
#include "cloud_provider_base.h"
#include <Security/Security.h>
#include <CoreFoundation/CoreFoundation.h>
#include <fstream>
#include "xdg.h"
static bool interactiveCredentials=false;
class KeychainTokens final : public ITokenStore {
    CFMutableDictionaryRef Query(const std::string& path) {
        auto q = CFDictionaryCreateMutable(nullptr, 0, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
        auto key = CFStringCreateWithCString(nullptr, path.c_str(), kCFStringEncodingUTF8);
        CFDictionarySetValue(q, kSecClass, kSecClassGenericPassword);
        CFDictionarySetValue(q, kSecAttrService, CFSTR("com.elfaria.cloudredirect.credentials.v2"));
        CFDictionarySetValue(q, kSecAttrAccount, key);
        CFRelease(key);
        return q;
    }
public:
    std::string Read(const std::string& path) override {
        auto q = Query(path);
        CFDictionarySetValue(q, kSecReturnData, kCFBooleanTrue);
        // Background Steam must never block on an authentication prompt.
        CFDictionarySetValue(q, kSecUseAuthenticationUI, kSecUseAuthenticationUIFail);
        CFTypeRef result = nullptr;
        auto status = SecItemCopyMatching(q, &result); CFRelease(q);
        if (status != errSecSuccess || !result) return {};
        auto data = (CFDataRef)result;
        std::string value((const char*)CFDataGetBytePtr(data), CFDataGetLength(data));
        CFRelease(result); return value;
    }
    bool Write(const std::string& path, const std::string& json) override {
        auto q = Query(path);
        auto data = CFDataCreate(nullptr, (const UInt8*)json.data(), json.size());
        auto attrs = CFDictionaryCreateMutable(nullptr, 0, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
        CFDictionarySetValue(attrs, kSecValueData, data);
        if(!interactiveCredentials)CFDictionarySetValue(q,kSecUseAuthenticationUI,kSecUseAuthenticationUIFail);
        // Foreground reconnection repairs access for this helper's identity.
        if(interactiveCredentials){
            SecAccessRef access=nullptr;
            auto trusted=CFArrayCreateMutable(nullptr,0,&kCFTypeArrayCallBacks);
            SecTrustedApplicationRef application=nullptr;
            if(SecTrustedApplicationCreateFromPath(nullptr,&application)==errSecSuccess){CFArrayAppendValue(trusted,application);CFRelease(application);}
            if(SecAccessCreate(CFSTR("CloudRedirect credentials"),trusted,&access)==errSecSuccess){CFDictionarySetValue(attrs,kSecAttrAccess,access);CFRelease(access);}
            CFRelease(trusted);
        }
        auto status = SecItemUpdate(q, attrs);
        if (status == errSecItemNotFound) {
            CFDictionarySetValue(q, kSecValueData, data);
            // Only this standalone credential helper needs direct Keychain access.
            auto trusted=CFArrayCreateMutable(nullptr,0,&kCFTypeArrayCallBacks);
            SecTrustedApplicationRef application=nullptr;
            if(SecTrustedApplicationCreateFromPath(nullptr,&application)==errSecSuccess){CFArrayAppendValue(trusted,application);CFRelease(application);}
            SecAccessRef access=nullptr;
            if(SecAccessCreate(CFSTR("CloudRedirect credentials"),trusted,&access)==errSecSuccess){CFDictionarySetValue(q,kSecAttrAccess,access);CFRelease(access);}
            CFRelease(trusted);
            status = SecItemAdd(q, nullptr);
        }
        CFRelease(attrs); CFRelease(data); CFRelease(q);
        return status == errSecSuccess;
    }
    bool IsEncryptionAvailable() const override { return true; }
};
std::unique_ptr<ITokenStore> CreateTokenStore() { return std::make_unique<KeychainTokens>(); }

#else
#include "cloud_provider_base.h"
#include "credential_broker.h"
#include <dlfcn.h>
#include <filesystem>
#include <spawn.h>
#include <poll.h>
#include <sys/wait.h>
#include <sys/socket.h>
#include <signal.h>
#include <unistd.h>
#include <fcntl.h>
#include <cerrno>
#include <chrono>
extern char** environ;
namespace MacCredentials {
std::string SelectHelper(const std::string& bundled, const std::string& installed) {
    std::error_code error;
    // Both the UI and Steam must use the same Keychain-trusted executable.
    // A separately built ad-hoc helper has a different signing identity.
    if (std::filesystem::is_regular_file(installed, error) && access(installed.c_str(), X_OK) == 0)
        return installed;
    return bundled;
}
static std::string helper(){
    Dl_info info{};
    if(!dladdr((void*)&CreateTokenStore,&info)||!info.dli_fname)return {};
    return SelectHelper((std::filesystem::path(info.dli_fname).parent_path()/"cloud_redirect_credentials").string(),
        "/Applications/Steam.app/Contents/MacOS/cloud_redirect_credentials");
}
bool Run(const std::string& executable,const std::string& mode,const std::string& path,const std::string& input,bool interactive,std::string& output){
    output.clear();if(executable.empty()||input.size()>1024*1024)return false;
    int in[2],out[2];if(socketpair(AF_UNIX,SOCK_STREAM,0,in))return false;if(pipe(out)){close(in[0]);close(in[1]);return false;}
    int noSignal=1;setsockopt(in[1],SOL_SOCKET,SO_NOSIGPIPE,&noSignal,sizeof(noSignal));
    timeval timeout{interactive?120:10,0};setsockopt(in[1],SOL_SOCKET,SO_SNDTIMEO,&timeout,sizeof(timeout));
    for(int fd:{in[0],in[1],out[0],out[1]})fcntl(fd,F_SETFD,FD_CLOEXEC);
    posix_spawn_file_actions_t actions;posix_spawn_file_actions_init(&actions);
    posix_spawn_file_actions_adddup2(&actions,in[0],STDIN_FILENO);
    posix_spawn_file_actions_adddup2(&actions,out[1],STDOUT_FILENO);
    posix_spawn_file_actions_addopen(&actions,STDERR_FILENO,"/dev/null",O_WRONLY,0);
    const char* args[]={executable.c_str(),mode.c_str(),path.c_str(),interactive?"--interactive":nullptr,nullptr};
    pid_t child=0;int error=posix_spawn(&child,executable.c_str(),&actions,nullptr,(char*const*)args,environ);
    posix_spawn_file_actions_destroy(&actions);close(in[0]);close(out[1]);
    if(error){close(in[1]);close(out[0]);return false;}
    // The helper consumes stdin before any Keychain operation.
    size_t sent=0;while(sent<input.size()){auto n=write(in[1],input.data()+sent,input.size()-sent);if(n<0&&errno==EINTR)continue;if(n<=0)break;sent+=n;}close(in[1]);
    auto deadline=std::chrono::steady_clock::now()+std::chrono::seconds(interactive?120:10);bool complete=false;
    while(std::chrono::steady_clock::now()<deadline){
        pollfd fd{out[0],POLLIN|POLLHUP,0};int ready=poll(&fd,1,100);if(ready<0&&errno==EINTR)continue;if(ready<0)break;if(!ready)continue;
        char buffer[4096];auto n=read(out[0],buffer,sizeof(buffer));if(n<0&&errno==EINTR)continue;if(n==0){complete=true;break;}if(n<0||output.size()+n>1024*1024)break;output.append(buffer,n);
    }
    close(out[0]);if(!complete)kill(child,SIGKILL);int status=0;while(waitpid(child,&status,0)<0&&errno==EINTR){}
    if(!complete||!WIFEXITED(status)||WEXITSTATUS(status)!=0){output.clear();return false;}return true;
}
bool WriteInteractive(const std::string& path,const std::string& value){std::string out;return Run(helper(),"write",path,value,true,out);}
}
class BrokerTokens final:public ITokenStore {
public:
 std::string Read(const std::string& path)override{std::string out;MacCredentials::Run(MacCredentials::helper(),"read",path,"",false,out);return out;}
 bool Write(const std::string& path,const std::string& value)override{std::string out;return MacCredentials::Run(MacCredentials::helper(),"write",path,value,false,out);}
 bool IsEncryptionAvailable()const override{return true;}
};
std::unique_ptr<ITokenStore>CreateTokenStore(){return std::make_unique<BrokerTokens>();}
#endif
