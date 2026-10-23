#include "Power.h"

#include "DBusPowerBackend.h"
#include "MockPowerBackend.h"

Power::Power(std::unique_ptr<PowerBackend> backend, QObject *parent)
    : QObject(parent)
    , m_backend(std::move(backend))
{
    connect(m_backend.get(), &PowerBackend::capabilities, this,
            [this](const QString &suspend, const QString &restart, const QString &poweroff) {
                const QLatin1String yes("yes");
                const bool s = suspend == yes;
                const bool r = restart == yes;
                const bool p = poweroff == yes;
                if (s != m_suspend || r != m_restart || p != m_poweroff) {
                    // In the journal: the image checks read what logind allowed this user.
                    qInfo("ruya-shell: power: suspend=%s restart=%s poweroff=%s", qPrintable(suspend),
                          qPrintable(restart), qPrintable(poweroff));
                    m_suspend = s;
                    m_restart = r;
                    m_poweroff = p;
                    emit capabilitiesChanged();
                }
            });
    connect(m_backend.get(), &PowerBackend::finished, this, &Power::done);
    m_backend->refresh();
}

Power::~Power() = default;

Power *Power::create(QQmlEngine *, QJSEngine *)
{
    const QString choice = qEnvironmentVariable("RUYA_SERVICES");
#ifdef Q_OS_LINUX
    const bool mock = choice == QLatin1String("mock");
#else
    const bool mock = choice != QLatin1String("dbus");
#endif
    std::unique_ptr<PowerBackend> backend;
    if (mock)
        backend = std::make_unique<MockPowerBackend>();
    else
        backend = std::make_unique<DBusPowerBackend>();
    return new Power(std::move(backend));
}

void Power::suspend()
{
    perform(QStringLiteral("suspend"));
}

void Power::restart()
{
    perform(QStringLiteral("restart"));
}

void Power::powerOff()
{
    perform(QStringLiteral("poweroff"));
}

void Power::refresh()
{
    m_backend->refresh();
}

void Power::perform(const QString &action)
{
    m_lastAction = action;
    ++m_actionCount;
    emit lastActionChanged();
    m_backend->perform(action);
}

void Power::mockSetCapabilities(const QString &suspend, const QString &restart, const QString &poweroff)
{
    if (auto *mock = qobject_cast<MockPowerBackend *>(m_backend.get()))
        mock->setCapabilities(suspend, restart, poweroff);
}

void Power::mockReset()
{
    if (auto *mock = qobject_cast<MockPowerBackend *>(m_backend.get()))
        mock->setCapabilities(QStringLiteral("yes"), QStringLiteral("yes"), QStringLiteral("yes"));
    m_lastAction.clear();
    m_actionCount = 0;
    emit lastActionChanged();
}
