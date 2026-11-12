#pragma once

#include "InputBackend.h"

#include <QObject>
#include <QQmlEngine>
#include <QVariantList>

#include <memory>

// QML face of org.ruyaos.Input1 (RUY-409): the shell tells Ruya Input who is in front, so a game
// sees the signed-in profile's virtual pads only while it has the screen (06 §5.1-5.2). The shell is
// the only source of the route; InputRoute.qml works it out and calls setRoute on every change.
// A failed call is logged and sent again with the next change, never waited for; a new owner of the
// name (the service restarted and is back in "shell") gets the current route again at once.
// Backend: RUYA_SERVICES=mock|dbus; the default is D-Bus on Linux and the mock elsewhere.
class Input : public QObject
{
    Q_OBJECT
    QML_ELEMENT
    QML_SINGLETON

    // The route last asked for ("" before the first call): "shell" | "app" | "overlay" | "locked".
    Q_PROPERTY(QString route READ route NOTIFY routeChanged)
    Q_PROPERTY(QString instance READ instance NOTIFY routeChanged)
    Q_PROPERTY(QString appId READ appId NOTIFY routeChanged)
    Q_PROPERTY(QString profile READ profile NOTIFY routeChanged)
    // The service's answer to the newest call: "" while it is on its way, else a status string of
    // api/dbus/org.ruyaos.Input1.xml, or "failed" when the call failed.
    Q_PROPERTY(QString status READ status NOTIFY statusChanged)
    // org.ruyaos.Input1 has an owner on the bus (RUY-410). EmergencyReader reads the pads itself
    // when it has been false for 3 s. True until the bus has answered.
    Q_PROPERTY(bool serviceOwned READ serviceOwned NOTIFY serviceOwnedChanged)
    Q_PROPERTY(bool mock READ isMock CONSTANT)

public:
    explicit Input(std::unique_ptr<InputBackend> backend, QObject *parent = nullptr);
    ~Input() override;

    static Input *create(QQmlEngine *qmlEngine, QJSEngine *jsEngine);

    QString route() const { return m_route; }
    QString instance() const { return m_instance; }
    QString appId() const { return m_appId; }
    QString profile() const { return m_profile; }
    QString status() const { return m_status; }
    bool isMock() const { return m_backend->isMock(); }
    bool serviceOwned() const { return m_backend->serviceOwned(); }

    // Sends the route unless it is the one already asked for and that call did not fail.
    Q_INVOKABLE void setRoute(const QString &route, const QString &instance, const QString &appId,
                              const QString &profile);

    // Tests only, and only with the mock backend (otherwise empty or no-ops).
    // Every SetRoute that reached the mock service: [{ route, instance, appId, profile }].
    Q_INVOKABLE QVariantList mockCalls() const;
    Q_INVOKABLE void mockClearCalls();
    // What the mock service holds now, and whether it has virtual pads (and how often it made them).
    Q_INVOKABLE QString mockServiceRoute() const;
    Q_INVOKABLE QString mockServiceInstance() const;
    Q_INVOKABLE QString mockServiceProfile() const;
    Q_INVOKABLE bool mockPads() const;
    Q_INVOKABLE int mockPadGeneration() const;
    // While true every call fails ("failed"), as with no service on the bus.
    Q_INVOKABLE void mockFail(bool fail);
    // The service restarts (route "shell", no pads) and its name gets a new owner.
    Q_INVOKABLE void mockRestart();
    // The service's name loses or regains its owner (RUY-410: the service is gone, or masked).
    Q_INVOKABLE void mockNameOwned(bool owned);

signals:
    void routeChanged();
    void statusChanged();
    void serviceOwnedChanged();

private:
    void send();

    std::unique_ptr<InputBackend> m_backend;
    QString m_route;
    QString m_instance;
    QString m_appId;
    QString m_profile;
    QString m_status;
};
