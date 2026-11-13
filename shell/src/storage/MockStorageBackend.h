#pragma once

#include "StorageBackend.h"

#include <QTimer>

// In-memory storage. The console's own storage (refreshUsage) is a 464 GB disk with 450 GB free and
// the profile data unknown (-1), as the real service reports it; a
// test can change the numbers (setUsage, lowSpace), which is published like the service's
// SystemUsageChanged. Present at start in the volume list: a second internal disk (ext4, the "games
// disk" mounted outside the system paths) and "Old Drive", a USB drive
// whose filesystem is not supported (listed, never mounted). A USB exFAT stick, "Ruya Stick",
// is plugged in a moment after the start (3 s; 30 ms with RUYA_MOCK_FAST=1; never with RUYA_MOCK_NO_STICK=1, which the tests set) and announced with
// volumeAdded. Not plugged in at the start, for the tests: "vol-stick-2" (a second exFAT
// partition of the same drive), "vol-stick-raw" (a third partition there that is not supported),
// "vol-card" (an SD card on a drive of its own) and "vol-odd" (a drive that is not supported at
// all); see plug(). Ejecting it removes it (the tests can plug it in again); a stick marked busy
// answers "busy" and stays. Nothing is ever read from or run on a mock volume.
//
// scanVolume() follows the service's rules (one scan at a time, "unsupported" for what is not a
// mounted removable volume) and finishes a moment later with a made-up breakdown: "Ruya Stick"
// has games 12 GB, backups 2 GB, captures 1.5 GB and pictures 300 MB, 3.7 GB of other; the photos
// partition only pictures; the camera card nothing RuyaOS knows. holdScan(true) keeps a scan
// running until released; setScanPartial(true) makes the results "at least" numbers.
class MockStorageBackend final : public StorageBackend
{
    Q_OBJECT

public:
    explicit MockStorageBackend(QObject *parent = nullptr);

    bool isMock() const override { return true; }
    void refresh() override;
    void eject(const QString &id) override;
    void saveReport(const QString &id, const QMap<QString, QString> &files) override;
    void refreshUsage() override;
    void scanVolume(const QString &id) override;
    void cancelScan(const QString &id) override;
    void listFiles(const QString &id, const QString &suffix) override;
    void readFile(const QString &id, const QString &name, quint32 maxBytes) override;

    // Files on a mock volume (RUY-42): a file at the top of it (`modified` in seconds since 1970);
    // the files a saveReport() wrote are there too. setReadStatus makes later readFile() calls
    // answer that status ("not-text", "failed", ...; "" = as the service would).
    void setFile(const QString &id, const QString &name, const QString &text, qint64 modified);
    void setReadStatus(const QString &status) { m_readStatus = status; }
    QStringList readCalls() const { return m_readCalls; }

    // Tests only.
    // While held a scan stays "running" (a walk takes seconds); releasing finishes the running one.
    void holdScan(bool hold);
    QStringList scanCalls() const { return m_scanCalls; }     // the ids of scanVolume() calls, in order
    QStringList cancelCalls() const { return m_cancelCalls; } // the ids of cancelScan() calls, in order
    void setScanPartial(bool partial) { m_scanPartial = partial; }
    void setScanFailed(bool failed) { m_scanFailed = failed; } // later scans end "failed" (an unreadable drive)
    // Asks for the scan state of a volume; the reply (a snapshot of it as it is now) arrives after `ms`.
    void refreshScanDelayed(const QString &id, int ms);
    // Replaces the internal storage numbers and publishes them. system is the rest of the used
    // space (never negative), -1 while any part is -1, as the service computes it.
    void setUsage(qint64 total, qint64 free, qint64 apps, qint64 data);
    // The 464 GB disk almost full (6 % free) or back to 450 GB free.
    void lowSpace(bool low);
    int usageCalls() const { return m_usageCalls; } // refreshUsage() calls since the start
    void reset(bool plugStick);
    void plugStick();
    // Plugs these volumes in together: one list, one announcement each (in the order given).
    void plug(const QStringList &ids);
    void setBusy(const QString &id, bool busy);
    // A volume's label as a drive could carry it (any text); publishes the list.
    void setLabel(const QString &id, const QString &label);
    // A volume's free space (bytes); publishes the list.
    void setFree(const QString &id, qint64 freeBytes);
    // While held, eject() is counted but unanswered (an unmount takes seconds) until released.
    void holdEject(bool hold);
    int ejectCalls() const { return m_ejectCalls; }
    // saveReport(): the files of the last call that was accepted (what the service would have
    // written), how many calls there were, and a status that the next calls answer instead of "ok".
    QMap<QString, QString> savedFiles() const { return m_saved; }
    int saveCalls() const { return m_saveCalls; }
    void setSaveStatus(const QString &status) { m_saveStatus = status; }
    void republish();   // publish the volume list again, unchanged
    // Replies to refresh() arrive after `ms` (0: at once), with the list as it was when asked; the
    // number of replies still on their way. Lets a test play an old reply landing after a new one.
    void setReplyDelay(int ms) { m_delay = ms; }
    int pendingReplies() const { return m_pending; }

private:
    struct Entry
    {
        StorageVolume vol;
        bool present = false;
        bool busy = false;
    };

    void initState();
    void doEject(const QString &id);
    void publish(int delayMs = 0);
    void publishUsage(int delayMs = 0);
    void publishScan(const QString &id, int delayMs = 0);
    void finishScan(const QString &id);
    void dropScans(const QString &drive); // the drive left: its volumes' scans go
    VolumeScan contentFor(const QString &id) const;
    void answer(const QString &op, const QString &id, const QString &status);
    int indexOf(const QString &id) const;

    QList<Entry> m_entries;
    SystemUsage m_usage;
    int m_usageCalls = 0;
    QTimer m_plugTimer;
    bool m_holdEject = false;
    QStringList m_heldEjects;
    int m_ejectCalls = 0;
    QMap<QString, QString> m_saved;
    int m_saveCalls = 0;
    QString m_saveStatus;
    struct MockFile
    {
        QString text;
        qint64 modified = 0;
    };
    QHash<QString, QMap<QString, MockFile>> m_files; // by volume id, then name
    QString m_readStatus;
    QStringList m_readCalls; // "<id>/<name>"
    int m_delay = 0;
    int m_pending = 0;
    QHash<QString, VolumeScan> m_scans;
    QString m_scanning; // the volume being scanned, "" if none
    bool m_holdScan = false;
    bool m_scanPartial = false;
    bool m_scanFailed = false;
    QStringList m_scanCalls;
    QStringList m_cancelCalls;
};
