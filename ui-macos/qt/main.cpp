#include <QGuiApplication>
#include <QQmlApplicationEngine>
#include <QQmlContext>
#include <QQmlComponent>
#include <QDebug>
#include <QQuickStyle>
#include "backend.h"
#include "deployer.h"
#include "oauthservice.h"
int main(int argc,char**argv){
    QGuiApplication app(argc,argv);app.setOrganizationName("CloudRedirect");app.setApplicationName("CloudRedirect");app.setApplicationVersion(CR_VERSION);
    QQuickStyle::setStyle("Fusion");QQmlApplicationEngine engine;Backend backend;Deployer deployer;OAuthService oauth;
    engine.rootContext()->setContextProperty("backend",&backend);engine.rootContext()->setContextProperty("deployer",&deployer);engine.rootContext()->setContextProperty("oauth",&oauth);engine.rootContext()->setContextProperty("macOSPort",true);
    QObject::connect(&oauth,&OAuthService::authSucceeded,&backend,&Backend::refreshStatus);QObject::connect(&oauth,&OAuthService::authSucceeded,&backend,&Backend::saveConfig);
    QObject::connect(&deployer,&Deployer::checkCompleted,&backend,&Backend::refreshStatus);
    if (app.arguments().contains("--validate-pages")) {
        const QStringList pages{"SetupPage", "DashboardPage", "AppsPage", "BackupsPage", "CloudProviderPage", "StatsPage", "MigrationPage", "ManifestPage", "SteamCloudPage"};
        for (const auto& page : pages) {
            QQmlComponent component(&engine, QUrl("qrc:/CloudRedirect/qml/pages/"+page+".qml"));
            auto* object = component.create();
            if (!object) { qCritical() << page << component.errors(); return 1; }
            delete object;
        }
        qInfo() << "All macOS QML pages loaded successfully";
        return 0;
    }
    engine.load(QUrl("qrc:/CloudRedirect/qml/Main.qml"));if(engine.rootObjects().isEmpty())return 1;return app.exec();
}
