// Kept independent of the runtime so feature rebuilds do not change its identity.
#define CR_CREDENTIAL_HELPER
#include "token_store_macos.cpp"
#import <Foundation/Foundation.h>
#include <iostream>
#include <iterator>
bool DeleteCredential(const std::string& path);
int main(int argc,char**argv){@autoreleasepool{
 if(argc==2&&std::string(argv[1])=="supports-delete")return 0;
 if(argc<3||argc>4)return 2;
 interactiveCredentials=argc==4&&std::string(argv[3])=="--interactive";
 SecKeychainSetUserInteractionAllowed(interactiveCredentials);
 if(std::string(argv[1])=="delete")return DeleteCredential(argv[2])?0:1;
 auto store=CreateTokenStore();std::string mode=argv[1];
 if(mode=="read") {auto value=store->Read(argv[2]);if(value.empty())return 1;std::cout<<value;return 0;}
 if(mode!="write")return 2;
 std::string value((std::istreambuf_iterator<char>(std::cin)),{});if(value.size()>1024*1024)return 2;
 NSData* data=[NSData dataWithBytes:value.data() length:value.size()];
 id json=[NSJSONSerialization JSONObjectWithData:data options:0 error:nil];if(![json isKindOfClass:NSDictionary.class])return 2;
 return store->Write(argv[2],value)?0:1;
}}
