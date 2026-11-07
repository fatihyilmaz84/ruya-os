#pragma once

#include "RequestSequence.h"

#include <QList>
#include <QMap>
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

// How full the console's own storage is (Devices1.Storage.GetSystemUsage): the filesystem that
// holds /var and what the apps, the profile data and the system take of it. -1: not known (yet).
struct SystemUsage
{
    qint64 totalBytes = -1;
    qint64 freeBytes = -1;
    qint64 appsBytes = -1;
    qint64 dataBytes = -1;
    qint64 systemBytes = -1;
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
    // Plain report files (name -> text) onto a mounted removable volume; reports finished() with op
    // "saveReport". See Storage.SaveReport in the XML for the names and limits.
    virtual void saveReport(const QString &id, const QMap<QString, QString> &files) = 0;
    virtual void refreshUsage() = 0; // reports the internal storage numbers

signals:
    void volumesListed(const QList<StorageVolume> &volumes);
    void usageListed(const SystemUsage &usage);
    // A volume was plugged in; sent before the list that contains it.
    void volumeAdded(const QString &id);
    // op: "eject" | "saveReport"; status: see the XML ("ok", "busy", "read-only", ...).
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

    // The same for the internal storage numbers. A request that failed is an outcome too: call
    // acceptUsage for it, so an older reply landing after the failure is dropped.
    quint64 beginUsageRequest() { return m_usageSeq.begin(); }
    bool acceptUsage(quint64 request) { return m_usageSeq.accept(request); }
    void deliverUsage(quint64 request, const SystemUsage &usage)
    {
        if (m_usageSeq.accept(request))
            emit usageListed(usage);
    }

private:
    RequestSequence m_listSeq;
    RequestSequence m_usageSeq;
};
