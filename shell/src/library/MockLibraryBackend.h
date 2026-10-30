#pragma once

#include "LibraryBackend.h"

// In-memory library: ten items (Steam and Flatpak, games and apps, varied last_played), in the
// order of the contract. The scenario "empty" has no item. rescan() answers and changes nothing.
class MockLibraryBackend final : public LibraryBackend
{
    Q_OBJECT

public:
    explicit MockLibraryBackend(QObject *parent = nullptr);

    bool isMock() const override { return true; }
    void listItems() override;
    void rescan() override;

    // Tests only.
    void reset(const QString &scenario);

private:
    QList<LibraryItem> m_items;
};
