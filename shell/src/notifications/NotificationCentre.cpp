#include "NotificationCentre.h"

#include "DBusNotificationsBackend.h"
#include "MockNotificationsBackend.h"

#include <QDateTime>

NotificationCentre::NotificationCentre(std::unique_ptr<NotificationsBackend> backend, QObject *parent)
    : QObject(parent)
    , m_backend(std::move(backend))
{
    connect(m_backend.get(), &NotificationsBackend::itemsListed, this,
            [this](const QString &profile, const QList<NotificationItem> &list) {
        if (profile != m_profile)
            return;             // an answer for a profile that is no longer in front
        QVariantList out;
        for (const NotificationItem &item : list)
            out.append(toMap(item));
        if (m_loaded && out == m_items)
            return;
        m_items = out;
        m_loaded = true;
        emit itemsChanged();
    });
    connect(m_backend.get(), &NotificationsBackend::settingsChanged, this, [this](const NotificationSettings &s) {
        if (s == m_settings)
            return;
        m_settings = s;
        emit settingsChanged();
    });
    connect(m_backend.get(), &NotificationsBackend::added, this, [this](const QString &profile, const NotificationItem &item) {
        if (profile != m_profile || m_profile.isEmpty())
            return;
        refresh();
        if (item.source == QLatin1String("app"))
            emit arrived(toMap(item));
    });
    connect(m_backend.get(), &NotificationsBackend::removed, this, [this](const QString &profile, const QList<uint> &, const QString &) {
        if (profile == m_profile)
            refresh();
    });
    connect(m_backend.get(), &NotificationsBackend::changed, this, [this](const QString &profile) {
        if (profile.isEmpty() || profile == m_profile)
            refresh();
    });
    connect(m_backend.get(), &NotificationsBackend::finished, this, [this](const QString &op, uint id, const QString &status) {
        if (status != QLatin1String("ok"))
            qWarning("ruya-shell: Notifications1 %s answered %s", qPrintable(op), qPrintable(status));
        emit finished(op, id, status);
    });
    connect(m_backend.get(), &NotificationsBackend::posted, this, [this](const QString &key, const QString &status, uint id) {
        if (status != QLatin1String("ok"))
            qWarning("ruya-shell: Notifications1 Post answered %s", qPrintable(status));
        emit posted(key, status, id);
    });
    connect(m_backend.get(), &NotificationsBackend::settingFinished, this, &NotificationCentre::settingFinished);
    m_backend->selectProfile(m_profile);
}

NotificationCentre::~NotificationCentre() = default;

NotificationCentre *NotificationCentre::create(QQmlEngine *, QJSEngine *)
{
    std::unique_ptr<NotificationsBackend> backend;
    // Like Network and Profiles: D-Bus on Linux unless RUYA_SERVICES=mock, the mock elsewhere.
    const QString choice = qEnvironmentVariable("RUYA_SERVICES");
#ifdef Q_OS_LINUX
    const bool mock = choice == QLatin1String("mock");
#else
    const bool mock = choice != QLatin1String("dbus");
#endif
    if (mock)
        backend = std::make_unique<MockNotificationsBackend>();
    else
        backend = std::make_unique<DBusNotificationsBackend>();
    return new NotificationCentre(std::move(backend));
}

void NotificationCentre::setProfile(const QString &profile)
{
    if (profile == m_profile)
        return;
    m_profile = profile;
    const bool hadItems = !m_items.isEmpty() || m_loaded;
    m_items.clear();
    m_loaded = false;
    emit profileChanged();
    if (hadItems)
        emit itemsChanged();
    m_backend->selectProfile(profile);
    refresh();
}

void NotificationCentre::refresh()
{
    if (m_profile.isEmpty())
        return;
    m_backend->refresh(m_profile);
}

int NotificationCentre::unreadCount() const
{
    int n = 0;
    for (const QVariant &v : m_items) {
        if (v.toMap().value(QStringLiteral("unread")).toBool())
            ++n;
    }
    return n;
}

QVariantMap NotificationCentre::quietHours() const
{
    return {{QStringLiteral("enabled"), m_settings.quietHoursEnabled},
            {QStringLiteral("from"), m_settings.quietFrom},
            {QStringLiteral("to"), m_settings.quietTo}};
}

QVariantMap NotificationCentre::toMap(const NotificationItem &item)
{
    QVariantList actions;
    for (const NotificationAction &a : item.actions)
        actions.append(QVariantMap{{QStringLiteral("id"), a.id}, {QStringLiteral("label"), a.label}});
    return {
        {QStringLiteral("id"), item.id},
        {QStringLiteral("source"), item.source},
        {QStringLiteral("appId"), item.appId},
        {QStringLiteral("kind"), item.kind},
        {QStringLiteral("title"), item.title},
        {QStringLiteral("body"), item.body},
        {QStringLiteral("icon"), item.icon},
        {QStringLiteral("actions"), actions},
        {QStringLiteral("urgency"), item.urgency},
        {QStringLiteral("pinned"), item.pinned},
        {QStringLiteral("unread"), item.unread},
        {QStringLiteral("time"), double(item.time)},
    };
}

NotificationItem NotificationCentre::fromMap(const QVariantMap &entry)
{
    NotificationItem item;
    item.source = entry.value(QStringLiteral("source"), item.source).toString();
    item.appId = entry.value(QStringLiteral("appId")).toString();
    item.kind = entry.value(QStringLiteral("kind"), item.kind).toString();
    item.title = entry.value(QStringLiteral("title")).toString();
    item.body = entry.value(QStringLiteral("body")).toString();
    item.icon = entry.value(QStringLiteral("icon")).toString();
    item.urgency = entry.value(QStringLiteral("urgency"), item.urgency).toString();
    item.pinned = entry.value(QStringLiteral("pinned")).toBool();
    for (const QVariant &v : entry.value(QStringLiteral("actions")).toList()) {
        const QVariantMap a = v.toMap();
        item.actions.append({a.value(QStringLiteral("id")).toString(), a.value(QStringLiteral("label")).toString()});
    }
    return item;
}

void NotificationCentre::post(const QVariantMap &entry)
{
    if (m_profile.isEmpty())
        return;                 // nobody signed in: the toast shows, nothing is kept
    m_backend->post(m_profile, entry.value(QStringLiteral("key")).toString(), fromMap(entry));
}

void NotificationCentre::withdraw(const QString &key)
{
    if (!key.isEmpty())
        m_backend->withdraw(key);
}

void NotificationCentre::dismiss(uint id)
{
    m_backend->dismiss(id);
}

void NotificationCentre::dismissAll()
{
    if (!m_profile.isEmpty())
        m_backend->dismissAll(m_profile);
}

void NotificationCentre::invoke(uint id, const QString &action)
{
    m_backend->invoke(id, action);
}

void NotificationCentre::markRead()
{
    if (!m_profile.isEmpty() && unreadCount() > 0)
        m_backend->markRead(m_profile);
}

void NotificationCentre::setQuiet(bool on)
{
    m_backend->setSetting(QStringLiteral("Quiet"), on);
}

void NotificationCentre::setDontInterruptGames(bool on)
{
    m_backend->setSetting(QStringLiteral("DontInterruptGames"), on);
}

void NotificationCentre::setSetting(const QString &name, const QVariant &value)
{
    m_backend->setSetting(name, value);
}

QVariantMap NotificationCentre::itemById(uint id) const
{
    for (const QVariant &v : m_items) {
        const QVariantMap m = v.toMap();
        if (m.value(QStringLiteral("id")).toUInt() == id)
            return m;
    }
    return {};
}

double NotificationCentre::nowMs() const
{
    if (auto *mock = qobject_cast<MockNotificationsBackend *>(m_backend.get()))
        return double(mock->now());
    return double(QDateTime::currentMSecsSinceEpoch());
}

void NotificationCentre::mockReset()
{
    if (auto *mock = qobject_cast<MockNotificationsBackend *>(m_backend.get())) {
        mock->reset();
        mock->selectProfile(m_profile);
        refresh();
    }
}

void NotificationCentre::mockSetNow(double ms)
{
    if (auto *mock = qobject_cast<MockNotificationsBackend *>(m_backend.get()))
        mock->setNow(qint64(ms));
}

void NotificationCentre::mockAppNotify(const QVariantMap &entry)
{
    if (auto *mock = qobject_cast<MockNotificationsBackend *>(m_backend.get()))
        mock->appNotify(entry.value(QStringLiteral("profile"), m_profile).toString(), fromMap(entry));
}

void NotificationCentre::mockRefreshDelayed(int ms)
{
    if (auto *mock = qobject_cast<MockNotificationsBackend *>(m_backend.get())) {
        mock->setReplyDelay(ms);
        refresh();
        mock->setReplyDelay(0);
    }
}

int NotificationCentre::mockPendingReplies() const
{
    auto *mock = qobject_cast<MockNotificationsBackend *>(m_backend.get());
    return mock ? mock->pendingReplies() : 0;
}

int NotificationCentre::mockCalls(const QString &op) const
{
    auto *mock = qobject_cast<MockNotificationsBackend *>(m_backend.get());
    return mock ? mock->calls(op) : 0;
}
