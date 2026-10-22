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
