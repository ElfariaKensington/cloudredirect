// Credentials are shared by the native app, CLI and injected runtime via Keychain.
#include "cloud_provider_base.h"
#include <Security/Security.h>
#include <CoreFoundation/CoreFoundation.h>
#include <fstream>
#include "xdg.h"
class KeychainTokens final : public ITokenStore {
    CFMutableDictionaryRef Query(const std::string& path) {
        auto q = CFDictionaryCreateMutable(nullptr, 0, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
        auto key = CFStringCreateWithCString(nullptr, path.c_str(), kCFStringEncodingUTF8);
        CFDictionarySetValue(q, kSecClass, kSecClassGenericPassword);
        CFDictionarySetValue(q, kSecAttrService, CFSTR("com.elfaria.cloudredirect.tokens"));
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
        auto status = SecItemUpdate(q, attrs);
        if (status == errSecItemNotFound) {
            CFDictionarySetValue(q, kSecValueData, data);
            // Trust only the credential helper and the installed Steam executables.
            auto trusted=CFArrayCreateMutable(nullptr,0,&kCFTypeArrayCallBacks);
            SecTrustedApplicationRef application=nullptr;
            if(SecTrustedApplicationCreateFromPath(nullptr,&application)==errSecSuccess){CFArrayAppendValue(trusted,application);CFRelease(application);}
            for(auto path : {XdgHome()+"/Library/Application Support/Steam/Steam.AppBundle/Steam/Contents/MacOS/steam_osx",std::string("/Applications/Steam.app/Contents/MacOS/steam_osx")}) {
                if(SecTrustedApplicationCreateFromPath(path.c_str(),&application)==errSecSuccess){CFArrayAppendValue(trusted,application);CFRelease(application);}
            }
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
