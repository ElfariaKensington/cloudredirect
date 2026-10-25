#pragma once
#include <QObject>
#include <QQuickImageProvider>
class QWindow;
class MacAppearance : public QObject {
    Q_OBJECT
public:
    using QObject::QObject;
    void attach(QWindow* window);
    Q_INVOKABLE void setSidebarWidth(int width);
signals:
    void toggleSidebar();
    void refresh();
private:
    void* effect_ = nullptr;
};
class SymbolProvider : public QQuickImageProvider {
public:
    SymbolProvider() : QQuickImageProvider(Image) {}
    QImage requestImage(const QString& id, QSize* size, const QSize& requestedSize) override;
};
