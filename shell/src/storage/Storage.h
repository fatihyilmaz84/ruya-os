#pragma once

#include "StorageBackend.h"

#include <QObject>
#include <QQmlEngine>
#include <QSet>
#include <QVariantList>

#include <memory>

// QML face of org.ruyaos.Devices1.Storage: the volume list, eject, and the "drive inserted"
// signal. Backend: RUYA_SERVICES=mock|dbus; the default is D-Bus on Linux (the service is a
// later task) and the mock elsewhere, like Audio, Network and Bluetooth.
class Storage : public QObject
{
    Q_OBJECT
    QML_ELEMENT
    QML_SINGLETON

    // [{ id, label, filesystem, sizeBytes, freeBytes, removable, mounted, mountPoint, readOnly }]
    Q_PROPERTY(QVariantList volumes READ volumes NOTIFY volumesChanged)
    Q_PROPERTY(bool mock READ isMock CONSTANT)

public:
    explicit Storage(std::unique_ptr<StorageBackend> backend, QObject *parent = nullptr);
    ~Storage() override;

    static Storage *create(QQmlEngine *qmlEngine, QJSEngine *jsEngine);

    QVariantList volumes() const { return m_volumes; }
    bool isMock() const { return m_backend->isMock(); }

    // The one place sizes are formatted: "1.5 GB" in the user's locale (decimal sign, unit
    // names), SI units (1 GB = 10^9 bytes) like disk makers and TVs.
    Q_INVOKABLE static QString formatBytes(qint64 bytes);

    Q_INVOKABLE void eject(const QString &id);

    // Tests only, and only with the mock backend (otherwise no-ops). mockReset puts the volumes
    // back with the USB stick not plugged in (plugStick starts the delayed insert, as a fresh
    // start does); mockPlugStick inserts it now; mockSetBusy makes ejecting a volume answer "busy".
    Q_INVOKABLE void mockReset(bool plugStick = false);
    Q_INVOKABLE void mockPlugStick();
    Q_INVOKABLE void mockSetBusy(const QString &id, bool busy);
    // mockHoldEject: eject() stays unanswered until released (false); mockEjectCalls counts the
    // eject() calls since the last reset; mockRepublish publishes the unchanged list again.
    Q_INVOKABLE void mockHoldEject(bool hold);
    Q_INVOKABLE int mockEjectCalls() const;
    Q_INVOKABLE void mockRepublish();
    // Asks the backend for the list; its reply arrives after `ms` and shows the list as it is now.
    // mockPendingReplies: how many replies are still on their way.
    Q_INVOKABLE void mockRefreshDelayed(int ms);
    Q_INVOKABLE int mockPendingReplies() const;

signals:
    void volumesChanged();
    // A volume was plugged in and is now in the list; once per insert.
    void volumeAdded(const QString &id, const QString &label);
    // op: "eject"; status: see api/dbus/org.ruyaos.Devices1.xml
    void finished(const QString &op, const QString &id, const QString &status);

private:
    std::unique_ptr<StorageBackend> m_backend;
    QVariantList m_volumes;
    QSet<QString> m_pendingAdded; // announced, waiting for the list that holds them
};
