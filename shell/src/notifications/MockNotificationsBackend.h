#pragma once

#include "NotificationsBackend.h"

#include <QHash>

#include <functional>

// In-memory Notifications1 (api/dbus/org.ruyaos.Notifications1.xml): one list per profile, capped
// at 50 items and 7 days (pinned items are never dropped), the settings per profile, ids that are
// never reused. Every answer and every signal is delivered asynchronously (QTimer::singleShot), so
// QML sees what it will see over D-Bus, and the signals make the facade list again through the
// same late-reply guard as the D-Bus client.
class MockNotificationsBackend final : public NotificationsBackend
{
    Q_OBJECT

public:
    explicit MockNotificationsBackend(QObject *parent = nullptr);

    static constexpr int MaxItems = 50;
    static constexpr qint64 MaxAgeMs = 7LL * 24 * 60 * 60 * 1000;

    bool isMock() const override { return true; }
    void refresh(const QString &profile) override;
    void refreshSettings() override;
    void selectProfile(const QString &profile) override;
    void dismiss(uint id) override;
    void dismissAll(const QString &profile) override;
    void invoke(uint id, const QString &action) override;
    void markRead(const QString &profile) override;
    void post(const QString &profile, const QString &key, const NotificationItem &item) override;
    void withdraw(const QString &key) override;
    void setSetting(const QString &name, const QVariant &value) override;

    // Tests only.
    void reset();
    // The clock the items are stamped and aged with (unix ms); a negative value is the real clock.
    void setNow(qint64 ms) { m_now = ms; }
    qint64 now() const;
    // An app's notification as the bridge (RUY-88) will hand it over: source "app"; Added follows.
    void appNotify(const QString &profile, const NotificationItem &item);
    // Replies to refresh() arrive after `ms` (0: at once), with the list as it was when asked;
    // the number of replies still on their way.
    void setReplyDelay(int ms) { m_delay = ms; }
    int pendingReplies() const { return m_pending; }
    // How many times each method was called ("list", "dismiss", "dismissall", "invoke", "markread",
    // "post", "withdraw", "set").
    int calls(const QString &op) const { return m_calls.value(op); }

private:
    struct Entry
    {
        NotificationItem item;
        QString key;
    };
    // The profile an item id belongs to, or "" (and -1) when no list has it.
    int find(uint id, QString *profile) const;
    QList<NotificationItem> sorted(const QString &profile) const;
    // The caps: drops the oldest unpinned items past 50 and every unpinned one older than 7 days.
    void applyCaps(const QString &profile);
    // Emits after `delayMs`, counted in pendingReplies.
    void later(int delayMs, std::function<void()> fn);
    void emitRemoved(const QString &profile, const QList<uint> &ids, const QString &reason);
    void publishSettings();
    void answer(const QString &op, uint id, const QString &status);

    QHash<QString, QList<Entry>> m_lists;
    QHash<QString, NotificationSettings> m_settings;
    QString m_profile;
    uint m_nextId = 1;
    qint64 m_now = -1;
    int m_delay = 0;
    int m_pending = 0;
    QHash<QString, int> m_calls;
};
