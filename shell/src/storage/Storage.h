#pragma once

#include "StorageBackend.h"

#include <QObject>
#include <QQmlEngine>
#include <QSet>
#include <QTimer>
#include <QVariantList>
#include <QVariantMap>

#include <memory>

// QML face of org.ruyaos.Devices1.Storage: the volume list, eject, and the "drive inserted"
// signal (one per drive, however many partitions it has). Backend: RUYA_SERVICES=mock|dbus; the default is D-Bus on Linux (the service is a
// later task) and the mock elsewhere, like Audio, Network and Bluetooth.
class Storage : public QObject
{
    Q_OBJECT
    QML_ELEMENT
    QML_SINGLETON

    // [{ id, drive, label, filesystem, sizeBytes, freeBytes, removable, mounted, mountPoint, readOnly }]
    Q_PROPERTY(QVariantList volumes READ volumes NOTIFY volumesChanged)
    // The console's own storage (the filesystem that holds /var): { valid, totalBytes, freeBytes,
    // appsBytes, dataBytes, systemBytes }. `valid` is false until the first reply; a part that is
    // not known is -1 (the apps and profile data sizes are measured in the background and are -1
    // for a moment after the service starts; profile data is a lower bound).
    Q_PROPERTY(QVariantMap internal READ internal NOTIFY internalChanged)
    Q_PROPERTY(bool mock READ isMock CONSTANT)
    // How long the volumes of one drive are waited for (tests wait this long to see "no second toast").
    Q_PROPERTY(int groupWindowMs READ groupWindowMs CONSTANT)

public:
    // How long after the first announced volume the others of the same drive are waited for.
    static constexpr int GroupWindowMs = 400;

    explicit Storage(std::unique_ptr<StorageBackend> backend, QObject *parent = nullptr);
    ~Storage() override;

    static Storage *create(QQmlEngine *qmlEngine, QJSEngine *jsEngine);

    QVariantList volumes() const { return m_volumes; }
    QVariantMap internal() const { return m_internal; }
    bool isMock() const { return m_backend->isMock(); }
    int groupWindowMs() const { return GroupWindowMs; }

    // The one place sizes are formatted: "1.5 GB" in the user's locale (decimal sign, unit
    // names), SI units (1 GB = 10^9 bytes) like disk makers and TVs.
    Q_INVOKABLE static QString formatBytes(qint64 bytes);

    Q_INVOKABLE void eject(const QString &id);
    // Reads the internal storage numbers again (free space changes without a signal: ask when
    // showing it).
    Q_INVOKABLE void refreshInternal();

    // Tests only, and only with the mock backend (otherwise no-ops). mockReset puts the volumes
    // back with the USB stick not plugged in (plugStick starts the delayed insert, as a fresh
    // start does); mockPlugStick inserts it now; mockSetBusy makes ejecting a volume answer "busy".
    Q_INVOKABLE void mockReset(bool plugStick = false);
    Q_INVOKABLE void mockPlugStick();
    // Plugs in these mock volumes together (ids: vol-stick, vol-stick-2, vol-stick-raw, vol-card,
    // vol-odd), announced in the order given, one list for all.
    Q_INVOKABLE void mockPlug(const QStringList &ids);
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
    // Replaces the internal storage numbers (bytes; system is worked out as the service does) and
    // publishes them. mockLowSpace(true): a 464 GB disk with 6 % free; false: 450 GB free.
    Q_INVOKABLE void mockSetInternal(double total, double free, double apps, double data);
    Q_INVOKABLE void mockLowSpace(bool low);
    // Asks for the internal storage numbers; the reply arrives after `ms` showing them as they are
    // now (counted in mockPendingReplies).
    Q_INVOKABLE void mockRefreshInternalDelayed(int ms);

signals:
    void volumesChanged();
    void internalChanged();
    // A drive was plugged in and its volumes are in the list; once per drive and insert. `label`
    // names the first volume with a supported filesystem, `volumeCount` counts those volumes
    // (partitions with a filesystem we do not mount stay listed but are not counted; a drive that
    // has none of the supported kind gives no signal). Volumes announced within
    // `groupWindowMs` of the first one are grouped by their drive; a volume that left the list
    // again before the window ended is not counted.
    void driveAdded(const QString &drive, const QString &label, int volumeCount);
    // op: "eject"; status: see api/dbus/org.ruyaos.Devices1.xml
    void finished(const QString &op, const QString &id, const QString &status);

private:
    // A volume that is in the list and was announced: held back for the group window so that
    // the other partitions of its drive can join it.
    struct Arrival
    {
        QString drive;
        QList<StorageVolume> volumes;
    };
    void flushArrivals();
    static QVariantMap unknownInternal();

    std::unique_ptr<StorageBackend> m_backend;
    QVariantList m_volumes;
    QVariantMap m_internal;
    QSet<QString> m_pendingAdded; // announced, waiting for the list that holds them
    QList<Arrival> m_arrivals;    // by drive, in the order they came
    QTimer m_groupTimer;
};
