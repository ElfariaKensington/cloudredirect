#pragma once
#include <QObject>
#include <QQuickImageProvider>
class QWindow;
class MacAppearance : public QObject {
    Q_OBJECT
    Q_PROPERTY(qreal titlebarInset READ titlebarInset NOTIFY layoutMetricsChanged)
public:
    using QObject::QObject;
    void attach(QWindow* window);
    qreal titlebarInset() const { return titlebarInset_; }
    Q_INVOKABLE void setSidebarWidth(int width);
signals:
    void toggleSidebar();
    void refresh();
    void layoutMetricsChanged();
private:
    void* effect_ = nullptr;
    qreal titlebarInset_ = 0;
};
class SymbolProvider : public QQuickImageProvider {
public:
    SymbolProvider() : QQuickImageProvider(Image) {}
    QImage requestImage(const QString& id, QSize* size, const QSize& requestedSize) override;
};
