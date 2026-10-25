#include <QGuiApplication>
#include <QQmlApplicationEngine>
#include <QQmlContext>
#include <QQmlComponent>
#include <QDebug>
#include <QIcon>
#include <QQuickStyle>
#include <QQuickWindow>
#include <QTimer>
#include "macappearance.h"
#include "backend.h"
#include "deployer.h"
#include "oauthservice.h"
int main(int argc,char**argv){
    QGuiApplication app(argc,argv);app.setOrganizationName("CloudRedirect");app.setApplicationName("CloudRedirect");app.setApplicationVersion(CR_VERSION);
    app.setWindowIcon(QIcon(QCoreApplication::applicationDirPath()+"/../Resources/CloudRedirect.icns"));
    QQuickWindow::setDefaultAlphaBuffer(true);
    QQuickStyle::setStyle("macOS");MacAppearance appearance;Backend backend;Deployer deployer;OAuthService oauth;QQmlApplicationEngine engine;engine.addImageProvider("symbols",new SymbolProvider);engine.rootContext()->setContextProperty("nativeAppearance", &appearance);
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
        engine.load(QUrl("qrc:/CloudRedirect/qml/Main.qml"));
        if (engine.rootObjects().isEmpty()) return 1;
        appearance.attach(qobject_cast<QQuickWindow*>(engine.rootObjects().first()));
        QTimer::singleShot(500, &app, &QGuiApplication::quit);
        return app.exec();
    }
    engine.load(QUrl("qrc:/CloudRedirect/qml/Main.qml"));if(engine.rootObjects().isEmpty())return 1;appearance.attach(qobject_cast<QQuickWindow*>(engine.rootObjects().first()));return app.exec();
}
