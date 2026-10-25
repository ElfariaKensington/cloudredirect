#pragma once
#include <string>
namespace MacCredentials {
bool Run(const std::string& executable,const std::string& mode,const std::string& path,const std::string& input,bool interactive,std::string& output);
bool WriteInteractive(const std::string& path,const std::string& value);
}
