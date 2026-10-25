#include "native_lua.h"
#include "cloud_intercept.h"
#include "cloud_storage.h"
#include "metadata_sync.h"
#include "json.h"
#include "file_util.h"
#include "miniz.h"
#include "log.h"
#include <filesystem>
#include <fstream>
#include <unordered_set>
#include <unordered_map>
#include <thread>
#include <chrono>
#include <strings.h>
#include <sys/stat.h>
namespace {
std::thread* worker=nullptr;
static bool IsSelfUnlockingLua(const std::string&,uint32_t);
// Lua file sync: stplug-in/*.lua via account-scope LuaArchive.zip + LuaManifest.json (appId=0).
// Union/grow-only: luas are only added or extracted, never deleted across machines.

static constexpr uint32_t LUA_SYNC_APPID = 0;

struct SyncState {
    uint64_t lastSyncTime = 0;
    std::unordered_set<std::string> files;
};

static std::string GetLuaSyncStatePath() {
    return CloudIntercept::GetSteamPath() + "config/stplug-in/.sync_state";
}

[[maybe_unused]] static SyncState ReadSyncState() {
    SyncState state;
    std::ifstream f(FileUtil::Utf8ToPath(GetLuaSyncStatePath()));
    if (!f.is_open()) return state;
    std::string line;
    // First line is the timestamp
    if (std::getline(f, line)) {
        while (!line.empty() && (line.back() == '\r' || line.back() == '\n'))
            line.pop_back();
        state.lastSyncTime = strtoull(line.c_str(), nullptr, 10);
    }
    while (std::getline(f, line)) {
        while (!line.empty() && (line.back() == '\r' || line.back() == '\n'))
            line.pop_back();
        if (!line.empty()) state.files.insert(line);
    }
    return state;
}

static void WriteSyncState(uint64_t syncTime, const std::unordered_set<std::string>& files) {
    std::string path = GetLuaSyncStatePath();
    std::error_code ec;
    std::filesystem::create_directories(FileUtil::Utf8ToPath(path).parent_path(), ec);
    // Atomic-write to avoid a half-truncated .sync_state on crash.
    std::string content;
    content += std::to_string(syncTime);
    content += '\n';
    for (auto& s : files) {
        content += s;
        content += '\n';
    }
    if (!FileUtil::AtomicWriteText(path, content)) {
        LOG("[LuaSync] Failed to write .sync_state");
    }
}

struct LuaFile {
    std::string filename;           // e.g. "1229490.lua"
    std::vector<uint8_t> content;
    uint64_t modTime;               // file modification time (unix seconds)
};

// Only allow plain "name.lua" filenames (no paths, no ..)
static bool IsValidLuaFilename(const std::string& name) {
    if (name.empty()||name.find('\0')!=std::string::npos) return false;
    if (name.find('/') != std::string::npos) return false;
    if (name.find('\\') != std::string::npos) return false;
    if (name.find("..") != std::string::npos) return false;
    if (name.find(':') != std::string::npos) return false;
    if (name.find('\n') != std::string::npos) return false;
    if (name.find('\r') != std::string::npos) return false;
    if (name.size() < 5) return false; // minimum: "X.lua"
    if (name.compare(name.size() - 4, 4, ".lua") != 0) return false;

    // Block Windows reserved device names (CON.lua, NUL.lua, etc.)
    std::string stem = name.substr(0, name.size() - 4);
    // Strip trailing dot for things like "CON..lua" edge cases
    while (!stem.empty() && stem.back() == '.') stem.pop_back();
    if (!stem.empty()) {
        static const char* reserved[] = {
            "CON","PRN","AUX","NUL",
            "COM1","COM2","COM3","COM4","COM5","COM6","COM7","COM8","COM9",
            "LPT1","LPT2","LPT3","LPT4","LPT5","LPT6","LPT7","LPT8","LPT9"
        };
        for (auto r : reserved) {
            if (strcasecmp(stem.c_str(), r) == 0) return false;
        }
    }
    return true;
}

// Reject binary content (NUL bytes in the first 8KB)
static bool IsValidLuaContent(const uint8_t* data, size_t len) {
    size_t check = (len < 8192) ? len : 8192;
    return memchr(data, '\0', check) == nullptr;
}

static std::vector<LuaFile> ReadLocalLuaFiles() {
    std::vector<LuaFile> files;
    std::string directory=CloudIntercept::GetSteamPath()+"config/stplug-in/";
    std::error_code error;
    for(const auto& entry:std::filesystem::directory_iterator(directory,std::filesystem::directory_options::skip_permission_denied,error)){
        std::string name=entry.path().filename().string();
        if(!IsValidLuaFilename(name)||!entry.is_regular_file(error)||entry.is_symlink(error))continue;
        auto length=entry.file_size(error);if(error||length==0||length>10*1024*1024)continue;
        LuaFile file;file.filename=name;file.content.resize(length);
        std::ifstream input(entry.path(),std::ios::binary);
        input.read((char*)file.content.data(),length);
        if(!input||!IsValidLuaContent(file.content.data(),file.content.size()))continue;
        struct stat info{};if(stat(entry.path().c_str(),&info))continue;file.modTime=info.st_mtime;files.push_back(std::move(file));
    }
    return files;
}

static std::vector<uint8_t> CreateLuaZip(const std::vector<LuaFile>& files) {
    size_t total=0;
    for(const auto& file:files){if(file.content.size()>10*1024*1024||file.content.size()>100*1024*1024-total){LOG("[LuaSync] Archive exceeds extraction bounds; refusing partial publication");return {};}total+=file.content.size();}
    mz_zip_archive zip{};
    if (!mz_zip_writer_init_heap(&zip, 0, 0)) {
        LOG("[LuaSync] Failed to init zip writer");
        return {};
    }
    for (auto& lf : files) {
        if (!mz_zip_writer_add_mem(&zip, lf.filename.c_str(),
                lf.content.data(), lf.content.size(), MZ_DEFAULT_COMPRESSION)) {
            LOG("[LuaSync] Failed to add %s to zip", lf.filename.c_str());
            mz_zip_writer_end(&zip);
            return {};
        }
    }
    void* buf = nullptr;
    size_t bufSize = 0;
    if (!mz_zip_writer_finalize_heap_archive(&zip, &buf, &bufSize)) {
        LOG("[LuaSync] Failed to get heap archive");
        mz_zip_writer_end(&zip);
        return {};
    }
    std::vector<uint8_t> result(static_cast<uint8_t*>(buf),
                                 static_cast<uint8_t*>(buf) + bufSize);
    mz_free(buf);
    mz_zip_writer_end(&zip);
    return result;
}

// Per-file manifest entry: mod time + optional deletion time
struct ManifestEntry {
    uint64_t mod = 0;
    uint64_t del = 0;   // 0 means not deleted; del > mod means deleted
    bool isDeleted() const { return del > mod; }
};

using CloudManifest = std::unordered_map<std::string, ManifestEntry>;

// Parse manifest JSON. Handles both new format ({ "f.lua": { "mod": N, "del": N } })
// and old format ({ "f.lua": N }) for migration.
static CloudManifest ParseManifest(const std::vector<uint8_t>& data) {
    CloudManifest manifest;
    if (data.empty()) return manifest;
    std::string mstr(reinterpret_cast<const char*>(data.data()), data.size());
    auto parsed = Json::Parse(mstr);
    if (parsed.type != Json::Type::Object) return manifest;
    for (auto& [key, val] : parsed.objVal) {
        ManifestEntry entry;
        if (val.type == Json::Type::Number) {
            // Old format: bare number is mod time
            entry.mod = static_cast<uint64_t>(val.numVal);
        } else if (val.type == Json::Type::Object) {
            if (val.has("mod")) {
                auto& m = val["mod"];
                if (m.type == Json::Type::Number)
                    entry.mod = static_cast<uint64_t>(m.numVal);
                else if (m.type == Json::Type::String)
                    entry.mod = strtoull(m.strVal.c_str(), nullptr, 10);
            }
            if (val.has("del")) {
                auto& d = val["del"];
                if (d.type == Json::Type::Number)
                    entry.del = static_cast<uint64_t>(d.numVal);
                else if (d.type == Json::Type::String)
                    entry.del = strtoull(d.strVal.c_str(), nullptr, 10);
            }
        }
        manifest[key] = entry;
    }
    return manifest;
}

static std::string SerializeManifest(const CloudManifest& manifest) {
    Json::Value root = Json::Object();
    for (auto& [filename, entry] : manifest) {
        Json::Value obj = Json::Object();
        obj.objVal["mod"] = Json::String(std::to_string(entry.mod));
        if (entry.del > 0)
            obj.objVal["del"] = Json::String(std::to_string(entry.del));
        root.objVal[filename] = obj;
    }
    return Json::Stringify(root);
}

static uint64_t NowUnix() {
    return static_cast<uint64_t>(std::chrono::duration_cast<std::chrono::seconds>(
        std::chrono::system_clock::now().time_since_epoch()).count());
}

static void SyncLuaFiles() {
    if (!CloudStorage::IsCloudActive()) {
        LOG("[LuaSync] Cloud not active, skipping lua sync");
        return;
    }
    uint32_t accountId = CloudIntercept::GetAccountId();
    if (!accountId) {
        LOG("[LuaSync] No account ID yet, skipping lua sync");
        return;
    }

    std::string luaDir = CloudIntercept::GetSteamPath() + "config/stplug-in/";
    uint64_t now = NowUnix();

    std::vector<uint8_t> manifestData;
    if(CloudStorage::FetchCloudMetadataStatus(accountId,LUA_SYNC_APPID,"blobs/LuaManifest.json",manifestData)==CloudStorage::MetadataFetch::Error){LOG("[LuaSync] Cloud manifest unavailable; retaining local and remote files");return;}
    auto cloudManifest = ParseManifest(manifestData);

    bool hasAlive = false;
    for (auto& [f, e] : cloudManifest) { if (!e.isDeleted()) { hasAlive = true; break; } }
    std::vector<uint8_t> archiveData;
    if (hasAlive) {
        if(CloudStorage::FetchCloudMetadataStatus(accountId,LUA_SYNC_APPID,"blobs/LuaArchive.zip",archiveData)!=CloudStorage::MetadataFetch::Ok||archiveData.empty()){LOG("[LuaSync] Cloud archive unavailable; refusing to overwrite it");return;}
    }

    // Parse archive into a map
    std::unordered_map<std::string, std::vector<uint8_t>> cloudFiles;
    if (!archiveData.empty()) {
        mz_zip_archive zip{};
        if (mz_zip_reader_init_mem(&zip, archiveData.data(), archiveData.size(), 0)) {
            mz_uint numFiles = mz_zip_reader_get_num_files(&zip);
            constexpr mz_uint MAX_ZIP_ENTRIES = 10000;
            if (numFiles > MAX_ZIP_ENTRIES) {
                LOG("[LuaSync] Archive has too many entries (%u), skipping", numFiles);
                mz_zip_reader_end(&zip);
            } else {
            size_t totalExtracted = 0;
            constexpr size_t MAX_TOTAL_SIZE = 100 * 1024 * 1024; // 100 MB aggregate
            for (mz_uint i = 0; i < numFiles; i++) {
                char fname[256];
                // Probe true name size first; miniz's silent post-clamp truncation could chop "../" and slip past IsValidLuaFilename.
                mz_uint nameLenPlusNul = mz_zip_reader_get_filename(&zip, i, nullptr, 0);
                if (nameLenPlusNul == 0) {
                    LOG("[LuaSync] Skipping zip entry %u: corrupt or missing CDH", i);
                    continue;
                }
                if (nameLenPlusNul > sizeof(fname)) {
                    LOG("[LuaSync] Skipping zip entry %u: overlength filename (%u bytes)",
                        i, nameLenPlusNul);
                    continue;
                }
                mz_zip_reader_get_filename(&zip, i, fname, sizeof(fname));
                if (!IsValidLuaFilename(fname)) {
                    LOG("[LuaSync] Skipping invalid zip entry: %s", fname);
                    continue;
                }
                // Check declared size before allocating
                mz_zip_archive_file_stat fstat;
                if (!mz_zip_reader_file_stat(&zip, i, &fstat)) continue;
                constexpr size_t MAX_LUA_SIZE = 10 * 1024 * 1024; // 10 MB
                if (fstat.m_uncomp_size > MAX_LUA_SIZE) {
                    LOG("[LuaSync] Skipping oversized zip entry: %s (%llu bytes)", fname, (unsigned long long)fstat.m_uncomp_size);
                    continue;
                }
                totalExtracted += static_cast<size_t>(fstat.m_uncomp_size);
                if (totalExtracted > MAX_TOTAL_SIZE) {
                    LOG("[LuaSync] Total extracted size exceeds %zuMB limit, stopping", MAX_TOTAL_SIZE / (1024*1024));
                    break;
                }
                size_t uncompSize = 0;
                void* p = mz_zip_reader_extract_to_heap(&zip, i, &uncompSize, 0);
                if (p) {
                    if (!IsValidLuaContent(static_cast<uint8_t*>(p), uncompSize)) {
                        LOG("[LuaSync] Skipping binary zip entry: %s", fname);
                        mz_free(p);
                        continue;
                    }
                    cloudFiles[fname] = std::vector<uint8_t>(
                        static_cast<uint8_t*>(p), static_cast<uint8_t*>(p) + uncompSize);
                    mz_free(p);
                }
            }
            mz_zip_reader_end(&zip);
            }
        } else {
            LOG("[LuaSync] Failed to open cloud archive: %s",
                mz_zip_get_error_string(mz_zip_get_last_error(&zip)));
        }
    }

    auto localFiles = ReadLocalLuaFiles();
    std::unordered_map<std::string, uint64_t> localByName; // filename -> modTime
    for (auto& lf : localFiles) localByName[lf.filename] = lf.modTime;

    int extracted = 0, addedToCloud = 0;
    bool manifestChanged = false;

    // Extract cloud luas missing locally; never delete or tombstone.
    for (auto& [filename, entry] : cloudManifest) {
        if (!IsValidLuaFilename(filename)) {
            LOG("[LuaSync] Skipping invalid manifest entry: %s", filename.c_str());
            continue;
        }
        bool onDisk = localByName.count(filename) > 0;

        if (!onDisk) {
            auto it = cloudFiles.find(filename);
            if (it != cloudFiles.end()) {
                std::error_code ec;
                // Route via Utf8ToPath: create_directories on std::string narrows via ACP internally.
                std::filesystem::create_directories(FileUtil::Utf8ToPath(luaDir), ec);
                std::string destPath = luaDir + filename;
                // Atomic-write so a crash never leaves a partial lua.
                if (FileUtil::AtomicWriteBinary(destPath, it->second.data(), it->second.size())) {
                    localByName[filename] = entry.mod;
                    extracted++;
                    LOG("[LuaSync] Extracted new lua: %s (%zu bytes)", filename.c_str(), it->second.size());
                } else {
                    LOG("[LuaSync] Failed to extract lua %s", filename.c_str());
                }
            }
        }
    }

    if (extracted > 0) {
        localFiles = ReadLocalLuaFiles();
        localByName.clear();
        for (auto& lf : localFiles) localByName[lf.filename] = lf.modTime;

        {
            for (auto& lf : localFiles) {
                auto dot = lf.filename.rfind('.');
                if (dot != std::string::npos) {
                    uint32_t appId = (uint32_t)strtoul(lf.filename.substr(0, dot).c_str(), nullptr, 10);
                    if (appId) {
                        std::string luaPath = CloudIntercept::GetSteamPath() + "config/stplug-in/" + lf.filename;
                        if (IsSelfUnlockingLua(luaPath, appId))
                            CloudIntercept::RegisterNamespaceApp(appId);
                    }
                }
            }


        }
    }

    // Propagate local additions up; never remove or tombstone entries.
    for (auto& [filename, modTime] : localByName) {
        auto it = cloudManifest.find(filename);
        if (it == cloudManifest.end()) {
            cloudManifest[filename] = { modTime, 0 };
            addedToCloud++;
            manifestChanged = true;
        }
    }

    bool needUpload = manifestChanged || extracted > 0;
    if (!needUpload && cloudManifest.empty() && !localFiles.empty()) {
        needUpload = true;
        LOG("[LuaSync] Cloud empty, seeding %zu lua files", localFiles.size());
        for (auto& lf : localFiles)
            cloudManifest[lf.filename] = { lf.modTime, 0 };
    }

    if (needUpload) {
        // Archive = union of cloud archive and local luas; local bytes win on collision.
        std::unordered_map<std::string, std::vector<uint8_t>> unionFiles = cloudFiles;
        for (auto& lf : localFiles)
            unionFiles[lf.filename] = lf.content;

        std::vector<LuaFile> archiveFiles;
        archiveFiles.reserve(unionFiles.size());
        for (auto& [filename, content] : unionFiles) {
            if (cloudManifest.count(filename) == 0) continue;
            LuaFile lf;
            lf.filename = filename;
            lf.content = content;
            lf.modTime = cloudManifest[filename].mod;
            archiveFiles.push_back(std::move(lf));
        }

        if (!archiveFiles.empty()) {
            auto zipData = CreateLuaZip(archiveFiles);
            if (zipData.empty()) return;
            if (!zipData.empty()) {
                CloudStorage::StoreBlob(accountId, LUA_SYNC_APPID,
                    "LuaArchive.zip", zipData.data(), zipData.size());
                LOG("[LuaSync] Uploaded archive (union): %zu files, %zu bytes zip",
                    archiveFiles.size(), zipData.size());
            }
        }

        std::string manifestStr = SerializeManifest(cloudManifest);
        CloudStorage::StoreBlob(accountId, LUA_SYNC_APPID, "LuaManifest.json",
            reinterpret_cast<const uint8_t*>(manifestStr.data()), manifestStr.size());
    }

    std::unordered_set<std::string> newFiles;
    for (auto& [filename, entry] : cloudManifest) {
        if (!entry.isDeleted()) newFiles.insert(filename);
    }
    WriteSyncState(now, newFiles);

    LOG("[LuaSync] Sync complete: %d extracted, %d added to cloud (union, grow-only)",
        extracted, addedToCloud);
}

// Shutdown upload: propagate local lua additions only; never tombstone (grow-only).
static void UploadLuaOnShutdown() {
    if (!CloudStorage::IsCloudActive()) return;
    uint32_t accountId = CloudIntercept::GetAccountId();
    if (!accountId) return;

    uint64_t now = NowUnix();

    std::vector<uint8_t> manifestData;
    if(CloudStorage::FetchCloudMetadataStatus(accountId,LUA_SYNC_APPID,"blobs/LuaManifest.json",manifestData)==CloudStorage::MetadataFetch::Error){LOG("[LuaSync] Cloud manifest unavailable; retaining local and remote files");return;}
    auto cloudManifest = ParseManifest(manifestData);

    bool hasCloudAlive = false;
    for (auto& [f, e] : cloudManifest) { if (!e.isDeleted()) { hasCloudAlive = true; break; } }
    std::unordered_map<std::string, std::vector<uint8_t>> cloudFiles;
    if (hasCloudAlive) {
        std::vector<uint8_t> archiveData;
        if(CloudStorage::FetchCloudMetadataStatus(accountId,LUA_SYNC_APPID,"blobs/LuaArchive.zip",archiveData)!=CloudStorage::MetadataFetch::Ok||archiveData.empty()){LOG("[LuaSync] Shutdown cloud archive unavailable; retaining remote files");return;}
        if (!archiveData.empty()) {
            mz_zip_archive zip{};
            if (mz_zip_reader_init_mem(&zip, archiveData.data(), archiveData.size(), 0)) {
                mz_uint numFiles = mz_zip_reader_get_num_files(&zip);
                for (mz_uint i = 0; i < numFiles && numFiles <= 10000; i++) {
                    mz_uint nameLenPlusNul = mz_zip_reader_get_filename(&zip, i, nullptr, 0);
                    if (nameLenPlusNul == 0 || nameLenPlusNul > 256) continue;
                    char fname[256];
                    mz_zip_reader_get_filename(&zip, i, fname, sizeof(fname));
                    if (!IsValidLuaFilename(fname)) continue;
                    mz_zip_archive_file_stat stat{};
                    if(!mz_zip_reader_file_stat(&zip,i,&stat)||stat.m_uncomp_size>10*1024*1024)continue;
                    size_t uncompSize = 0;
                    void* p = mz_zip_reader_extract_to_heap(&zip, i, &uncompSize, 0);
                    if (p) {
                        if (IsValidLuaContent(static_cast<uint8_t*>(p), uncompSize))
                            cloudFiles[fname] = std::vector<uint8_t>(
                                static_cast<uint8_t*>(p), static_cast<uint8_t*>(p) + uncompSize);
                        mz_free(p);
                    }
                }
                mz_zip_reader_end(&zip);
            }
        }
    }

    auto localFiles = ReadLocalLuaFiles();
    std::unordered_map<std::string, uint64_t> localByName;
    for (auto& lf : localFiles) localByName[lf.filename] = lf.modTime;

    bool changed = false;

    // Add new local files to the manifest; never tombstone.
    for (auto& [filename, modTime] : localByName) {
        auto it = cloudManifest.find(filename);
        if (it == cloudManifest.end()) {
            cloudManifest[filename] = { modTime, 0 };
            changed = true;
        }
    }

    if (!changed && !cloudManifest.empty()) {
        LOG("[LuaSync] Shutdown: no changes to upload");
        std::unordered_set<std::string> newFiles;
        for (auto& [f, e] : cloudManifest) { if (!e.isDeleted()) newFiles.insert(f); }
        WriteSyncState(now, newFiles);
        return;
    }

    // Archive = union of cloud archive and local luas.
    std::unordered_map<std::string, std::vector<uint8_t>> unionFiles = cloudFiles;
    for (auto& lf : localFiles)
        unionFiles[lf.filename] = lf.content;

    std::vector<LuaFile> archiveFiles;
    archiveFiles.reserve(unionFiles.size());
    for (auto& [filename, content] : unionFiles) {
        auto it = cloudManifest.find(filename);
        if (it == cloudManifest.end() || it->second.isDeleted()) continue;
        LuaFile lf;
        lf.filename = filename;
        lf.content = content;
        lf.modTime = it->second.mod;
        archiveFiles.push_back(std::move(lf));
    }

    if (!archiveFiles.empty()) {
        auto zipData = CreateLuaZip(archiveFiles);
        if (zipData.empty())return;
        if (!zipData.empty()) {
            CloudStorage::StoreBlob(accountId, LUA_SYNC_APPID,
                "LuaArchive.zip", zipData.data(), zipData.size());
        }
    }

    std::string manifestStr = SerializeManifest(cloudManifest);
    CloudStorage::StoreBlob(accountId, LUA_SYNC_APPID, "LuaManifest.json",
        reinterpret_cast<const uint8_t*>(manifestStr.data()), manifestStr.size());

    std::unordered_set<std::string> newFiles;
    for (auto& [f, e] : cloudManifest) { if (!e.isDeleted()) newFiles.insert(f); }
    WriteSyncState(now, newFiles);

    LOG("[LuaSync] Shutdown upload (union): %zu archived, %zu total manifest entries",
        archiveFiles.size(), cloudManifest.size());
}


static bool IsSelfUnlockingLua(const std::string& filePath, uint32_t appId) {
    std::ifstream ifs(FileUtil::Utf8ToPath(filePath));
    if (!ifs.is_open()) return false;

    // Build the two markers: "addappid(12345)" and "addappid(12345,"
    std::string markerExact = "addappid(" + std::to_string(appId) + ")";
    std::string markerArgs  = "addappid(" + std::to_string(appId) + ",";

    std::string line;
    while (std::getline(ifs, line)) {
        // Skip leading whitespace
        size_t start = 0;
        while (start < line.size() && (line[start] == ' ' || line[start] == '\t'))
            ++start;

        // Skip commented-out lines
        if (start + 1 < line.size() && line[start] == '-' && line[start + 1] == '-')
            continue;

        std::string_view sv(line.data() + start, line.size() - start);
        if (sv.starts_with(markerExact) || sv.starts_with(markerArgs))
            return true;
    }

    return false;
}



}
namespace NativeLua {
void SyncNow(){SyncLuaFiles();}
void Start(){if(!MetadataSync::syncLuas||worker)return;worker=new std::thread([](){try{SyncLuaFiles();}catch(const std::exception& e){LOG("[LuaSync] Native sync failed: %s",e.what());}});}
void Shutdown(){if(worker){if(worker->joinable())worker->join();delete worker;worker=nullptr;}if(MetadataSync::syncLuas)UploadLuaOnShutdown();}
}
