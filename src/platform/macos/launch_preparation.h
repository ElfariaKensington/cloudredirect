#pragma once
#include "app_state.h"
#include <optional>
#include <string>
// Observe Steam launch events before cloud sync, and reserve the cloud session
// alongside ticket/installer work. Missing events or unknown client IDs fall
// through to the normal live RPC path. Unclaimed reservations are released.
namespace LaunchPreparation {
void Start(const std::string& storageRoot, const std::string& steamRoot, uint32_t accountId);
void RememberClient(uint64_t clientId);
std::optional<CloudStorage::StateFetchResult> State(uint32_t accountId, uint32_t appId);
std::optional<CloudStorage::SessionAcquireResult> Take(uint32_t accountId, uint32_t appId,
                                                      uint64_t clientId, bool force);
void Shutdown();
}
