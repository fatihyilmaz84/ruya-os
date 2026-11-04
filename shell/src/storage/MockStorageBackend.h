#pragma once

#include "StorageBackend.h"

#include <QTimer>

// In-memory storage. Present at start: the internal disk (ext4) and "Old Drive", a USB drive
// whose filesystem is not supported (listed, never mounted). A USB exFAT stick, "Ruya Stick",
// is plugged in a moment after the start (3 s; 30 ms with RUYA_MOCK_FAST=1; never with RUYA_MOCK_NO_STICK=1, which the tests set) and announced with
// volumeAdded. Ejecting it removes it (the tests can plug it in again); a stick marked busy
// answers "busy" and stays. Nothing is ever read from or run on a mock volume.
class MockStorageBackend final : public StorageBackend
{
    Q_OBJECT

public:
    explicit MockStorageBackend(QObject *parent = nullptr);

    bool isMock() const override { return true; }
    void refresh() override;
    void eject(const QString &id) override;

    // Tests only.
    void reset(bool plugStick);
    void plugStick();
    void setBusy(const QString &id, bool busy);

private:
    struct Entry
    {
        StorageVolume vol;
        bool present = false;
        bool busy = false;
    };

    void initState();
    void publish();
    void answer(const QString &op, const QString &id, const QString &status);
    int indexOf(const QString &id) const;

    QList<Entry> m_entries;
    QTimer m_plugTimer;
};
