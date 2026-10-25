#include "backend.h"
#include "utils.h"
#include "managed_games.h"
#include "credentials.h"
#include <QFile>
#include <QMap>
#include <QSaveFile>
#include <QJsonDocument>
#include <QJsonObject>
#include <QJsonArray>
#include <QRegularExpression>
static QJsonObject config(){QFile f(crConfigDir()+"/config.json");if(!f.open(QIODevice::ReadOnly))return {};return QJsonDocument::fromJson(f.readAll()).object();}
QString Backend::managedIDs()const{QStringList ids;for(auto id:config()["apps"].toArray())ids<<QString::number(id.toInt());return ids.join(", ");}
bool Backend::redirectEnabled()const{return config()["enabled"].toBool(false);}
QString Backend::saveManagedIDs(const QString& ids,bool enabled){
    QJsonArray apps;QSet<uint> seen;
    for(const auto& token:ids.split(QRegularExpression("[,\\s]+"),Qt::SkipEmptyParts)){bool ok=false;uint id=token.toUInt(&ok);if(!ok||id==0||id>0xffffff)return "Invalid game ID: "+token;if(!seen.contains(id)){apps.append((int)id);seen.insert(id);}}
    if(enabled&&apps.isEmpty()&&ManagedGames::Discover(m_steamPath.toStdString(),QFileInfo(crConfigDir()).absolutePath().toStdString()).empty())return "Select game IDs or install self-unlocking Lua scripts.";
    auto cfg=config();cfg["apps"]=apps;cfg["enabled"]=enabled;QDir().mkpath(crConfigDir());
    QSaveFile file(crConfigDir()+"/config.json");if(!file.open(QIODevice::WriteOnly)||file.write(QJsonDocument(cfg).toJson())<0||!file.commit())return "Could not save settings.";
    file.setPermissions(QFile::ReadOwner|QFile::WriteOwner);refreshStatus();return "Settings saved. Restart Steam to apply.";
}

#include <QCoreApplication>
#include <QProcess>
static void runSteamCloud(Backend* owner,const QString& command,uint appId,const QStringList& names={}){
    if(!appId){emit owner->steamCloudFinished({},"Enter a valid Steam AppID.");return;}
    auto* process=new QProcess(owner);process->setProcessChannelMode(QProcess::SeparateChannels);
    QObject::connect(process,&QProcess::finished,owner,[owner,process,appId,command](int code,QProcess::ExitStatus status){
        QVariantMap result;result["appId"]=appId;QVariantList files;
        QString error;QString output=QString::fromUtf8(process->readAllStandardOutput());
        if(code||status!=QProcess::NormalExit)error=QString::fromUtf8(process->readAllStandardError());
        int count=-1;
        for(const auto& line:output.split('\n')){
            auto fields=line.split('\t');if(fields.isEmpty())continue;
            if(fields[0]=="COUNT"&&fields.size()>=2)count=fields[1].toInt();
            if(fields[0]=="CLOUD"&&fields.size()>=3){result["accountEnabled"]=fields[1]=="1";result["appEnabled"]=fields[2]=="1";}
            if(fields[0]=="QUOTA"&&fields.size()>=3){result["totalBytes"]=fields[1].toULongLong();result["availableBytes"]=fields[2].toULongLong();}
            if(fields[0]=="FILE"&&fields.size()>=4){QVariantMap f;f["name"]=fields[1];f["size"]=fields[2].toLongLong();f["persisted"]=fields[3]=="1";files.append(f);}
        }
        if(error.isEmpty()&&command=="list"&&(count<0||count!=files.size()))error="Steam returned an incomplete file listing.";
        result["files"]=files;result["deleted"]=command=="delete";
        emit owner->steamCloudFinished(result,error);process->deleteLater();
    });
    QObject::connect(process,&QProcess::errorOccurred,owner,[owner,process](QProcess::ProcessError error){if(error==QProcess::FailedToStart){emit owner->steamCloudFinished({},"Could not start the native Steam Cloud helper.");process->deleteLater();}});
    QStringList args{command,QString::number(appId),"--porcelain"};args.append(names);
    process->start(QCoreApplication::applicationDirPath()+"/../Resources/runtime/cloud760_tool",args);
}
void Backend::steamCloudList(uint appId){runSteamCloud(this,"list",appId);}
void Backend::steamCloudDelete(uint appId,const QStringList& names){if(names.isEmpty()){emit steamCloudFinished({},"Select at least one file.");return;}runSteamCloud(this,"delete",appId,names);}

#include <QDesktopServices>
#include <QUrl>
QVariantMap Backend::manifestSettings()const{
    auto cfg=config();QVariantMap result;result["enabled"]=cfg["manifest_pinning"].toBool(false);result["autoComment"]=cfg["auto_comment"].toBool(true);result["pinnedApps"]=cfg["pinned_apps"].toArray().toVariantList();return result;
}
QVariantList Backend::manifestApps()const{
    QVariantList result;QDir directory(m_steamPath+"/config/stplug-in");
    for(const auto& name:directory.entryList({"*.lua"},QDir::Files)){
        bool ok=false;uint id=QFileInfo(name).completeBaseName().toUInt(&ok);if(!ok||!id)continue;
        QFile file(directory.filePath(name));if(!file.open(QIODevice::ReadOnly))continue;
        auto content=QString::fromUtf8(file.read(4*1024*1024));
        QRegularExpression pattern("setManifestid\\s*\\(\\s*([0-9]+)\\s*,\\s*\"([0-9]+)\"",QRegularExpression::CaseInsensitiveOption);
        int count=0;for(auto line:content.split('\n')){line=line.section("--",0,0);auto matches=pattern.globalMatch(line);while(matches.hasNext()){matches.next();++count;}}
        QVariantMap record;record["appId"]=id;record["name"]=getAppName(id);record["pins"]=count;result.append(record);
    }
    return result;
}
QString Backend::saveManifestSettings(bool enabled,bool autoComment,const QVariantList& apps){
    auto cfg=config();QJsonArray ids;QSet<uint> seen;
    for(const auto& value:apps){bool ok=false;uint id=value.toUInt(&ok);if(!ok||!id||id>0xffffff)return "Invalid pinned AppID.";if(!seen.contains(id)){seen.insert(id);ids.append((int)id);}}
    cfg["manifest_pinning"]=enabled;cfg["auto_comment"]=autoComment;cfg["pinned_apps"]=ids;
    QDir().mkpath(crConfigDir());QSaveFile file(crConfigDir()+"/config.json");
    if(!file.open(QIODevice::WriteOnly)||file.write(QJsonDocument(cfg).toJson())<0||!file.commit())return "Could not save manifest preferences.";
    return "Manifest settings saved. Restart Steam to apply.";
}
void Backend::openLuaFolder(){QString path=m_steamPath+"/config/stplug-in";QDir().mkpath(path);QDesktopServices::openUrl(QUrl::fromLocalFile(path));}

bool Backend::syncLuas() const { return config()["sync_luas"].toBool(false); }
void Backend::setSyncLuas(bool enabled) {
    auto cfg = config();
    cfg["sync_luas"] = enabled;
    QDir().mkpath(crConfigDir());
    QSaveFile file(crConfigDir()+"/config.json");
    if (!file.open(QIODevice::WriteOnly)) return;
    const auto bytes = QJsonDocument(cfg).toJson();
    if (file.write(bytes) != bytes.size() || !file.commit()) return;
    emit settingsChanged();
}

QVariantList Backend::detectedGames() const {
    QMap<uint,QVariantMap> games;
    for(auto id:ManagedGames::Discover(m_steamPath.toStdString(),QFileInfo(crConfigDir()).absolutePath().toStdString())) {
        games[id]={{"appId",id},{"name",getAppName(id)}};
    }
    for(auto value:const_cast<Backend*>(this)->getAppDetails()) {
        auto game=value.toMap();uint id=game["appId"].toUInt();if(id)games[id]=game;
    }
    QVariantList result;
    for(auto game:games){game["label"]=game["name"].toString()+" ("+game["appId"].toString()+")";result.append(game);}
    std::sort(result.begin(),result.end(),[](const QVariant&a,const QVariant&b){return a.toMap()["label"].toString().localeAwareCompare(b.toMap()["label"].toString())<0;});
    result.prepend(QVariantMap{{"appId",760},{"label","Steam Community (760)"}});return result;
}

QVariantList Backend::cloudGames() const {
    QVariantList result;
    for(auto value:const_cast<Backend*>(this)->getAppDetails()) {
        auto game=value.toMap();if(!m_remoteAppIds.contains(game["appId"].toUInt()))continue;
        QString name=getAppName(game["appId"].toUInt());
        if(name.startsWith("App "))continue; // Names are resolved asynchronously by the backend.
        game["label"]=name;result.append(game);
    }
    std::sort(result.begin(),result.end(),[](const QVariant&a,const QVariant&b){return a.toMap()["label"].toString().localeAwareCompare(b.toMap()["label"].toString())<0;});return result;
}
void Backend::cloudSaveList(uint appId){
    if(!appId||!m_remoteAppIds.contains(appId)){emit steamCloudFinished({},"Choose a game with cloud data.");return;}
    auto* process=new QProcess(this);
    connect(process,&QProcess::finished,this,[this,process,appId](int code,QProcess::ExitStatus status){
        auto data=QJsonDocument::fromJson(process->readAllStandardOutput()).object();
        QVariantMap result=data.toVariantMap();result["appId"]=appId;result["source"]="provider";
        QString error;if(code||status!=QProcess::NormalExit||!data["success"].toBool())error=data["error"].toString("Could not read the cloud save inventory.");
        emit steamCloudFinished(result,error);process->deleteLater();
    });
    connect(process,&QProcess::errorOccurred,this,[this,process](QProcess::ProcessError error){if(error==QProcess::FailedToStart){emit steamCloudFinished({},"Could not start the cloud helper.");process->deleteLater();}});
    process->start(nativeCli(),{"list-cloud-save-files",m_providerName,m_accountId,QString::number(appId)});
}
