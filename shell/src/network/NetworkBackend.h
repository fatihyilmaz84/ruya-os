#pragma once

#include <QList>
#include <QObject>
#include <QString>
#include <QVariantMap>

struct WifiInfo
{
    QString id;
    QString ssid;
    int signal = 0;                            // 0-100
    QString security = QStringLiteral("open"); // "open" | "wpa-psk" | "enterprise"
    bool known = false;
    bool active = false;
};

// Transport behind the Network QML singleton: org.ruyaos.Devices1.Network over D-Bus
// (api/dbus/org.ruyaos.Devices1.xml), or an in-memory mock. Results arrive asynchronously
// through signals.
class NetworkBackend : public QObject
{
    Q_OBJECT

public:
    using QObject::QObject;

    virtual bool isMock() const = 0;
    virtual void refresh() = 0; // reports the state and the networks
    virtual void scan() = 0;
    virtual void connectWifi(const QString &id, const QString &password) = 0;
    virtual void forget(const QString &id) = 0;

signals:
    // state: "disconnected" | "connecting" | "connected" | "limited"; primary: see the XML
    // (empty when disconnected).
    void stateChanged(const QString &state, const QVariantMap &primary);
    void networksListed(const QList<WifiInfo> &networks);
    // status: see the XML ("ok", "wrong-password", "unsupported", ...).
    void connectFinished(const QString &id, const QString &status);
    void forgetFinished(const QString &id, const QString &status);
};
