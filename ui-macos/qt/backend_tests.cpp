#include "backend.h"
#include <QCoreApplication>
#include <QTemporaryDir>
#include <QFile>
#include <QDir>
#include <QJsonDocument>
#include <QJsonObject>
#include <stdexcept>
#include <cstdio>
#define CHECK(x) do{if(!(x))throw std::runtime_error(#x);}while(0)
static void write(const QString& path,const QByteArray& bytes){QDir().mkpath(QFileInfo(path).absolutePath());QFile f(path);CHECK(f.open(QIODevice::WriteOnly));CHECK(f.write(bytes)==bytes.size());}
int main(int argc,char**argv){QCoreApplication app(argc,argv);QTemporaryDir temp;CHECK(temp.isValid());
    qputenv("CLOUDREDIRECT_CONFIG_HOME",temp.path().toUtf8());qputenv("CLOUDREDIRECT_STEAM_HOME",(temp.path()+"/steam").toUtf8());
    QString config=temp.path()+"/CloudRedirect";QString steam=temp.path()+"/steam";
    write(config+"/config.json","{\"provider\":\"local\",\"apps\":[620],\"enabled\":true,\"custom\":\"preserved\"}");
    write(steam+"/config/loginusers.vdf","\"users\"\n{\n\"76561197960269970\"\n{\n\"MostRecent\"\t\"1\"\n\"PersonaName\"\t\"Fixture\"\n}\n}\n");
    const QString storage=config+"/storage/4242/620";const QString userdata=steam+"/userdata/4242/620";
    write(storage+"/blobs/save.bin","save fixture");write(userdata+"/remotecache.vdf","cache fixture");
    try{
        Backend backend;CHECK(backend.accountId()=="4242");CHECK(backend.managedIDs()=="620");
        CHECK(backend.saveManagedIDs("620, 20, 620",true).startsWith("Settings saved"));CHECK(backend.managedIDs()=="620, 20");
        CHECK(backend.saveManagedIDs("620,no",true).startsWith("Invalid"));CHECK(backend.managedIDs()=="620, 20");
        QFile cf(config+"/config.json");CHECK(cf.open(QIODevice::ReadOnly));CHECK(QJsonDocument::fromJson(cf.readAll()).object()["custom"]=="preserved");
        CHECK(!backend.syncLuas());backend.setSyncLuas(true);CHECK(backend.syncLuas());
        CHECK(backend.scanOrphans().size()==1);
        backend.deleteAppData(620);CHECK(!QFile::exists(storage+"/blobs/save.bin"));CHECK(!QFile::exists(userdata+"/remotecache.vdf"));
        auto backups=backend.listBackups();CHECK(backups.size()==1);auto backup=backups[0].toMap()["path"].toString();
        auto result=backend.restoreBackup(backup);CHECK(result.startsWith("Restored 2 file(s)"));CHECK(QFile::exists(storage+"/blobs/save.bin"));CHECK(QFile::exists(userdata+"/remotecache.vdf"));
        CHECK(backend.restoreBackup(temp.path()).contains("Invalid"));
        backend.deleteBackup(backup);CHECK(backend.listBackups().isEmpty());puts("Native Qt app management, backup/restore and settings checks passed");return 0;
    }catch(const std::exception& e){fprintf(stderr,"FAIL: %s\n",e.what());return 1;}
}
