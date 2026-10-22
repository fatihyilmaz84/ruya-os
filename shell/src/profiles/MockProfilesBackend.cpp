#include "MockProfilesBackend.h"

#include <QTimer>

#include <algorithm>

namespace {
constexpr int FreeAttempts = 5;
constexpr int LockoutSecs = 30;
} // namespace

MockProfilesBackend::MockProfilesBackend(QObject *parent)
    : ProfilesBackend(parent)
{
    m_entries = {
        {{QStringLiteral("p1"), QStringLiteral("Player One"), QStringLiteral("#3a5bd9"), QStringLiteral("admin"), true},
         QStringLiteral("1234")},
        {{QStringLiteral("p2"), QStringLiteral("Ada"), QStringLiteral("#d9483a"), QStringLiteral("standard"), false}, {}},
        {{QStringLiteral("p3"), QStringLiteral("Guest"), QStringLiteral("#5a6478"), QStringLiteral("guest"), false}, {}},
    };
}

void MockProfilesBackend::refresh()
{
    QList<ProfileInfo> list;
    for (const Entry &e : std::as_const(m_entries))
        list.append(e.info);
    QTimer::singleShot(0, this, [this, list] {
        emit availabilityChanged(true);
        emit listed(list);
        emit activeChanged(m_active);
    });
}

void MockProfilesBackend::finish(const QString &id, const QString &status, int attemptsLeft, int retryAfterSecs)
{
    QTimer::singleShot(0, this, [this, id, status, attemptsLeft, retryAfterSecs] {
        if (status == QLatin1String("ok") && m_active != id) {
            m_active = id;
            emit activeChanged(m_active);
        }
        emit switchFinished(id, status, attemptsLeft, retryAfterSecs);
    });
}

void MockProfilesBackend::switchTo(const QString &id, const QString &pin)
{
    auto it = std::find_if(m_entries.begin(), m_entries.end(), [&](const Entry &e) { return e.info.id == id; });
    if (it == m_entries.end())
        return finish(id, QStringLiteral("unknown-profile"));
    if (it->pin.isEmpty())
        return finish(id, QStringLiteral("ok"));
    if (!it->lockedUntil.isForever() && !it->lockedUntil.hasExpired()) {
        const int secs = int((it->lockedUntil.remainingTime() + 999) / 1000);
        return finish(id, QStringLiteral("locked-out"), 0, secs);
    }
    if (pin.isEmpty())
        return finish(id, QStringLiteral("pin-required"), FreeAttempts - qMin(it->failures, FreeAttempts));
    if (pin == it->pin) {
        it->failures = 0;
        it->lockedUntil = QDeadlineTimer(QDeadlineTimer::Forever);
        return finish(id, QStringLiteral("ok"));
    }
    if (++it->failures >= FreeAttempts) {
        it->lockedUntil = QDeadlineTimer(LockoutSecs * 1000);
        return finish(id, QStringLiteral("locked-out"), 0, LockoutSecs);
    }
    finish(id, QStringLiteral("wrong-pin"), FreeAttempts - it->failures);
}

void MockProfilesBackend::lock()
{
    QTimer::singleShot(0, this, [this] {
        if (!m_active.isEmpty()) {
            m_active.clear();
            emit activeChanged(m_active);
        }
    });
}
