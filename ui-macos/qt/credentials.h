#pragma once
#include <QCoreApplication>
#include <QBuffer>
#include <QFile>
#include <QProcess>
inline QString nativeCli(){return qEnvironmentVariable("CR_BUNDLED_CLI",QCoreApplication::applicationDirPath()+"/../Resources/runtime/cloud_redirect_cli");}
inline QByteArray readCredential(const QString& path) {
    QProcess p;p.start(nativeCli(),{"read-credentials-path",path});
    if(!p.waitForFinished(10000)||p.exitCode()!=0)return {};
    return p.readAllStandardOutput();
}
inline bool writeCredential(const QString& path,const QByteArray& value){
    QProcess p;p.start(nativeCli(),{"store-credentials-path",path});
    if(!p.waitForStarted(5000))return false;p.write(value);p.closeWriteChannel();
    return p.waitForFinished(10000)&&p.exitCode()==0;
}
class CredentialFile: public QBuffer {
    QString path;
public:
    explicit CredentialFile(const QString& value):path(value){}
    bool open(QIODevice::OpenMode mode) override {if(mode!=QIODevice::ReadOnly)return false;setData(readCredential(path));return !data().isEmpty()&&QBuffer::open(mode);}
    static bool exists(const QString& path){return !readCredential(path).isEmpty();}
};
