#pragma once

#include <QList>
#include <QObject>
#include <QString>

struct StorageVolume
{
    QString id;
    QString label;
    QString filesystem = QStringLiteral("unknown"); // "ext4" | "btrfs" | "exfat" | "vfat" | "ntfs" | "unknown"
    qint64 sizeBytes = 0;
    qint64 freeBytes = 0;
    bool removable = false;
    bool mounted = false;
    QString mountPoint;
    bool readOnly = false;
};

// Transport behind the Storage QML singleton: org.ruyaos.Devices1.Storage over D-Bus
// (api/dbus/org.ruyaos.Devices1.xml), or an in-memory mock. Results arrive asynchronously
// through signals. Nothing here ever runs content from a volume.
class StorageBackend : public QObject
{
    Q_OBJECT

public:
    using QObject::QObject;

    virtual bool isMock() const = 0;
    virtual void refresh() = 0; // reports the volumes
    virtual void eject(const QString &id) = 0;

signals:
    void volumesListed(const QList<StorageVolume> &volumes);
    // A volume was plugged in; sent before the list that contains it.
    void volumeAdded(const QString &id);
    // op: "eject"; status: see the XML ("ok", "busy", ...).
    void finished(const QString &op, const QString &id, const QString &status);
};
