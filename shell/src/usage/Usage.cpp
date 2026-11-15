#include "Usage.h"

#include "DBusUsageBackend.h"
#include "MockUsageBackend.h"
#include "Profiles.h"
#include "UsageStats.h"

Usage::Usage(std::unique_ptr<UsageBackend> backend, QObject *parent)
    : QObject(parent)
    , m_backend(std::move(backend))
{
    connect(m_backend.get(), &UsageBackend::loaded, this, &Usage::onLoaded);
    connect(m_backend.get(), &UsageBackend::clearFinished, this, [this](const QString &profile, const QString &status) {
        if (profile != activeProfile())
            return;
        emit clearFinished(status);
        if (status == QLatin1String("ok"))
            refresh();
    });
    connect(m_backend.get(), &UsageBackend::usageChanged, this, [this](const QString &profile) {
        // Not while no Activity page is shown: the page reads the ledger when it opens (RUY-48).
        if (!profile.isEmpty() && profile == activeProfile() && !m_watchers.isEmpty())
            refresh();
    });
}

Usage::~Usage() = default;

Usage *Usage::create(QQmlEngine *qmlEngine, QJSEngine *)
{
    std::unique_ptr<UsageBackend> backend;
    // Like Store and Profiles: D-Bus on Linux unless RUYA_SERVICES=mock, the mock elsewhere.
    const QString choice = qEnvironmentVariable("RUYA_SERVICES");
#ifdef Q_OS_LINUX
    const bool mock = choice == QLatin1String("mock");
#else
    const bool mock = choice != QLatin1String("dbus");
#endif
    if (mock)
        backend = std::make_unique<MockUsageBackend>();
    else
        backend = std::make_unique<DBusUsageBackend>();
    auto *usage = new Usage(std::move(backend));
    usage->m_engine = qmlEngine;
    // The ledger belongs to one profile: when another signs in, nothing of the old one stays.
    if (auto *profiles = qmlEngine ? qmlEngine->singletonInstance<Profiles *>("RuyaShell", "Profiles") : nullptr) {
        connect(profiles, &Profiles::activeProfileChanged, usage, [usage] {
            usage->forget();
            if (!usage->m_watchers.isEmpty())
                usage->refresh();
        });
    }
    return usage;
}

QString Usage::activeProfile() const
{
    auto *profiles = m_engine ? m_engine->singletonInstance<Profiles *>("RuyaShell", "Profiles") : nullptr;
    return profiles ? profiles->activeProfile() : QString();
}

void Usage::forget()
{
    const bool wasReady = m_ready;
    m_ready = false;
    m_status.clear();
    m_today.clear();
    m_rows.clear();
    m_sessions.clear();
    m_week = UsageStats::week({}, {});
    m_top.clear();
    m_history.clear();
    m_highlights = UsageStats::highlights({}, {});
    m_pages = 1;
    m_more = false;
    m_capped = false;
    emit dataChanged();
    if (wasReady)
        emit readyChanged();
}

void Usage::refresh()
{
    const QString profile = activeProfile();
    if (profile.isEmpty()) {
        forget();
        return;
    }
    m_backend->refresh(profile, qMin(m_pages * kPageSize, kMaxSessions));
}

void Usage::setWatching(QObject *page, bool on)
{
    if (!page)
        return;
    if (!on) {
        m_watchers.remove(page);
        return;
    }
    if (m_watchers.contains(page))
        return;
    m_watchers.insert(page);
    connect(page, &QObject::destroyed, this, [this](QObject *gone) { m_watchers.remove(gone); });
    refresh();
}

void Usage::loadMore()
{
    if (!m_more)
        return;
    ++m_pages;
    refresh();
}

void Usage::onLoaded(const QString &profile, const UsageSnapshot &snapshot)
{
    // A reply for a profile that is no longer active is dropped: its data must not show.
    if (profile != activeProfile())
        return;
    const bool wasReady = m_ready;
    const QString oldStatus = m_status;
    m_status = snapshot.status;
    m_ready = snapshot.status == QLatin1String("ok");
    if (m_ready) {
        // Fewer sessions than asked for: that was all of them. Asking for the most the service lists: the rest is out of reach.
        const bool full = snapshot.sessions.size() >= snapshot.limit;
        const bool more = full && snapshot.limit < kMaxSessions;
        const bool capped = full && snapshot.limit >= kMaxSessions;
        const bool same = m_today == snapshot.today && m_rows == snapshot.rows && m_sessions == snapshot.sessions
                          && m_more == more && m_capped == capped;
        if (!same) {
            m_more = more;
            m_capped = capped;
            m_today = snapshot.today;
            m_rows = snapshot.rows;
            m_sessions = snapshot.sessions;
            m_week = UsageStats::week(m_rows, m_today);
            m_top = UsageStats::top(m_rows, m_today);
            m_history = UsageStats::history(m_sessions, kMaxSessions);
            m_highlights = UsageStats::highlights(m_rows, m_today);
            emit dataChanged();
        }
    }
    if (wasReady != m_ready || oldStatus != m_status)
        emit readyChanged();
}

QVariantMap Usage::game(const QString &appId) const
{
    return UsageStats::game(m_rows, appId, m_today);
}

int Usage::daysAgo(const QString &day) const
{
    return UsageStats::daysAgo(day, m_today);
}

void Usage::clearHistory()
{
    const QString profile = activeProfile();
    if (profile.isEmpty()) {
        emit clearFinished(QStringLiteral("not-allowed"));
        return;
    }
    m_backend->clearHistory(profile);
}

void Usage::reportPresence(const QString &instance, const QString &attention)
{
    m_backend->reportPresence(activeProfile(), instance, attention);
}

void Usage::mockReset()
{
    if (auto *mock = qobject_cast<MockUsageBackend *>(m_backend.get())) {
        mock->reset();
        forget();
    }
}

void Usage::mockSetData(const QString &profile, const QVariantList &sessions, const QString &today)
{
    if (auto *mock = qobject_cast<MockUsageBackend *>(m_backend.get())) {
        mock->setToday(today);
        mock->setData(profile, sessions);
    }
}

void Usage::mockSeedDemo(const QString &profile, const QString &today)
{
    if (auto *mock = qobject_cast<MockUsageBackend *>(m_backend.get()))
        mock->seedDemo(profile, today);
}

void Usage::mockRefreshDelayed(int ms)
{
    if (auto *mock = qobject_cast<MockUsageBackend *>(m_backend.get()))
        mock->setReplyDelay(ms);
}

void Usage::mockFailNextClear(const QString &status)
{
    if (auto *mock = qobject_cast<MockUsageBackend *>(m_backend.get()))
        mock->failNextClear(status);
}

void Usage::mockFailNextRefresh(const QString &status)
{
    if (auto *mock = qobject_cast<MockUsageBackend *>(m_backend.get()))
        mock->failNextRefresh(status);
}

void Usage::mockTouch(const QString &profile)
{
    if (auto *mock = qobject_cast<MockUsageBackend *>(m_backend.get()))
        mock->touch(profile);
}

int Usage::mockPendingReplies() const
{
    auto *mock = qobject_cast<MockUsageBackend *>(m_backend.get());
    return mock ? mock->pendingReplies() : 0;
}

QVariantMap Usage::mockLastPresence() const
{
    auto *mock = qobject_cast<MockUsageBackend *>(m_backend.get());
    return mock ? mock->lastPresence() : QVariantMap();
}

int Usage::mockReadCount() const
{
    auto *mock = qobject_cast<MockUsageBackend *>(m_backend.get());
    return mock ? mock->readCount() : 0;
}

int Usage::mockLastLimit() const
{
    auto *mock = qobject_cast<MockUsageBackend *>(m_backend.get());
    return mock ? mock->lastLimit() : 0;
}

int Usage::mockPresenceCount() const
{
    auto *mock = qobject_cast<MockUsageBackend *>(m_backend.get());
    return mock ? mock->presenceCount() : 0;
}
