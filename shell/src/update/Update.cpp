#include "Update.h"

#include "DBusUpdateBackend.h"
#include "MockUpdateBackend.h"

Update::Update(std::unique_ptr<UpdateBackend> backend, QObject *parent)
    : QObject(parent)
    , m_backend(std::move(backend))
{
    connect(m_backend.get(), &UpdateBackend::statusChanged, this, [this](const UpdateStatus &status) {
        const bool becameStaged = status.state == QLatin1String("staged") && m_status.state != status.state;
        m_status = status;
        m_known = true;
        emit statusChanged();
        if (becameStaged)
            emit stagedReady(status.staged);
    });
    connect(m_backend.get(), &UpdateBackend::requestFinished, this, &Update::requestFinished);
    m_backend->refresh();
}

Update::~Update() = default;

Update *Update::create(QQmlEngine *, QJSEngine *)
{
    std::unique_ptr<UpdateBackend> backend;
    // Like Store and Profiles: D-Bus on Linux unless RUYA_SERVICES=mock, the mock elsewhere.
    const QString choice = qEnvironmentVariable("RUYA_SERVICES");
#ifdef Q_OS_LINUX
    const bool mock = choice == QLatin1String("mock");
#else
    const bool mock = choice != QLatin1String("dbus");
#endif
    if (mock)
        backend = std::make_unique<MockUpdateBackend>();
    else
        backend = std::make_unique<DBusUpdateBackend>();
    return new Update(std::move(backend));
}

void Update::check()
{
    m_backend->check();
}

void Update::download()
{
    m_backend->download();
}

void Update::rollback()
{
    m_backend->rollback();
}

void Update::setChannel(const QString &channel)
{
    m_backend->setChannel(channel);
}

void Update::mockReset()
{
    if (auto *mock = qobject_cast<MockUpdateBackend *>(m_backend.get()))
        mock->reset();
}

void Update::mockSetUpdateExists(bool exists)
{
    if (auto *mock = qobject_cast<MockUpdateBackend *>(m_backend.get()))
        mock->setUpdateExists(exists);
}

void Update::mockSetRollbackAvailable(bool available)
{
    if (auto *mock = qobject_cast<MockUpdateBackend *>(m_backend.get()))
        mock->setRollbackAvailable(available);
}

void Update::mockFailNextCheck()
{
    if (auto *mock = qobject_cast<MockUpdateBackend *>(m_backend.get()))
        mock->setFailNext(true);
}

void Update::mockPauseDownloadAt(int percent)
{
    if (auto *mock = qobject_cast<MockUpdateBackend *>(m_backend.get()))
        mock->setPauseAt(percent);
}

void Update::mockResumeDownload()
{
    if (auto *mock = qobject_cast<MockUpdateBackend *>(m_backend.get()))
        mock->resume();
}

int Update::mockRollbackCount() const
{
    auto *mock = qobject_cast<MockUpdateBackend *>(m_backend.get());
    return mock ? mock->rollbackCount() : 0;
}
