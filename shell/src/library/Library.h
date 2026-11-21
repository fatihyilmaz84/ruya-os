#pragma once

#include "LibraryBackend.h"

#include <QObject>
#include <QQmlEngine>
#include <QStringList>
#include <QVariantList>

#include <memory>

// QML face of org.ruyaos.Library1: everything installed that can be started.
// Backend: RUYA_SERVICES=mock|dbus; the default is D-Bus on Linux (ruya-library, T-112) and the
// mock elsewhere, like Store and Profiles.
//
// Items are plain objects: { id, kind, title, source, launch, art, lastPlayed }.
class Library : public QObject
{
    Q_OBJECT
    QML_ELEMENT
    QML_SINGLETON

    // Every item, last played first.
    Q_PROPERTY(QVariantList items READ items NOTIFY itemsChanged)
    // The items with kind "game".
    Q_PROPERTY(QVariantList games READ games NOTIFY itemsChanged)
    // The eight most recently played items (lastPlayed > 0), newest first.
    Q_PROPERTY(QVariantList recent READ recent NOTIFY itemsChanged)
    // True once the service has answered (always, for the mock).
    Q_PROPERTY(bool available READ isAvailable NOTIFY availableChanged)
    Q_PROPERTY(bool mock READ isMock CONSTANT)
    // The image's runners (Library1 ListRunners, RUY-959), in its order: { family, kind, version,
    // licence, sourceUrl } ("" for an absent licence or source). Read at start and whenever the
    // service appears; the mock lists the pinned GE-Proton and Wine.
    Q_PROPERTY(QVariantList runners READ runners NOTIFY runnersChanged)
    // Whose runner choices the choice calls read and store (Shell binds the signed-in profile, as it
    // does NotificationCentre's; "" = nobody, and Library1 refuses the calls as "invalid").
    Q_PROPERTY(QString profile READ profile WRITE setProfile NOTIFY profileChanged)

public:
    explicit Library(std::unique_ptr<LibraryBackend> backend, QObject *parent = nullptr);
    ~Library() override;

    static Library *create(QQmlEngine *qmlEngine, QJSEngine *jsEngine);

    QVariantList items() const { return m_items; }
    QVariantList games() const { return m_games; }
    QVariantList recent() const { return m_recent; }
    bool isAvailable() const { return m_available; }
    bool isMock() const { return m_backend->isMock(); }
    QVariantList runners() const { return m_runners; }
    QString profile() const { return m_profile; }
    void setProfile(const QString &profile);

    // The signed-in profile's runner choice for a .play item (Library1, RUY-959, RUY-905): "package",
    // "bundled" or "system". The choice calls follow `profile`, so QML never passes a profile id. Each
    // answers with its signal (status: a Library1 status string); an answer for a profile that is no
    // longer in front is dropped. runnerChoice asks for the stored choice (runnerChoiceAnswered).
    Q_INVOKABLE void runnerChoice(const QString &id);
    Q_INVOKABLE void setRunnerChoice(const QString &id, const QString &choice);
    // What the launch would run the item with for that choice: resolution has playRunner,
    // playRunnerSource, playRunnerTested, playResolveError, playResolveCode ("" when absent) and
    // playFallback, as an item has. Profile-free (Library1 ResolveRunner).
    Q_INVOKABLE void resolveRunner(const QString &id, const QString &choice);

    // rescanned follows when the service has read its files again.
    Q_INVOKABLE void rescan();
    // Asks for the item to be started. Only emits launchRequested; Shell.qml answers it with
    // Session.launch for the signed-in profile (T-386).
    Q_INVOKABLE void launch(const QString &id);
    // The Flatpak application id Session1.Launch takes for an item, or "" when the item has no
    // launch path through Session1 yet (a Steam game): the shell offers no Play for those (T-147).
    Q_INVOKABLE QString sessionAppId(const QString &id) const;
    // The record of an item, or an empty object.
    Q_INVOKABLE QVariantMap item(const QString &id) const;
    // The record of the item whose Flatpak application id (sessionAppId) is appId, or an empty object. A binding
    // that calls it reads `items` too, or it is not evaluated again when the list changes (AppName).
    Q_INVOKABLE QVariantMap itemForApp(const QString &appId) const;

    // Tests only, and only with the mock backend (otherwise a no-op). scenario: "" (the default library), "empty" (nothing installed) or "unlisted" (the default items and one Flatpak app with no Store record) or "play" (the default items and one .play app with every field, RUY-852) or "unplayed" (the default
    // items, none with a last played time) or "art:<dir>" (the default items with pictures: art.tile is
    // <dir>/<colour>.png, cycling red, blue, green, white, dark, redblue; T-281 screenshots).
    Q_INVOKABLE void resetMockForTests(const QString &scenario);
    // A list request whose reply (a snapshot of now) arrives after ms, and how many replies
    // (ListItems and ListRunners) are still due. No-ops with the D-Bus backend.
    Q_INVOKABLE void mockListDelayed(int ms);
    Q_INVOKABLE int mockPendingReplies() const;
    // The service saw an app go (an uninstall finished, RUY-499): the item leaves the list and itemsChanged
    // follows, as Library1's ItemsChanged does. A no-op with the D-Bus backend.
    Q_INVOKABLE void mockRemoveItem(const QString &id);
    // Tests only, mock only: the runners the mock lists from now on (maps as in runners), then a
    // ListRunners whose reply arrives after ms. No-ops with the D-Bus backend.
    Q_INVOKABLE void mockSetRunners(const QVariantList &runners, int ms = 0);
    // Tests only, mock only (RUY-905): what ResolveRunner answers for id and choice from now on
    // (resolution keys as resolveRunner's; "package" is the item's own fields too), and which runner
    // calls ("get", "set", "resolve") answer "failed" from now on ([] none). resetMockForTests ends both.
    Q_INVOKABLE void mockSetResolution(const QString &id, const QString &choice, const QVariantMap &resolution);
    Q_INVOKABLE void mockFailRunnerCalls(const QStringList &calls);

signals:
    void itemsChanged();
    void availableChanged();
    void rescanned();
    void launchRequested(const QString &id, const QString &launchSpec);
    void runnersChanged();
    void profileChanged();
    // The choice signals are the signed-in profile's only.
    void runnerChoiceAnswered(const QString &id, const QString &status, const QString &choice);
    void runnerChoiceSet(const QString &id, const QString &choice, const QString &status);
    void runnerResolved(const QString &id, const QString &choice, const QString &status, const QVariantMap &resolution);
    // Library1 RunnerChoiceChanged for the signed-in profile (from any caller, ruya-session included).
    void runnerChoiceChanged(const QString &id, const QString &choice);

private:
    std::unique_ptr<LibraryBackend> m_backend;
    QVariantList m_items;
    QVariantList m_games;
    QVariantList m_recent;
    QVariantList m_runners;
    QString m_profile;
    bool m_available = false;
};
