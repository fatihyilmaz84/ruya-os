#pragma once

#include "NetworkBackend.h"

#include <QObject>
#include <QQmlEngine>
#include <QVariantList>
#include <QVariantMap>

#include <memory>

// QML face of org.ruyaos.Devices1.Network: connectivity, the primary connection and the Wi-Fi
// networks. Backend: RUYA_SERVICES=mock|dbus. Like Audio, this defaults to the mock on every
// OS because the D-Bus service (ruya-devices, T-132) does not exist yet; flip the default to
// follow Profiles in that task.
class Network : public QObject
{
    Q_OBJECT
    QML_ELEMENT
    QML_SINGLETON

    // "disconnected" | "connecting" | "connected" | "limited"
    Q_PROPERTY(QString state READ state NOTIFY stateChanged)
    // { kind, name, ip, signal? }; empty when disconnected
    Q_PROPERTY(QVariantMap primary READ primary NOTIFY stateChanged)
    // [{ id, ssid, signal, security, known, active }]
    Q_PROPERTY(QVariantList networks READ networks NOTIFY networksChanged)
    Q_PROPERTY(bool mock READ isMock CONSTANT)

public:
    explicit Network(std::unique_ptr<NetworkBackend> backend, QObject *parent = nullptr);
    ~Network() override;

    static Network *create(QQmlEngine *qmlEngine, QJSEngine *jsEngine);

    QString state() const { return m_state; }
    QVariantMap primary() const { return m_primary; }
    QVariantList networks() const { return m_networks; }
    bool isMock() const { return m_backend->isMock(); }

    Q_INVOKABLE void scan();
    // password: for a secured network that is not saved; "" otherwise. Never logged.
    Q_INVOKABLE void connectWifi(const QString &id, const QString &password);
    Q_INVOKABLE void forget(const QString &id);

    // Tests only, and only with the mock backend (otherwise no-ops): the password the mock
    // accepts, the cable, and the initial state.
    Q_INVOKABLE QString mockPassword() const;
    Q_INVOKABLE void mockSetCable(bool plugged);
    Q_INVOKABLE void mockReset();

signals:
    void stateChanged();
    void networksChanged();
    // status: see api/dbus/org.ruyaos.Devices1.xml
    void connectFinished(const QString &id, const QString &status);
    void forgetFinished(const QString &id, const QString &status);

private:
    std::unique_ptr<NetworkBackend> m_backend;
    QString m_state = QStringLiteral("disconnected");
    QVariantMap m_primary;
    QVariantList m_networks;
};
