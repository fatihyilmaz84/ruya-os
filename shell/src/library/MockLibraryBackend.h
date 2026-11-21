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
    // Tests only: ask for the list, but deliver the reply (a snapshot of now) after ms.
    void listItemsDelayed(int ms);
    int pendingReplies() const { return m_pending; }
    void rescan() override;
    // RUY-959. The runners: the image's pinned GE-Proton and Wine until setRunners. A choice is taken for a
    // .play item only ("unknown", "not_play", "invalid" as Library1 answers), kept per profile in
    // memory; "package" removes it. resolveRunner answers every valid choice with the item's own
    // runner fields (the mock has no launcher to resolve with).
    void listRunners() override;
    void getRunnerChoice(const QString &profile, const QString &id) override;
    void setRunnerChoice(const QString &profile, const QString &id, const QString &choice) override;
    void resolveRunner(const QString &id, const QString &choice) override;
    // Tests only: the runners ListRunners answers from now on, and a ListRunners reply after ms.
    void setRunners(const QList<LibraryRunner> &runners) { m_runners = runners; }
    void listRunnersDelayed(int ms);

    // Tests only. scenario: "", "empty", "unplayed" or "art:<dir>" (the default items, each with
    // art.tile and art.icon = a picture of <dir>, see mockArtPath). Every scenario lists the pinned
    // runner again and forgets the runner choices.
    void reset(const QString &scenario);
    // Tests only: drops the item and announces the change (Library1's ItemsChanged after an app went).
    void removeItem(const QString &id);
    // The mock Store removed this Flatpak app: the mock Library drops its item, as the real one does once it rescans (RUY-524).
    static void flatpakUninstalled(const QString &appId);

    ~MockLibraryBackend() override;

private:
    // The Library1 status of a choice call for id ("ok" when it is a .play item).
    QString choiceStatus(const QString &profile, const QString &id) const;

    QList<LibraryItem> m_items;
    QList<LibraryRunner> m_runners;
    QMap<QString, QMap<QString, QString>> m_choices; // profile -> item id -> choice
    int m_pending = 0; // ListItems and ListRunners replies not delivered yet
};
