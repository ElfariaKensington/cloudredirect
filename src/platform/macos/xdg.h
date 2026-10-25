#pragma once
#include <cstdlib>
#include <pwd.h>
#include <unistd.h>
#include <string>
inline bool InFlatpak() { return false; }
inline std::string XdgHome() {
    const char* home = getenv("HOME");
    if (home && *home) return home;
    auto* p = getpwuid(getuid());
    return p ? p->pw_dir : "/tmp";
}
inline std::string XdgConfigHome() {
    const char* root = getenv("CLOUDREDIRECT_CONFIG_HOME");
    return root && *root == '/' ? root : XdgHome() + "/Library/Application Support";
}
inline std::string XdgDataHome() { return XdgConfigHome(); }
