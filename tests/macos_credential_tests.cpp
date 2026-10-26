#include "credential_broker.h"
#include <iostream>
#include <iterator>
#include <string>
#include <filesystem>
#include <fstream>
#include <sys/stat.h>
#include <unistd.h>
int main(int argc,char**argv){
 if(argc>=3){std::string input((std::istreambuf_iterator<char>(std::cin)),{});if(std::string(argv[2])!="fixture")return 2;std::cout<<input;return 0;}
 std::string output;
 if(!MacCredentials::Run(argv[0],"write","fixture","dummy credential",false,output)||output!="dummy credential")return 1;
 if(!MacCredentials::Run(argv[0],"write","fixture","foreground fixture",true,output)||output!="foreground fixture")return 1;
 if(MacCredentials::Run("/not/a/helper","read","fixture","",false,output)||!output.empty())return 1;
 if(MacCredentials::Run("/usr/bin/false","write","fixture",std::string(100000,'x'),false,output)||!output.empty())return 1;
 if(MacCredentials::Run(argv[0],"write","fixture",std::string(1024*1024+1,'x'),false,output))return 1;
 auto root=std::filesystem::temp_directory_path()/("cr-helper-selection-"+std::to_string(getpid()));
 std::filesystem::create_directory(root);
 auto installed=(root/"installed-helper").string();
 if(MacCredentials::SelectHelper("bundle-build-A",installed)!="bundle-build-A")return 1;
 {std::ofstream file(installed);file<<"fixture";}
 chmod(installed.c_str(),0600);
 if(MacCredentials::SelectHelper("bundle-build-A",installed)!="bundle-build-A")return 1;
 chmod(installed.c_str(),0700);
 if(MacCredentials::SelectHelper("bundle-build-A",installed)!=installed)return 1;
 if(MacCredentials::SelectHelper("bundle-build-B",installed)!=installed)return 1;
 std::filesystem::remove_all(root);
 std::cout<<"Credential helper IPC, failure handling and size limits passed\n";return 0;
}
