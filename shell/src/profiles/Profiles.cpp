#include "Profiles.h"

#include "DBusProfilesBackend.h"
#include "MockProfilesBackend.h"

Profiles::Profiles(std::unique_ptr<ProfilesBackend> backend, QObject *parent)
    : QObject(parent)
    , m_backend(std::move(backend))
{
    connect(m_backend.get(), &ProfilesBackend::listed, this, [this](const QList<ProfileInfo> &list) {
        QVariantList out;
        for (const ProfileInfo &p : list) {
            out.append(QVariantMap{
                {QStringLiteral("id"), p.id},
                {QStringLiteral("name"), p.name},
                {QStringLiteral("avatar"), p.avatar},
                {QStringLiteral("role"), p.role},
                {QStringLiteral("hasPin"), p.hasPin},
            });
        }
        m_profiles = out;
        emit profilesChanged();
        emit activeProfileChanged(); // `active` resolves against the new list
    });
    connect(m_backend.get(), &ProfilesBackend::guestsListed, this, [this](const QList<GuestInfo> &list) {
        QVariantList out;
        for (const GuestInfo &g : list) {
            out.append(QVariantMap{
                {QStringLiteral("id"), g.id},
                {QStringLiteral("avatar"), g.avatar},
                {QStringLiteral("number"), g.number},
            });
        }
        if (out != m_guests) {
            m_guests = out;
            emit guestsChanged();
        }
    });
    connect(m_backend.get(), &ProfilesBackend::activeChanged, this, [this](const QString &id) {
        if (id != m_active) {
            m_active = id;
            emit activeProfileChanged();
        }
    });
    connect(m_backend.get(), &ProfilesBackend::availabilityChanged, this, [this](bool available) {
        if (available != m_available) {
            m_available = available;
            emit availableChanged();
        }
    });
    connect(m_backend.get(), &ProfilesBackend::switchFinished, this, &Profiles::switchFinished);
    connect(m_backend.get(), &ProfilesBackend::createFinished, this, &Profiles::createFinished);
    connect(m_backend.get(), &ProfilesBackend::setPinFinished, this, &Profiles::setPinFinished);
    connect(m_backend.get(), &ProfilesBackend::renameFinished, this, &Profiles::renameFinished);
    connect(m_backend.get(), &ProfilesBackend::deleteFinished, this, &Profiles::deleteFinished);
    connect(m_backend.get(), &ProfilesBackend::verifyAdminFinished, this, &Profiles::verifyAdminFinished);
    connect(m_backend.get(), &ProfilesBackend::pinVerified, this, &Profiles::pinVerified);
    connect(m_backend.get(), &ProfilesBackend::guestCreated, this, &Profiles::guestCreated);
    connect(m_backend.get(), &ProfilesBackend::guestRemoved, this, &Profiles::guestRemoved);
    m_backend->refresh();
}

Profiles::~Profiles() = default;

Profiles *Profiles::create(QQmlEngine *, QJSEngine *)
{
    const QString choice = qEnvironmentVariable("RUYA_SERVICES");
#ifdef Q_OS_LINUX
    const bool mock = choice == QLatin1String("mock");
#else
    const bool mock = choice != QLatin1String("dbus");
#endif
    std::unique_ptr<ProfilesBackend> backend;
    if (mock)
        backend = std::make_unique<MockProfilesBackend>();
    else
        backend = std::make_unique<DBusProfilesBackend>();
    return new Profiles(std::move(backend));
}

QVariantMap Profiles::active() const
{
    for (const QVariant &v : m_profiles) {
        const QVariantMap p = v.toMap();
        if (p.value(QStringLiteral("id")).toString() == m_active)
            return p;
    }
    return {};
}

QString Profiles::nameOf(const QString &id) const
{
    for (const QVariant &v : m_profiles) {
        const QVariantMap p = v.toMap();
        if (p.value(QStringLiteral("id")).toString() == id)
            return p.value(QStringLiteral("name")).toString();
    }
    // A temporary guest (RUY-631): "Guest" for number 1, "Guest n" for the others.
    for (const QVariant &v : m_guests) {
        const QVariantMap g = v.toMap();
        if (g.value(QStringLiteral("id")).toString() == id) {
            const int number = g.value(QStringLiteral("number")).toInt();
            return number <= 1 ? tr("Guest") : tr("Guest %1").arg(number);
        }
    }
    return {};
}

void Profiles::refresh()
{
    m_backend->refresh();
}

void Profiles::switchTo(const QString &id, const QString &pin)
{
    m_backend->switchTo(id, pin);
}

void Profiles::lock()
{
    m_backend->lock();
}

void Profiles::createProfile(const QString &adminId, const QString &adminPin, const QString &name,
                             const QString &role, const QString &pin)
{
    m_backend->createProfile(adminId, adminPin, name, role, pin);
}

void Profiles::setPin(const QString &id, const QString &oldPin, const QString &newPin)
{
    m_backend->setPin(id, oldPin, newPin);
}

void Profiles::renameProfile(const QString &actorId, const QString &actorPin, const QString &id,
                             const QString &name)
{
    m_backend->renameProfile(actorId, actorPin, id, name);
}

void Profiles::deleteProfile(const QString &adminId, const QString &adminPin, const QString &id)
{
    m_backend->deleteProfile(adminId, adminPin, id);
}

void Profiles::verifyAdmin(const QString &adminId, const QString &adminPin)
{
    m_backend->verifyAdmin(adminId, adminPin);
}

void Profiles::verifyPin(const QString &id, const QString &pin)
{
    m_backend->verifyPin(id, pin);
}

void Profiles::createGuest()
{
    m_backend->createGuest();
}

void Profiles::removeGuest(const QString &id)
{
    m_backend->removeGuest(id);
}

bool Profiles::resetMockForTests(const QString &state)
{
    auto *mock = qobject_cast<MockProfilesBackend *>(m_backend.get());
    if (!mock)
        return false;
    mock->resetForTests(state == QLatin1String("empty"));
    return true;
}

void Profiles::mockRefreshDelayed(int ms)
{
    if (auto *mock = qobject_cast<MockProfilesBackend *>(m_backend.get()))
        mock->refreshDelayed(ms);
}

void Profiles::mockSetAvailable(bool available)
{
    if (!qobject_cast<MockProfilesBackend *>(m_backend.get()) || available == m_available)
        return;
    m_available = available;
    emit availableChanged();
}

void Profiles::mockFailGuests(const QString &method, const QString &status, int times)
{
    if (auto *mock = qobject_cast<MockProfilesBackend *>(m_backend.get()))
        mock->failGuestCalls(method, status, times);
}

int Profiles::mockPendingReplies() const
{
    auto *mock = qobject_cast<MockProfilesBackend *>(m_backend.get());
    return mock ? mock->pendingReplies() : 0;
}
