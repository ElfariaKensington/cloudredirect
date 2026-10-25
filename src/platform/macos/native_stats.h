#pragma once
#include "stats_hooks.h"
#include <string>
namespace NativeStats {
bool Initialize(const std::string& root,StatsHooks::SerializeFn serialize,StatsHooks::ParseFn parse);
void Shutdown();
}
