#include "deployer.h"
#include "utils.h"
#include "credentials.h"
#include <QCoreApplication>
#include <QProcess>
#include <QFile>
#include <QDir>
#include <QJsonDocument>
#include <QJsonObject>
#include <QCryptographicHash>
static QString helper(){return QCoreApplication::applicationDirPath()+"/../Resources/CloudRedirectNative";}
static QString installed(){return "/Applications/Steam.app/Contents/MacOS/cloud_redirect.dylib";}
static QString bundled(){return QCoreApplication::applicationDirPath()+"/../Resources/runtime/cloud_redirect.dylib";}
static QByteArray digest(const QString& p){QFile f(p);return f.open(QIODevice::ReadOnly)?QCryptographicHash::hash(f.readAll(),QCryptographicHash::Sha256):QByteArray();}
Deployer::Deployer(QObject* parent):QObject(parent){checkPrerequisites();}
bool Deployer::slssteamInstalled()const{return m_slssteamInstalled;}
bool Deployer::headcrabInstalled()const{return m_headcrabInstalled;}
bool Deployer::alreadyDeployed()const{return m_alreadyDeployed;}
bool Deployer::updateAvailable()const{return m_updateAvailable;}
bool Deployer::slsCloudBlocked()const{return m_slsCloudBlocked;}
QString Deployer::statusMessage()const{return m_statusMessage;}
QString Deployer::bundledVersion()const{return m_bundledVersion;}
QString Deployer::deployedVersion()const{return m_deployedVersion;}
void Deployer::checkPrerequisites(){
    m_slssteamInstalled=QDir("/Applications/Steam.app").exists();
    m_headcrabInstalled=QDir("/Applications/Steam.app").exists();
    m_alreadyDeployed=QFile::exists(installed());m_updateAvailable=m_alreadyDeployed&&digest(installed())!=digest(bundled());
    m_slsCloudBlocked=false;m_bundledVersion=QCoreApplication::applicationVersion();
    m_deployedVersion=m_updateAvailable?"Earlier macOS runtime":m_alreadyDeployed?m_bundledVersion:QString();
    emit checkCompleted();
}
bool Deployer::deploy(){
    QProcess check;check.start(nativeCli(),{"diagnose"});
    if(!check.waitForFinished(15000)||check.exitCode()!=0){m_statusMessage="Steam compatibility check failed: "+QString::fromUtf8(check.readAllStandardOutput());emit statusMessageChanged();emit deployCompleted(false);return false;}
    QProcess p;p.start(helper(),{"--install-runtime"});bool ok=p.waitForFinished(30000)&&p.exitCode()==0;
    m_statusMessage=ok?"Installed. Restart Steam to activate the runtime.":QString::fromUtf8(p.readAllStandardError());
    emit statusMessageChanged();checkPrerequisites();emit deployCompleted(ok);return ok;
}
bool Deployer::undeploy(){QProcess p;p.start(helper(),{"--remove-runtime"});bool ok=p.waitForFinished(30000)&&p.exitCode()==0;m_statusMessage=ok?"Runtime removed; saves and settings retained.":QString::fromUtf8(p.readAllStandardError());emit statusMessageChanged();checkPrerequisites();emit deployCompleted(ok);return ok;}
bool Deployer::update(){return deploy();}
bool Deployer::purgeAll(){
    if(!undeploy())return false;
    // The original app requires a countdown confirmation before this method.
    // Only local CloudRedirect files are purged, never remote provider data.
    const QString root=crConfigDir();
    QProcess purge;purge.start(nativeCli(),{"purge-credentials"});
    if(!purge.waitForFinished(10000)||purge.exitCode()!=0){m_statusMessage="Could not remove Keychain credentials; local files retained.";emit statusMessageChanged();return false;}
    bool ok=QDir(root).removeRecursively();m_statusMessage=ok?"Local data removed.":"Some local data could not be removed.";emit statusMessageChanged();return ok;
}
