#include "MockProfilesBackend.h"

#include <QChar>
#include <QTimer>

#include <algorithm>

namespace {
constexpr int FreeAttempts = 5;
constexpr int FirstLockoutSecs = 30;
constexpr int MaxLockoutSecs = 3600;
constexpr int MaxNameChars = 32;
constexpr int MaxGuests = 3; // service.rs MAX_GUESTS

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
    // RUYA_MOCK_PROFILES=empty starts in the first-boot state (shows the setup wizard).
    if (qEnvironmentVariable("RUYA_MOCK_PROFILES") == QLatin1String("empty"))
        m_nextId = 1;
    else
        seed();
}

void MockProfilesBackend::seed()
{
    m_entries = {
        {{QStringLiteral("p1"), QStringLiteral("Player One"), QStringLiteral("#3a5bd9"), QStringLiteral("admin"), true},
         QStringLiteral("1234")},
        {{QStringLiteral("p2"), QStringLiteral("Ada"), QStringLiteral("#d9483a"), QStringLiteral("standard"), false}, {}},
        {{QStringLiteral("p3"), QStringLiteral("Sam"), QStringLiteral("#5a6478"), QStringLiteral("guest"), false}, {}},
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
    refreshAfter(0);
}

void MockProfilesBackend::refreshDelayed(int ms)
{
    refreshAfter(ms);
}

void MockProfilesBackend::refreshAfter(int ms)
{
    const quint64 request = beginListRequest();
    QList<ProfileInfo> list;
    for (const Entry &e : std::as_const(m_entries))
        list.append(e.info);
    ++m_pending;
    QTimer::singleShot(ms, this, [this, request, list] {
        --m_pending;
        if (!acceptList(request))
            return;
        emit availabilityChanged(true);
        emit listed(list);
        emit activeChanged(m_active);
        if (guestCallFails(QStringLiteral("listGuests")))
            acceptGuests(beginGuestsRequest()); // a failed ListGuests: an outcome, no list (as over D-Bus)
        else
            publishGuests();
    });
}

bool MockProfilesBackend::isGuest(const QString &id) const
{
    return std::any_of(m_guests.cbegin(), m_guests.cend(), [&](const GuestInfo &g) { return g.id == id; });
}

void MockProfilesBackend::publishGuests()
{
    QList<GuestInfo> list = m_guests;
    std::sort(list.begin(), list.end(), [](const GuestInfo &a, const GuestInfo &b) { return a.number < b.number; });
    // ProfilesChanged, then the shell's ListGuests: the newest list so far.
    if (acceptGuests(beginGuestsRequest()))
        emit guestsListed(list);
}

void MockProfilesBackend::wipeGuests()
{
    if (m_guests.isEmpty())
        return;
    m_guests.clear();
    publishGuests();
}

void MockProfilesBackend::publishList()
{
    QList<ProfileInfo> list;
    for (const Entry &e : std::as_const(m_entries))
        list.append(e.info);
    // The service says ProfilesChanged and the shell lists again: the newest list so far.
    deliverList(beginListRequest(), list);
}

void MockProfilesBackend::resetForTests(bool empty)
{
    m_guestFailTimes = 0;
    if (empty) {
        m_entries.clear();
        m_nextId = 1;
    } else {
        seed();
    }
    m_active.clear();
    m_guests.clear();
    QTimer::singleShot(0, this, [this] {
        emit activeChanged(m_active);
        publishList();
        publishGuests();
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
            wipeGuests(); // a switch to another profile ends the session
            m_active = id;
            emit activeChanged(m_active);
        }
        emit switchFinished(id, status, attemptsLeft, retryAfterSecs);
    });
}

void MockProfilesBackend::switchTo(const QString &id, const QString &pin)
{
    if (isGuest(id))
        return finish(id, QStringLiteral("not-allowed")); // a guest only joins
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
        wipeGuests();
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
    // RUY-716: no new kept guests (temporary guests come from "Who's playing?"). Before the name
    // check, in the service's order (RUY-728): a blank name with role guest is not-allowed.
    if (role == QLatin1String("guest"))
        return reply(QStringLiteral("not-allowed"));
    const QString trimmed = name.trimmed();
    if (!isValidName(trimmed))
        return reply(QStringLiteral("invalid"));
    // Admins must have a PIN; others may.
    bool pinOk = false;
    if (role == QLatin1String("admin"))
        pinOk = isValidPin(pin);
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

    if (isGuest(id))
        return reply(QStringLiteral("not-allowed"));
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

void MockProfilesBackend::renameProfile(const QString &actorId, const QString &actorPin, const QString &id,
                                        const QString &name)
{
    auto reply = [this, id](const QString &status, int attemptsLeft = 0, int retryAfterSecs = 0) {
        QTimer::singleShot(0, this, [this, id, status, attemptsLeft, retryAfterSecs] {
            if (status == QLatin1String("ok"))
                publishList();
            emit renameFinished(id, status, attemptsLeft, retryAfterSecs);
        });
    };

    if (isGuest(id) || isGuest(actorId))
        return reply(QStringLiteral("not-allowed"));
    Entry *target = find(id);
    if (!target)
        return reply(QStringLiteral("unknown-profile"));
    const QString trimmed = name.trimmed();
    if (!isValidName(trimmed))
        return reply(QStringLiteral("invalid"));
    const Entry *actor = find(actorId);
    if (!actor || (actor->info.role != QLatin1String("admin") && actorId != id))
        return reply(QStringLiteral("not-allowed"));
    const Outcome auth = authenticate(actorId, actorPin);
    if (auth.status != QLatin1String("ok"))
        return reply(auth.status, auth.attemptsLeft, auth.retryAfterSecs);
    target->info.name = trimmed;
    reply(QStringLiteral("ok"));
}

void MockProfilesBackend::deleteProfile(const QString &adminId, const QString &adminPin, const QString &id)
{
    auto reply = [this, id](const QString &status, int attemptsLeft = 0, int retryAfterSecs = 0) {
        QTimer::singleShot(0, this, [this, id, status, attemptsLeft, retryAfterSecs] {
            if (status == QLatin1String("ok"))
                publishList();
            emit deleteFinished(id, status, attemptsLeft, retryAfterSecs);
        });
    };

    if (isGuest(id))
        return reply(QStringLiteral("not-allowed"));
    const Entry *target = find(id);
    if (!target)
        return reply(QStringLiteral("unknown-profile"));
    const Entry *admin = find(adminId);
    if (!admin || admin->info.role != QLatin1String("admin"))
        return reply(QStringLiteral("not-allowed"));
    const Outcome auth = authenticate(adminId, adminPin);
    if (auth.status != QLatin1String("ok"))
        return reply(auth.status, auth.attemptsLeft, auth.retryAfterSecs);
    const auto admins = std::count_if(m_entries.cbegin(), m_entries.cend(),
                                      [](const Entry &e) { return e.info.role == QLatin1String("admin"); });
    if (m_active == id || (target->info.role == QLatin1String("admin") && admins <= 1))
        return reply(QStringLiteral("not-allowed"));
    m_entries.removeIf([&](const Entry &e) { return e.info.id == id; });
    reply(QStringLiteral("ok"));
}

void MockProfilesBackend::verifyAdmin(const QString &adminId, const QString &adminPin)
{
    auto reply = [this, adminId](const QString &status, int attemptsLeft = 0, int retryAfterSecs = 0) {
        QTimer::singleShot(0, this, [this, adminId, status, attemptsLeft, retryAfterSecs] {
            emit verifyAdminFinished(adminId, status, attemptsLeft, retryAfterSecs);
        });
    };
    const Entry *admin = find(adminId);
    if (!admin || admin->info.role != QLatin1String("admin"))
        return reply(QStringLiteral("not-allowed"));
    const Outcome auth = authenticate(adminId, adminPin);
    reply(auth.status, auth.attemptsLeft, auth.retryAfterSecs);
}

void MockProfilesBackend::verifyPin(const QString &id, const QString &pin)
{
    auto reply = [this, id](const QString &status, int attemptsLeft = 0, int retryAfterSecs = 0) {
        QTimer::singleShot(0, this, [this, id, status, attemptsLeft, retryAfterSecs] {
            emit pinVerified(id, status, attemptsLeft, retryAfterSecs);
        });
    };
    if (isGuest(id))
        return reply(QStringLiteral("not-allowed"));
    // The same check and lockout as switchTo; the active profile stays.
    const Outcome auth = authenticate(id, pin);
    reply(auth.status, auth.attemptsLeft, auth.retryAfterSecs);
}

void MockProfilesBackend::failGuestCalls(const QString &method, const QString &status, int times)
{
    m_guestFailMethod = method;
    m_guestFailStatus = status;
    m_guestFailTimes = times;
}

bool MockProfilesBackend::guestCallFails(const QString &method)
{
    if (m_guestFailTimes <= 0 || m_guestFailMethod != method)
        return false;
    --m_guestFailTimes;
    return true;
}

void MockProfilesBackend::createGuest()
{
    auto reply = [this](const QString &status, const QString &id = {}, int number = 0) {
        QTimer::singleShot(0, this, [this, status, id, number] {
            if (status == QLatin1String("ok"))
                publishGuests(); // the list first, so the caller sees the guest on "ok"
            emit guestCreated(status, id, number);
        });
    };
    if (guestCallFails(QStringLiteral("createGuest")))
        return reply(m_guestFailStatus);
    if (m_active.isEmpty() || m_guests.size() >= MaxGuests)
        return reply(QStringLiteral("not-allowed"));
    int number = 1;
    while (std::any_of(m_guests.cbegin(), m_guests.cend(), [&](const GuestInfo &g) { return g.number == number; }))
        ++number;
    GuestInfo guest;
    guest.id = QStringLiteral("p%1").arg(m_nextId++);
    guest.avatar = AvatarColours.at(int(m_entries.size() + number - 1) % AvatarColours.size());
    guest.number = number;
    m_guests.append(guest);
    reply(QStringLiteral("ok"), guest.id, number);
}

void MockProfilesBackend::removeGuest(const QString &id)
{
    auto reply = [this, id](const QString &status) {
        QTimer::singleShot(0, this, [this, id, status] {
            if (status == QLatin1String("ok"))
                publishGuests();
            emit guestRemoved(id, status);
        });
    };
    if (guestCallFails(QStringLiteral("removeGuest")))
        return reply(m_guestFailStatus);
    if (!isGuest(id))
        return reply(QStringLiteral("unknown-profile")); // a kept profile is never removed here
    m_guests.removeIf([&](const GuestInfo &g) { return g.id == id; });
    reply(QStringLiteral("ok"));
}
