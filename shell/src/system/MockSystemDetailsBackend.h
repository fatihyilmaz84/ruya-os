#pragma once

#include "SystemDetailsBackend.h"

#include <QString>
#include <QStringList>

// In-memory machines, three of them (the same keys the service sends; `SystemDetails.mockProfile`):
//   "dell"    a small office desktop: Core i5-10500T, Intel UHD 630, 8 GB, a SATA SSD, an Intel Bluetooth dongle
//   "amd"     a mini PC with an AMD APU: Ryzen 5, 16 GB, an NVMe drive, Wi-Fi only
//   "nvidia"  a desktop with an NVIDIA card: Ryzen 7, 32 GB, no swap, an NVMe drive and a hard disk
class MockSystemDetailsBackend final : public SystemDetailsBackend
{
    Q_OBJECT

public:
    explicit MockSystemDetailsBackend(QObject *parent = nullptr);

    bool isMock() const override { return true; }
    void refresh() override;

    static QStringList profiles();

    // Tests only.
    // Starts over with a machine ("dell" when the name is unknown) and publishes it.
    void setProfile(const QString &name);
    QString profile() const { return m_profile; }
    // Sets or removes one key and publishes (like a live value that changed or a value that
    // stopped being readable).
    void setValue(const QString &key, const QVariant &value);
    void removeValue(const QString &key);
    // Replies to refresh() arrive after `ms` (0: at once), with the data as it was when asked; the
    // number of replies still on their way. Lets a test play an old reply landing after a new one.
    void setReplyDelay(int ms) { m_delay = ms; }
    int pendingReplies() const { return m_pending; }

private:
    void publish();

    QString m_profile;
    QVariantMap m_info;
    int m_delay = 0;
    int m_pending = 0;
};
