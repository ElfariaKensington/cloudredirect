#pragma once
#include <filesystem>
#include <fstream>
#include <string>
#include <vector>
#include <cstdint>
namespace LuaNamespace {
inline std::vector<uint32_t> Discover(const std::string& directory){
    std::vector<uint32_t> result;std::error_code error;
    for(const auto& entry:std::filesystem::directory_iterator(directory,std::filesystem::directory_options::skip_permission_denied,error)){
        if(entry.path().extension()!=".lua"||!entry.is_regular_file(error)||entry.is_symlink(error)||entry.file_size(error)>10*1024*1024)continue;
        std::string stem=entry.path().stem().string();if(stem.empty()||stem.find_first_not_of("0123456789")!=std::string::npos)continue;
        uint64_t id=0;try{id=std::stoull(stem);}catch(...){continue;}if(!id||id>0xffffff)continue;
        const std::string exact="addappid("+std::to_string(id)+")",arguments="addappid("+std::to_string(id)+",";
        std::ifstream file(entry.path());std::string line;
        while(std::getline(file,line)){
            auto begin=line.find_first_not_of(" \t");if(begin==std::string::npos)continue;
            std::string_view view(line.data()+begin,line.size()-begin);
            if(view.starts_with(exact)||view.starts_with(arguments)){result.push_back((uint32_t)id);break;}
        }
    }
    return result;
}
}
