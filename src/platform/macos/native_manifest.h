#pragma once
#include "native_profile.h"
#include "json.h"
#include <unordered_map>
namespace NativeManifest {
using DepotPins=std::unordered_map<uint32_t,uint64_t>;
using AppPins=std::unordered_map<uint32_t,DepotPins>;
AppPins LoadPins(const Json::Value& config,const std::string& luaDirectory);
bool PatchVector(void* vector,const DepotPins& pins);
bool Initialize(const MacProfile::Profile& profile,const Json::Value& config,const std::string& steamPath);
void Shutdown();
}
