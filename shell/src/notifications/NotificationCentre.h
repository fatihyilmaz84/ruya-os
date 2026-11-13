#pragma once

#include "NotificationsBackend.h"

#include <QObject>
#include <QQmlEngine>
#include <QVariantList>
#include <QVariantMap>

#include <memory>

// QML face of org.ruyaos.Notifications1 (api/dbus/org.ruyaos.Notifications1.xml, RUY-413): the
// signed-in profile's notification history (the bell's badge, the centre sheet) and the quiet
// settings the toasts obey. `Notifications.show` (QML) posts every toast here, so the centre is the
// one list (T-245 scope 4). Backend: RUYA_SERVICES=mock|dbus; the default is D-Bus on Linux and the
// mock elsewhere. Until RUY-88 builds the service the image has no Notifications1 on the bus: the
// list stays empty there and the calls fail (logged), the toasts still show.
class NotificationCentre : public QObject
{
    Q_OBJECT
    QML_ELEMENT
    QML_SINGLETON

    // Whose history this is (Shell binds the signed-in profile; "" = nobody, no list).
    Q_PROPERTY(QString profile READ profile WRITE setProfile NOTIFY profileChanged)
    // The items, pinned first, then newest first: [{ id, source, appId, kind, title, body, icon,
    // actions: [{ id, label }], urgency, pinned, unread, time }] (time in unix ms).
    Q_PROPERTY(QVariantList items READ items NOTIFY itemsChanged)
    Q_PROPERTY(int count READ count NOTIFY itemsChanged)
    Q_PROPERTY(int unreadCount READ unreadCount NOTIFY itemsChanged)
    // The first list of this profile has arrived.
    Q_PROPERTY(bool loaded READ loaded NOTIFY itemsChanged)
    Q_PROPERTY(bool quiet READ quiet NOTIFY settingsChanged)
    Q_PROPERTY(bool dontInterruptGames READ dontInterruptGames NOTIFY settingsChanged)
    // { enabled, from, to } ("HH:MM", local time).
    Q_PROPERTY(QVariantMap quietHours READ quietHours NOTIFY settingsChanged)
    Q_PROPERTY(int toastSeconds READ toastSeconds NOTIFY settingsChanged)
    Q_PROPERTY(bool sounds READ sounds NOTIFY settingsChanged)
    Q_PROPERTY(QVariantMap sourcesEnabled READ sourcesEnabled NOTIFY settingsChanged)
    Q_PROPERTY(bool mock READ isMock CONSTANT)

public:
    explicit NotificationCentre(std::unique_ptr<NotificationsBackend> backend, QObject *parent = nullptr);
    ~NotificationCentre() override;

    static NotificationCentre *create(QQmlEngine *qmlEngine, QJSEngine *jsEngine);

    QString profile() const { return m_profile; }
    void setProfile(const QString &profile);
    QVariantList items() const { return m_items; }
    int count() const { return int(m_items.size()); }
    int unreadCount() const;
    bool loaded() const { return m_loaded; }
    bool quiet() const { return m_settings.quiet; }
    bool dontInterruptGames() const { return m_settings.dontInterruptGames; }
    QVariantMap quietHours() const;
    int toastSeconds() const { return int(m_settings.toastSeconds); }
    bool sounds() const { return m_settings.sounds; }
    QVariantMap sourcesEnabled() const { return m_settings.sourcesEnabled; }
    bool isMock() const { return m_backend->isMock(); }

    // Keeps an item for the signed-in profile (nothing while nobody is): { key, source, appId,
    // kind, title, body, icon, actions: [{ id, label }], urgency, pinned }. The answer is posted().
    Q_INVOKABLE void post(const QVariantMap &entry);
    // The keyed state is over: its item goes from every profile.
    Q_INVOKABLE void withdraw(const QString &key);
    Q_INVOKABLE void dismiss(uint id);
    Q_INVOKABLE void dismissAll();
    Q_INVOKABLE void invoke(uint id, const QString &action);
    Q_INVOKABLE void markRead();
    Q_INVOKABLE void setQuiet(bool on);
    Q_INVOKABLE void setDontInterruptGames(bool on);
    // Any settings property by its XML name (RUY-414's pane).
    Q_INVOKABLE void setSetting(const QString &name, const QVariant &value);
    // The item with this id, or an empty map.
    Q_INVOKABLE QVariantMap itemById(uint id) const;
    // Now in unix ms, on the clock the items are stamped with (the mock's, in tests).
    Q_INVOKABLE double nowMs() const;

    // Tests only, and only with the mock backend (otherwise no-ops).
    Q_INVOKABLE void mockReset();
    // Pins the mock's clock (unix ms); a negative value gives the real clock back.
    Q_INVOKABLE void mockSetNow(double ms);
    // An app's notification arriving through the bridge (RUY-88): { profile (default: the signed-in
    // one), appId, kind, title, body, icon, actions, urgency }.
    Q_INVOKABLE void mockAppNotify(const QVariantMap &entry);
    // Lists once with the reply held back `ms`, the list as it is now (the late-reply guard).
    Q_INVOKABLE void mockRefreshDelayed(int ms);
    Q_INVOKABLE int mockPendingReplies() const;
    Q_INVOKABLE int mockCalls(const QString &op) const;

signals:
    void profileChanged();
    void itemsChanged();
    void settingsChanged();
    // An app's item arrived (source "app"): the shell toasts it. The shell's own posts toast at once.
    void arrived(const QVariantMap &item);
    // op: "dismiss" | "dismissall" | "invoke" | "markread" | "withdraw"; status: see the XML.
    void finished(const QString &op, uint id, const QString &status);
    void posted(const QString &key, const QString &status, uint id);
    void settingFinished(const QString &name, const QString &status);

private:
    void refresh();
    static QVariantMap toMap(const NotificationItem &item);
    static NotificationItem fromMap(const QVariantMap &entry);

    std::unique_ptr<NotificationsBackend> m_backend;
    QString m_profile;
    QVariantList m_items;
    bool m_loaded = false;
    NotificationSettings m_settings;
};
