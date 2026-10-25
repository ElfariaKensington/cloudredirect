#include "stats_store.h"
#include "stats_handlers.h"
#include "metadata_sync.h"
#include "protobuf.h"
#include <filesystem>
#include <algorithm>
#include <stdexcept>
#include <unistd.h>
#include <cstdio>
#define CHECK(x) do{if(!(x))throw std::runtime_error(#x);}while(0)
int main(){
    char pattern[]="/tmp/cr-stats-tests-XXXXXX";auto* p=mkdtemp(pattern);if(!p)return 1;std::string root=p;
    try{
        auto selected=[](uint32_t app){return app==620;};
        StatsStore::SetAccountIdProvider([](){return 4242u;});StatsStore::SetNamespacePredicate(selected);
        StatsHandlers::SetNamespacePredicate(selected);StatsStore::Init(root,root+"/steam/");StatsHandlers::Init();StatsStore::SeedApps({620});
        StatsStore::SetStat(620,7,42);StatsStore::SetAchievement(620,9,3,1700000000);
        StatsStore::FlushAll();
        StatsStore::AppStats data{};CHECK(StatsStore::LoadAppStats(620,data));
        CHECK(std::any_of(data.stats.begin(),data.stats.end(),[](auto s){return s.statId==7&&s.value==42;}));
        CHECK(std::any_of(data.achievements.begin(),data.achievements.end(),[](auto a){return a.statId==9&&(a.bits&(1u<<3));}));
        PB::Writer games,managed,other;managed.WriteFixed64(2,620);other.WriteFixed64(2,999999);
        games.WriteSubmessage(1,managed);games.WriteSubmessage(1,other);
        StatsHandlers::ObserveGamesPlayed(games.Data().data(),games.Size());
        CHECK(StatsStore::GetPlaytime(620).lastPlayedTime>0);
        auto apps=StatsStore::GetTrackedApps();CHECK(std::find(apps.begin(),apps.end(),999999)==apps.end());
        auto ended=StatsHandlers::ObserveGamesPlayed(nullptr,0);CHECK(ended.size()==1&&ended[0]==620);
        StatsHandlers::Shutdown();StatsStore::ResetForTesting();std::filesystem::remove_all(root);
        puts("Native stats persistence, achievements and selected-game session handling passed");return 0;
    }catch(const std::exception&e){StatsHandlers::Shutdown();std::filesystem::remove_all(root);fprintf(stderr,"FAIL: %s\n",e.what());return 1;}
}
