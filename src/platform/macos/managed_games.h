#pragma once
#include "lua_namespace.h"
#include <set>
#include <regex>
namespace ManagedGames {
inline std::vector<uint32_t> Discover(const std::string& steam,const std::string& configHome){
    auto lua=LuaNamespace::Discover(steam+"/config/stplug-in");
    std::set<uint32_t> ids(lua.begin(),lua.end());
    const char* custom=getenv("MACSTEAM_CONFIG");
    std::ifstream file(custom&&*custom=='/'?custom:configHome+"/macsteam/config.yaml");
    bool apps=false;std::string line;std::regex item("^  -[ \\t]+([0-9]+)[ \\t]*(#.*)?$");std::smatch match;
    while(std::getline(file,line)){
        if(!line.empty()&&line.back()=='\r')line.pop_back();
        if(!line.empty()&&!isspace((unsigned char)line[0])&&line[0]!='#')apps=line=="Apps:"||line.starts_with("Apps: #");
        else if(apps&&std::regex_match(line,match,item))try{auto id=std::stoull(match[1]);if(id&&id<=0xffffff)ids.insert((uint32_t)id);}catch(...){}
    }
    return {ids.begin(),ids.end()};
}
}
