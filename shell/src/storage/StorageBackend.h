#pragma once

#include "RequestSequence.h"

#include <QList>
#include <QObject>
#include <QString>

struct StorageVolume
{
    QString id;
    QString drive; // the drive it lives on; partitions of one stick share it (may be empty)
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

protected:
    // Replies can arrive out of order: number each request when it is sent and report a reply only
    // if no newer one has been reported already. RequestSequence.h.
    quint64 beginRequest() { return m_listSeq.begin(); }
    void deliver(quint64 request, const QList<StorageVolume> &volumes)
    {
        if (m_listSeq.accept(request))
            emit volumesListed(volumes);
    }

private:
    RequestSequence m_listSeq;
};
