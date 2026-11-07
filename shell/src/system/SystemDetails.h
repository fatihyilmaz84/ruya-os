#pragma once

#include "SystemDetailsBackend.h"

#include <QObject>
#include <QQmlEngine>
#include <QVariantMap>

#include <memory>

class QQuickWindow;

// QML face of org.ruyaos.Devices1.System (T-226): what the console is made of, for the System
// information page. `info` is the service's dictionary of grouped keys (api/dbus/org.ruyaos.Devices1.xml;
// a value that could not be read is absent, never 0) plus what only this session knows (the mode
// the display runs in, the graphics API and renderer; see probeLocal). The page puts the other
// services' numbers next to it (Thermal, Storage, Batteries, Network, Audio) and does not repeat them
// here. Backend: RUYA_SERVICES=mock|dbus; the default is D-Bus on Linux (ruya-devices) and the mock
// elsewhere, like Thermal.
class SystemDetails : public QObject
{
    Q_OBJECT
    QML_ELEMENT
    QML_SINGLETON

    // { "cpu.model": ..., "memory.total_bytes": ..., "storage.drives": [{ model, type, size_bytes,
    // health? }], ... } (the keys of the XML); empty until the first reply.
    Q_PROPERTY(QVariantMap info READ info NOTIFY infoChanged)
    // The first reply has arrived.
    Q_PROPERTY(bool valid READ valid NOTIFY infoChanged)
    Q_PROPERTY(bool mock READ isMock CONSTANT)
    // How often the visible page asks for the live values, in ms. 2000; a test may shorten it.
    Q_PROPERTY(int liveIntervalMs READ liveIntervalMs WRITE setLiveIntervalMs NOTIFY liveIntervalMsChanged)
    // How many times refresh() was called since the start (the page's timer; tests read it to see
    // that nothing is asked for while the page is hidden).
    Q_PROPERTY(int refreshCount READ refreshCount NOTIFY refreshCountChanged)

public:
    static constexpr int DefaultLiveIntervalMs = 2000;

    explicit SystemDetails(std::unique_ptr<SystemDetailsBackend> backend, QObject *parent = nullptr);
    ~SystemDetails() override;

    static SystemDetails *create(QQmlEngine *qmlEngine, QJSEngine *jsEngine);

    QVariantMap info() const;
    bool valid() const { return m_valid; }
    bool isMock() const { return m_backend->isMock(); }
    int liveIntervalMs() const { return m_liveIntervalMs; }
    void setLiveIntervalMs(int ms);
    int refreshCount() const { return m_refreshCount; }

    // Asks the service again (the live values change all the time; the page calls this every
    // liveIntervalMs while it is visible, and never when hidden).
    Q_INVOKABLE void refresh();
    // Reads what only this session knows: the display's name, size and refresh rate, the graphics
    // API and, for OpenGL, the renderer string. Not with the mock (its machines carry their own).
    Q_INVOKABLE void probeLocal(QQuickWindow *window);

    // Tests only, and only with the mock backend (otherwise no-ops): "dell" | "amd" | "nvidia".
    Q_INVOKABLE QStringList mockProfiles() const;
    Q_INVOKABLE void mockProfile(const QString &name);
    Q_INVOKABLE void mockSet(const QString &key, const QVariant &value);
    Q_INVOKABLE void mockRemove(const QString &key);
    Q_INVOKABLE void mockReset();
    // Asks the backend; its reply arrives after `ms` and shows the data as it is now.
    Q_INVOKABLE void mockRefreshDelayed(int ms);
    Q_INVOKABLE int mockPendingReplies() const;

signals:
    void infoChanged();
    void liveIntervalMsChanged();
    void refreshCountChanged();

private:
    void apply(const QVariantMap &info);

    std::unique_ptr<SystemDetailsBackend> m_backend;
    QVariantMap m_service;
    QVariantMap m_local;
    bool m_valid = false;
    int m_liveIntervalMs = DefaultLiveIntervalMs;
    int m_refreshCount = 0;
};
