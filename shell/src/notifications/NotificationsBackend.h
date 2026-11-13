#pragma once

#include "RequestSequence.h"

#include <QList>
#include <QObject>
#include <QString>
#include <QVariantMap>

// One action of an item: (action id, label), at most two per item (api/dbus/org.ruyaos.Notifications1.xml).
struct NotificationAction
{
    QString id;
    QString label;
};

// One item of the notification centre, field for field the struct of Notifications1.List.
struct NotificationItem
{
    uint id = 0;
    QString source = QStringLiteral("system"); // "system" | "updates" | "devices" | "store" | "app"
    QString appId;
    QString kind = QStringLiteral("info");     // "info" | "success" | "warning" | "error"
    QString title;
    QString body;
    QString icon;
    QList<NotificationAction> actions;
    QString urgency = QStringLiteral("normal"); // "low" | "normal" | "critical"
    bool pinned = false;
    bool unread = true;
    qint64 time = 0;                           // unix ms
};

// The settings properties of Notifications1 (the active profile's).
struct NotificationSettings
{
    bool quiet = false;
    bool dontInterruptGames = true;
    bool quietHoursEnabled = false;
    QString quietFrom = QStringLiteral("22:00");
    QString quietTo = QStringLiteral("07:00");
    uint toastSeconds = 4;
    bool sounds = true;
    QVariantMap sourcesEnabled;                 // source -> bool; a source not listed is on

    bool operator==(const NotificationSettings &o) const
    {
        return quiet == o.quiet && dontInterruptGames == o.dontInterruptGames
            && quietHoursEnabled == o.quietHoursEnabled && quietFrom == o.quietFrom && quietTo == o.quietTo
            && toastSeconds == o.toastSeconds && sounds == o.sounds && sourcesEnabled == o.sourcesEnabled;
    }
    bool operator!=(const NotificationSettings &o) const { return !(*this == o); }
};

// Transport behind the NotificationCentre QML singleton: org.ruyaos.Notifications1 over D-Bus
// (api/dbus/org.ruyaos.Notifications1.xml, served by RUY-88's service), or an in-memory mock.
// Results arrive asynchronously through signals.
class NotificationsBackend : public QObject
{
    Q_OBJECT

public:
    using QObject::QObject;

    virtual bool isMock() const = 0;
    // List(profile): the answer is itemsListed (through the list sequence).
    virtual void refresh(const QString &profile) = 0;
    // The settings properties: the answer is settingsChanged (through the settings sequence).
    virtual void refreshSettings() = 0;
    // The profile in front. The service follows Profiles1 itself; the mock keeps settings per
    // profile and switches here. Then the settings are read again.
    virtual void selectProfile(const QString &profile) = 0;
    // The methods. Each answers `finished(op, id, status)`; op is the method's name in lower case
    // ("dismiss", "dismissall", "invoke", "markread", "withdraw"); id is the item's (0 for the others).
    virtual void dismiss(uint id) = 0;
    virtual void dismissAll(const QString &profile) = 0;
    virtual void invoke(uint id, const QString &action) = 0;
    virtual void markRead(const QString &profile) = 0;
    // Post answers `posted(key, status, id)`.
    virtual void post(const QString &profile, const QString &key, const NotificationItem &item) = 0;
    virtual void withdraw(const QString &key) = 0;
    // A settings property by its XML name ("Quiet", "DontInterruptGames", "QuietHours" as
    // {enabled, from, to}, "ToastSeconds", "Sounds", "SourcesEnabled" as a map of bools); answers
    // `settingFinished(name, status)` ("ok" | "invalid" | "failed"), the new value follows by
    // settingsChanged.
    virtual void setSetting(const QString &name, const QVariant &value) = 0;

signals:
    void itemsListed(const QString &profile, const QList<NotificationItem> &items);
    void settingsChanged(const NotificationSettings &settings);
    void added(const QString &profile, const NotificationItem &item);
    void removed(const QString &profile, const QList<uint> &ids, const QString &reason);
    // Items of the profile changed in place; "" = any profile (the service came back): list again.
    void changed(const QString &profile);
    void finished(const QString &op, uint id, const QString &status);
    void posted(const QString &key, const QString &status, uint id);
    void settingFinished(const QString &name, const QString &status);

protected:
    // Replies can arrive out of order (an Added crosses a List reply): number each request when it
    // is sent and report a reply only if no newer one of the same kind was reported (RequestSequence.h).
    // A failed request counts as an outcome too: call failItems/failSettings for it.
    quint64 beginItemsRequest() { return m_itemsSeq.begin(); }
    void deliverItems(quint64 request, const QString &profile, const QList<NotificationItem> &items)
    {
        if (m_itemsSeq.accept(request))
            emit itemsListed(profile, items);
    }
    void failItems(quint64 request) { m_itemsSeq.accept(request); }
    quint64 beginSettingsRequest() { return m_settingsSeq.begin(); }
    void deliverSettings(quint64 request, const NotificationSettings &settings)
    {
        if (m_settingsSeq.accept(request))
            emit settingsChanged(settings);
    }
    void failSettings(quint64 request) { m_settingsSeq.accept(request); }

private:
    RequestSequence m_itemsSeq;
    RequestSequence m_settingsSeq;
};
