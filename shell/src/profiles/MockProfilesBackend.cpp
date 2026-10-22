#include "MockProfilesBackend.h"

#include <QChar>
#include <QTimer>

#include <algorithm>

namespace {
constexpr int FreeAttempts = 5;
constexpr int FirstLockoutSecs = 30;
constexpr int MaxLockoutSecs = 3600;
constexpr int MaxNameChars = 32;

const QStringList AvatarColours = {
    QStringLiteral("#3a5bd9"), QStringLiteral("#d9483a"), QStringLiteral("#2fa37a"),
    QStringLiteral("#7a5bd9"), QStringLiteral("#d99a3a"), QStringLiteral("#3aa7d9"),
};

// 4-6 ASCII digits (pin.rs::is_valid).
bool isValidPin(const QString &pin)
{
    if (pin.size() < 4 || pin.size() > 6)
        return false;
    return std::all_of(pin.cbegin(), pin.cend(), [](QChar c) { return c >= QLatin1Char('0') && c <= QLatin1Char('9'); });
}

bool isValidRole(const QString &role)
{
    return role == QLatin1String("admin") || role == QLatin1String("standard") || role == QLatin1String("guest");
}

// Trimmed name, 1-32 characters, no control characters (service.rs::create_profile).
bool isValidName(const QString &trimmed)
{
    const QList<uint> chars = trimmed.toUcs4();
    if (chars.isEmpty() || chars.size() > MaxNameChars)
        return false;
    return std::none_of(chars.cbegin(), chars.cend(),
                        [](uint c) { return QChar::category(c) == QChar::Other_Control; });
}

// 5th failure -> 30 s, 6th -> 60 s, 7th -> 120 s ... capped at an hour (lockout.rs).
int lockoutSecsFor(int failures)
{
    const int doublings = std::min(failures - FreeAttempts, 16);
    return int(std::min<qint64>(qint64(FirstLockoutSecs) << doublings, MaxLockoutSecs));
}
} // namespace

MockProfilesBackend::MockProfilesBackend(QObject *parent)
    : ProfilesBackend(parent)
{
    seed();
}

void MockProfilesBackend::seed()
{
    m_entries = {
        {{QStringLiteral("p1"), QStringLiteral("Player One"), QStringLiteral("#3a5bd9"), QStringLiteral("admin"), true},
         QStringLiteral("1234")},
        {{QStringLiteral("p2"), QStringLiteral("Ada"), QStringLiteral("#d9483a"), QStringLiteral("standard"), false}, {}},
        {{QStringLiteral("p3"), QStringLiteral("Guest"), QStringLiteral("#5a6478"), QStringLiteral("guest"), false}, {}},
    };
    m_nextId = 4;
}

MockProfilesBackend::Entry *MockProfilesBackend::find(const QString &id)
{
    auto it = std::find_if(m_entries.begin(), m_entries.end(), [&](const Entry &e) { return e.info.id == id; });
    return it == m_entries.end() ? nullptr : &*it;
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

void MockProfilesBackend::publishList()
{
    QList<ProfileInfo> list;
    for (const Entry &e : std::as_const(m_entries))
        list.append(e.info);
    emit listed(list);
}

void MockProfilesBackend::resetForTests(bool empty)
{
    if (empty) {
        m_entries.clear();
        m_nextId = 1;
    } else {
        seed();
    }
    m_active.clear();
    QTimer::singleShot(0, this, [this] {
        emit activeChanged(m_active);
        publishList();
    });
}

MockProfilesBackend::Outcome MockProfilesBackend::authenticate(const QString &id, const QString &pin)
{
    Entry *e = find(id);
    if (!e)
        return {QStringLiteral("unknown-profile")};
    if (e->pin.isEmpty())
        return {QStringLiteral("ok")};
    if (!e->lockedUntil.isForever() && !e->lockedUntil.hasExpired()) {
        const int secs = int((e->lockedUntil.remainingTime() + 999) / 1000);
        return {QStringLiteral("locked-out"), 0, secs};
    }
    if (pin.isEmpty())
        return {QStringLiteral("pin-required"), std::max(0, FreeAttempts - e->failures), 0};
    if (pin == e->pin) {
        e->failures = 0;
        e->lockedUntil = QDeadlineTimer(QDeadlineTimer::Forever);
        return {QStringLiteral("ok")};
    }
    if (++e->failures >= FreeAttempts) {
        const int secs = lockoutSecsFor(e->failures);
        e->lockedUntil = QDeadlineTimer(qint64(secs) * 1000);
        return {QStringLiteral("locked-out"), 0, secs};
    }
    return {QStringLiteral("wrong-pin"), FreeAttempts - e->failures, 0};
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
    const Outcome o = authenticate(id, pin);
    finish(id, o.status, o.attemptsLeft, o.retryAfterSecs);
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

void MockProfilesBackend::createProfile(const QString &adminId, const QString &adminPin, const QString &name,
                                        const QString &role, const QString &pin)
{
    auto reply = [this](const QString &status, const QString &id = {}, int attemptsLeft = 0, int retryAfterSecs = 0) {
        QTimer::singleShot(0, this, [this, status, id, attemptsLeft, retryAfterSecs] {
            emit createFinished(status, id, attemptsLeft, retryAfterSecs);
        });
    };

    const bool firstBoot = m_entries.isEmpty();
    if (!isValidRole(role))
        return reply(QStringLiteral("invalid"));
    const QString trimmed = name.trimmed();
    if (!isValidName(trimmed))
        return reply(QStringLiteral("invalid"));
    // Admins must have a PIN; guests never have one; others may.
    bool pinOk = false;
    if (role == QLatin1String("admin"))
        pinOk = isValidPin(pin);
    else if (role == QLatin1String("guest"))
        pinOk = pin.isEmpty();
    else
        pinOk = pin.isEmpty() || isValidPin(pin);
    if (!pinOk)
        return reply(QStringLiteral("invalid"));

    if (firstBoot) {
        if (role != QLatin1String("admin"))
            return reply(QStringLiteral("not-allowed"));
    } else {
        const Entry *admin = find(adminId);
        if (!admin || admin->info.role != QLatin1String("admin"))
            return reply(QStringLiteral("not-allowed"));
        const Outcome auth = authenticate(adminId, adminPin);
        if (auth.status != QLatin1String("ok"))
            return reply(auth.status, {}, auth.attemptsLeft, auth.retryAfterSecs);
    }

    Entry created;
    created.info = {QStringLiteral("p%1").arg(m_nextId++), trimmed, AvatarColours.at(int(m_entries.size()) % AvatarColours.size()),
                    role, !pin.isEmpty()};
    created.pin = pin;
    const QString id = created.info.id;
    m_entries.append(created);
    QTimer::singleShot(0, this, [this, id] {
        publishList();                 // the list first, so the caller sees the new profile on "ok"
        emit createFinished(QStringLiteral("ok"), id, 0, 0);
    });
}

void MockProfilesBackend::setPin(const QString &id, const QString &oldPin, const QString &newPin)
{
    auto reply = [this, id](const QString &status, int attemptsLeft = 0, int retryAfterSecs = 0) {
        QTimer::singleShot(0, this, [this, id, status, attemptsLeft, retryAfterSecs] {
            if (status == QLatin1String("ok"))
                publishList();
            emit setPinFinished(id, status, attemptsLeft, retryAfterSecs);
        });
    };

    Entry *e = find(id);
    if (!e)
        return reply(QStringLiteral("unknown-profile"));
    bool allowed = false;
    if (e->info.role == QLatin1String("admin"))
        allowed = isValidPin(newPin);
    else if (e->info.role == QLatin1String("guest"))
        allowed = false;
    else
        allowed = newPin.isEmpty() || isValidPin(newPin);
    if (!allowed)
        return reply(QStringLiteral("invalid"));
    const Outcome auth = authenticate(id, oldPin);
    if (auth.status != QLatin1String("ok"))
        return reply(auth.status, auth.attemptsLeft, auth.retryAfterSecs);
    e->pin = newPin;
    e->info.hasPin = !newPin.isEmpty();
    reply(QStringLiteral("ok"));
}
