#pragma once
#include "native_profile.h"
#include "steam_kv_injector.h"
namespace MacProfile {
bool ResolveKv(const Profile& profile,SteamKvInjector::ResolvedKvAddrs& out,std::string& error);
bool TestKv(const SteamKvInjector::ResolvedKvAddrs& addresses,std::string& error,bool includeTree=false);
}
