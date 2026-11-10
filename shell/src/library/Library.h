#pragma once

#include "LibraryBackend.h"

#include <QObject>
#include <QQmlEngine>
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

public:
    explicit Library(std::unique_ptr<LibraryBackend> backend, QObject *parent = nullptr);
    ~Library() override;

    static Library *create(QQmlEngine *qmlEngine, QJSEngine *jsEngine);

    QVariantList items() const { return m_items; }
    QVariantList games() const { return m_games; }
    QVariantList recent() const { return m_recent; }
    bool isAvailable() const { return m_available; }
    bool isMock() const { return m_backend->isMock(); }

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

    // Tests only, and only with the mock backend (otherwise a no-op). scenario: "" (the default library), "empty" (nothing installed) or "unplayed" (the default
    // items, none with a last played time) or "art:<dir>" (the default items with pictures: art.tile is
    // <dir>/<colour>.png, cycling red, blue, green, white, dark, redblue; T-281 screenshots).
    Q_INVOKABLE void resetMockForTests(const QString &scenario);
    // A list request whose reply (a snapshot of now) arrives after ms, and how many replies are
    // still due. No-ops with the D-Bus backend.
    Q_INVOKABLE void mockListDelayed(int ms);
    Q_INVOKABLE int mockPendingReplies() const;

signals:
    void itemsChanged();
    void availableChanged();
    void rescanned();
    void launchRequested(const QString &id, const QString &launchSpec);

private:
    std::unique_ptr<LibraryBackend> m_backend;
    QVariantList m_items;
    QVariantList m_games;
    QVariantList m_recent;
    bool m_available = false;
};
