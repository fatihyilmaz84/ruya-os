#pragma once

#include "LibraryBackend.h"

// In-memory library: ten items (Steam and Flatpak, games and apps, varied last_played), in the
// order of the contract. The scenario "empty" has no item. rescan() answers and changes nothing.
// Steam items are per profile (ADR-045): the mock's three profiles (p1 Player One, p2 Ada, p3 Sam) and
// nobody ("") have the Steam games, a profile made later (p4 on) has none. The mock plays ruya-session:
// it follows profileSelected one event-loop turn later (ActiveProfile changes, then itemsChanged when the
// visible list differs). It starts with nobody active, as Library.profile does.
// Games (RUY-137): the items are installations; ListItems groups them into games as Library1 does, by the
// active profile's links (kept per profile in memory), with the fixed order (.play, Flatpak, Steam, id), the
// preferred installation and the title suggestions. No mock source declares another source's id, so there
// is no grouping by key.
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
    // memory; "package" removes it. resolveRunner answers a choice from the mock's table for the item
    // (what the launcher answers for such a package against the pinned runners, RUY-905), else with the
    // item's own runner fields (the mock has no launcher to resolve with).
    void listRunners() override;
    void getRunnerChoice(const QString &profile, const QString &id) override;
    void setRunnerChoice(const QString &profile, const QString &id, const QString &choice) override;
    void resolveRunner(const QString &id, const QString &choice) override;
    QString activeProfile() const override { return m_active; }
    void profileSelected(const QString &profile) override;
    void setPreferredInstallation(const QString &profile, const QString &game, const QString &installation) override;
    void linkInstallations(const QString &profile, const QString &a, const QString &b) override;
    void unlinkInstallation(const QString &profile, const QString &installation) override;
    // Tests only: the runners ListRunners answers from now on, and a ListRunners reply after ms.
    void setRunners(const QList<LibraryRunner> &runners) { m_runners = runners; }
    void listRunnersDelayed(int ms);
    // Tests only: what resolveRunner answers for id and choice from now on; for "package" also the item's
    // own runner fields (and the list changes, as after a rescan).
    void setResolution(const QString &id, const QString &choice, const LibraryResolution &resolution);
    // Tests only: these runner calls ("get", "set", "resolve") answer "failed" (Library1 did not answer)
    // until the list is changed or the mock is reset; an empty list ends it.
    void setFailingRunnerCalls(const QStringList &calls) { m_failing = calls; }

    // Tests only. scenario: "", "empty", "unplayed" or "art:<dir>" (the default items, each with
    // art.tile and art.icon = a picture of <dir>, see mockArtPath), or "installations" (the default items
    // and a .play "Turbo Racer", the title of the Flatpak one, never played: RUY-137). Every scenario lists
    // the pinned runner again and forgets the runner choices, the links and the preferences.
    void reset(const QString &scenario);
    // Tests only: drops the item and announces the change (Library1's ItemsChanged after an app went).
    void removeItem(const QString &id);
    // The mock Store removed this Flatpak app: the mock Library drops its item, as the real one does once it rescans (RUY-524).
    static void flatpakUninstalled(const QString &appId);

    ~MockLibraryBackend() override;

private:
    // The Library1 status of a choice call for id ("ok" when it is a .play item).
    QString choiceStatus(const QString &profile, const QString &id) const;

    // The installations `profile` sees: Steam items only while it has them.
    QList<LibraryItem> installationsOf(const QString &profile) const;
    // The games of profile's installations under its links and preferences, in the contract's order.
    QList<LibraryItem> gamesOf(const QString &profile) const;
    // An installation call's answer, one event-loop turn later, after itemsChanged when the active
    // profile's list changed.
    void answerInstallationCall(const QString &profile, const QString &call, const QString &status, bool changed);

    QList<LibraryItem> m_items; // every installed item, Steam ones included
    QString m_active; // Library1 ActiveProfile
    QList<LibraryRunner> m_runners;
    QMap<QString, QMap<QString, QString>> m_choices; // profile -> item id -> choice
    QMap<QString, QMap<QString, LibraryResolution>> m_resolutions; // item id -> choice -> answer
    QStringList m_failing;                           // runner calls that answer "failed"
    QMap<QString, QMap<QString, QStringList>> m_links;  // profile -> anchor -> the installations linked to it
    QMap<QString, QMap<QString, QString>> m_preferred;  // profile -> game id -> installation
    QMap<QString, QString> m_versions;                  // installation id -> its display version
    int m_pending = 0; // ListItems and ListRunners replies not delivered yet
};
