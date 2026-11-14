#include "Input.h"

#include "DBusInputBackend.h"
#include "InputProfileCalls.h"
#include "MockInputBackend.h"
#include "Storage.h"

#include <QDate>
#include <QJsonDocument>
#include <QJsonObject>

namespace {
// The import cap (06 §7): a profile file is at most 64 KiB, refused unread when larger.
constexpr int ImportCap = 64 * 1024;
} // namespace

Input::Input(std::unique_ptr<InputBackend> backend, QObject *parent)
    : QObject(parent)
    , m_backend(std::move(backend))
{
    connect(m_backend.get(), &InputBackend::routeFinished, this, [this](const QString &status) {
        if (status != QLatin1String("ok"))
            qWarning("ruya-shell: Input1 SetRoute %s answered %s; sent again with the next change",
                     qPrintable(m_route), qPrintable(status));
        if (status == m_status)
            return;
        m_status = status;
        emit statusChanged();
    });
    connect(m_backend.get(), &InputBackend::serviceOwnedChanged, this, &Input::serviceOwnedChanged);
    // A restarted service is in "shell" with no profile (06 §8): tell it again who is in front, and
    // ask for its devices.
    connect(m_backend.get(), &InputBackend::serviceAppeared, this, [this] {
        if (!m_route.isEmpty())
            send();
        m_backend->refreshDevices();
        m_backend->readConfirmButton();
    });
    connect(m_backend.get(), &InputBackend::confirmButtonRead, this, [this](bool ok, const QString &mode) {
        const QString next = ok ? mode : QStringLiteral("family");
        if (ok == m_confirmAvailable && next == m_confirm)
            return;
        m_confirmAvailable = ok;
        m_confirm = next;
        emit confirmButtonChanged();
    });
    connect(m_backend.get(), &InputBackend::confirmButtonChanged, this, [this] { m_backend->readConfirmButton(); });
    connect(m_backend.get(), &InputBackend::activeInputChanged, this,
            [this](const QString &deviceId, const QString &family) {
                if (deviceId == m_activeDevice && family == m_activeFamily)
                    return;
                m_activeDevice = deviceId;
                m_activeFamily = family;
                emit activeInputChanged();
            });
    connect(m_backend.get(), &InputBackend::userActive, this, &Input::userActive);
    connect(m_backend.get(), &InputBackend::devicesListed, this, [this](bool ok, const QVariantList &devices) {
        if (ok && devices != m_devices) {
            m_devices = devices;
            emit devicesChanged();
        }
        const QString state = ok ? QStringLiteral("ok") : QStringLiteral("failed");
        if (state != m_devicesState) {
            m_devicesState = state;
            emit devicesStateChanged();
        }
    });
    connect(m_backend.get(), &InputBackend::devicesChanged, this, [this] { m_backend->refreshDevices(); });
    connect(m_backend.get(), &InputBackend::capabilitiesFinished, this, &Input::capabilitiesFinished);
    connect(m_backend.get(), &InputBackend::testStartFinished, this, &Input::testStartFinished);
    connect(m_backend.get(), &InputBackend::testInput, this, &Input::testInput);
    connect(m_backend.get(), &InputBackend::testEnded, this, &Input::testEnded);
    connect(m_backend.get(), &InputBackend::profileReply, this, &Input::onProfileReply);
    connect(m_backend.get(), &InputBackend::profilesChanged, this, &Input::profilesChanged);
    m_backend->refreshDevices();
    m_backend->readConfirmButton();
}

Input::~Input() = default;

void Input::setConfirmButton(const QString &mode)
{
    if (mode == m_confirm && m_confirmAvailable)
        return;
    m_previousConfirm = m_confirm;
    m_confirm = mode;                 // shown at once; the answer confirms or puts the old one back
    emit confirmButtonChanged();
    callProfile(QStringLiteral("SetConfirmButton"), {{QStringLiteral("profile"), m_profile}, {QStringLiteral("mode"), mode}},
                Purpose::Plain);
}

Input *Input::create(QQmlEngine *qmlEngine, QJSEngine *)
{
    std::unique_ptr<InputBackend> backend;
    // Like Network and Profiles: D-Bus on Linux unless RUYA_SERVICES=mock, the mock elsewhere.
    const QString choice = qEnvironmentVariable("RUYA_SERVICES");
#ifdef Q_OS_LINUX
    const bool mock = choice == QLatin1String("mock");
#else
    const bool mock = choice != QLatin1String("dbus");
#endif
    if (mock)
        backend = std::make_unique<MockInputBackend>();
    else
        backend = std::make_unique<DBusInputBackend>();
    auto *input = new Input(std::move(backend));
    if (qmlEngine)
        input->setStorage(qmlEngine->singletonInstance<Storage *>("RuyaShell", "Storage"));
    return input;
}

void Input::setStorage(Storage *storage)
{
    if (m_storage)
        disconnect(m_storage, nullptr, this, nullptr);
    m_storage = storage;
    if (!storage)
        return;
    connect(storage, &Storage::finished, this, [this](const QString &op, const QString &id, const QString &status) {
        if (op == QLatin1String("saveReport") && m_export.active && m_export.storageStage && id == m_export.volumeId)
            finishExport(status);
    });
    connect(storage, &Storage::fileRead, this,
            [this](const QString &id, const QString &name, const QString &status, const QString &text) {
                if (!m_import.active || !m_import.storageStage || id != m_import.volumeId || name != m_import.fileName)
                    return;
                m_import.storageStage = false;
                if (status != QLatin1String("ok"))
                    return finishImport(status);
                m_import.text = text;
                callProfile(QStringLiteral("ValidateProfile"), {{QStringLiteral("json"), text}}, Purpose::ImportValidate);
            });
}

// ---- controller profiles (RUY-42) ----------------------------------------------------------

void Input::callProfile(const QString &method, const QVariantMap &args, Purpose purpose)
{
    const quint64 token = m_nextToken++;
    m_purposes.insert(token, purpose);
    m_backend->callProfile(token, method, args);
}

void Input::listProfiles(const QString &profile)
{
    callProfile(QStringLiteral("ListProfiles"), {{QStringLiteral("profile"), profile}}, Purpose::Plain);
}

void Input::getProfile(const QString &profile, const QString &profileId)
{
    callProfile(QStringLiteral("GetProfile"),
                {{QStringLiteral("profile"), profile}, {QStringLiteral("profile_id"), profileId}}, Purpose::Plain);
}

void Input::saveProfile(const QString &profile, const QString &json)
{
    callProfile(QStringLiteral("SaveProfile"), {{QStringLiteral("profile"), profile}, {QStringLiteral("json"), json}},
                Purpose::Plain);
}

void Input::validateProfile(const QString &json)
{
    callProfile(QStringLiteral("ValidateProfile"), {{QStringLiteral("json"), json}}, Purpose::Plain);
}

void Input::deleteProfile(const QString &profile, const QString &profileId)
{
    callProfile(QStringLiteral("DeleteProfile"),
                {{QStringLiteral("profile"), profile}, {QStringLiteral("profile_id"), profileId}}, Purpose::Plain);
}

void Input::assignProfile(const QString &profile, const QString &scope, const QString &scopeId, const QString &profileId)
{
    callProfile(QStringLiteral("AssignProfile"),
                {{QStringLiteral("profile"), profile},
                 {QStringLiteral("scope"), scope},
                 {QStringLiteral("scope_id"), scopeId},
                 {QStringLiteral("profile_id"), profileId}},
                Purpose::Plain);
}

void Input::getEffectiveProfile(const QString &profile, const QString &deviceId, const QString &appId)
{
    callProfile(QStringLiteral("GetEffectiveProfile"),
                {{QStringLiteral("profile"), profile}, {QStringLiteral("device_id"), deviceId}, {QStringLiteral("app_id"), appId}},
                Purpose::Plain);
}

QString Input::exportFileName(const QString &profile) const
{
    return QStringLiteral("RuyaOS-controls-%1-%2.json").arg(profile, QDate::currentDate().toString(Qt::ISODate));
}

QVariantList Input::profileMethods() const
{
    return InputProfileCalls::describe();
}

void Input::exportProfile(const QString &profile, const QString &profileId, const QString &volumeId)
{
    const QString fileName = exportFileName(profile);
    if (m_export.active || !m_storage) {
        emit exportFinished(profile, profileId, volumeId, m_export.active ? QStringLiteral("busy") : QStringLiteral("failed"),
                            fileName);
        return;
    }
    m_export = Transfer{true, false, profile, profileId, volumeId, fileName, QString()};
    callProfile(QStringLiteral("GetProfile"),
                {{QStringLiteral("profile"), profile}, {QStringLiteral("profile_id"), profileId}}, Purpose::ExportGet);
}

void Input::finishExport(const QString &status)
{
    const Transfer done = m_export;
    m_export = Transfer();
    if (status != QLatin1String("ok"))
        qWarning("ruya-shell: exporting controller profile %s of %s to %s answered %s", qPrintable(done.profileId),
                 qPrintable(done.profile), qPrintable(done.volumeId), qPrintable(status));
    emit exportFinished(done.profile, done.profileId, done.volumeId, status, done.fileName);
}

void Input::importProfile(const QString &profile, const QString &volumeId, const QString &fileName,
                          const QString &targetId, const QString &targetSlot)
{
    if (m_import.active || !m_storage) {
        emit importFinished(profile, volumeId, fileName, m_import.active ? QStringLiteral("busy") : QStringLiteral("failed"),
                            QString(), {});
        return;
    }
    m_import = Transfer{true, true, profile, QString(), volumeId, fileName, QString(), targetId, targetSlot};
    m_storage->readFile(volumeId, fileName, ImportCap);
}

void Input::finishImport(const QString &status, const QStringList &errors)
{
    const Transfer done = m_import;
    m_import = Transfer();
    if (status != QLatin1String("ok"))
        qInfo("ruya-shell: importing %s from %s answered %s%s%s", qPrintable(done.fileName), qPrintable(done.volumeId),
              qPrintable(status), errors.isEmpty() ? "" : ": ", qPrintable(errors.join(QStringLiteral("; "))));
    emit importFinished(done.profile, done.volumeId, done.fileName, status, done.profileId, errors);
}

void Input::onProfileReply(quint64 token, const QString &method, const QVariantMap &args, const QVariantMap &reply)
{
    const Purpose purpose = m_purposes.take(token);
    const QString status = reply.value(QStringLiteral("status")).toString();
    const QString profile = args.value(QStringLiteral("profile")).toString();
    const QStringList errors = reply.value(QStringLiteral("errors")).toStringList();
    switch (purpose) {
    case Purpose::ExportGet:
        if (!m_export.active)
            return;
        if (status != QLatin1String("ok"))
            return finishExport(status);
        m_export.storageStage = true;
        m_storage->saveReport(m_export.volumeId, {{m_export.fileName, reply.value(QStringLiteral("json")).toString()}});
        return;
    case Purpose::ImportValidate:
        if (!m_import.active)
            return;
        if (status != QLatin1String("ok"))
            return finishImport(status, errors);
        if (!m_import.targetId.isEmpty()) {
            // The slot the page edits (RUY-572): a global profile is saved as that slot's own.
            QJsonObject doc = QJsonDocument::fromJson(m_import.text.toUtf8()).object();
            if (doc.value(QStringLiteral("scope")).toObject().value(QStringLiteral("type")).toString() == QLatin1String("global")) {
                doc.insert(QStringLiteral("id"), m_import.targetId);
                doc.remove(QStringLiteral("match"));
                const QString slot = m_import.targetSlot;
                if (slot.startsWith(QLatin1String("device:")))
                    doc.insert(QStringLiteral("match"), QJsonObject{{QStringLiteral("device"), slot.mid(7)}});
                else if (slot.startsWith(QLatin1String("family:")))
                    doc.insert(QStringLiteral("match"), QJsonObject{{QStringLiteral("family"), slot.mid(7)}});
                m_import.text = QString::fromUtf8(QJsonDocument(doc).toJson(QJsonDocument::Compact));
            }
        }
        callProfile(QStringLiteral("SaveProfile"), {{QStringLiteral("profile"), m_import.profile}, {QStringLiteral("json"), m_import.text}},
                    Purpose::ImportSave);
        return;
    case Purpose::ImportSave: {
        if (!m_import.active)
            return;
        m_import.profileId = reply.value(QStringLiteral("profile_id")).toString();
        if (status != QLatin1String("ok"))
            return finishImport(status, errors);
        // A global profile replaces the console profile's controls in games: it is assigned, to the
        // slot its match names (RUY-545: the device's, else the family's, else all controllers').
        const QJsonObject doc = QJsonDocument::fromJson(m_import.text.toUtf8()).object();
        if (doc.value(QStringLiteral("scope")).toObject().value(QStringLiteral("type")).toString() != QLatin1String("global"))
            return finishImport(status);
        const QJsonObject match = doc.value(QStringLiteral("match")).toObject();
        const QString slot = match.contains(QStringLiteral("device"))
                                 ? QStringLiteral("device:") + match.value(QStringLiteral("device")).toString()
                             : match.contains(QStringLiteral("family"))
                                 ? QStringLiteral("family:") + match.value(QStringLiteral("family")).toString()
                                 : QString();
        callProfile(QStringLiteral("AssignProfile"),
                    {{QStringLiteral("profile"), m_import.profile},
                     {QStringLiteral("scope"), QStringLiteral("global")},
                     {QStringLiteral("scope_id"), slot},
                     {QStringLiteral("profile_id"), m_import.profileId}},
                    Purpose::ImportAssign);
        return;
    }
    case Purpose::ImportAssign:
        if (m_import.active)
            finishImport(status);
        return;
    case Purpose::Plain:
        break;
    }
    if (method == QLatin1String("SetConfirmButton")) {
        if (status != QLatin1String("ok")) {
            qInfo("ruya-shell: Input1 SetConfirmButton answered %s", qPrintable(status));
            m_confirm = m_previousConfirm;
            emit confirmButtonChanged();
            emit confirmButtonRefused(status);
        }
        return;
    }
    if (method == QLatin1String("SaveProfile") && status != QLatin1String("ok"))
        qInfo("ruya-shell: Input1 SaveProfile for %s answered %s%s%s", qPrintable(profile), qPrintable(status),
              errors.isEmpty() ? "" : ": ", qPrintable(errors.join(QStringLiteral("; "))));
    if (method == QLatin1String("ListProfiles"))
        emit profilesListed(profile, status, reply.value(QStringLiteral("profiles")).toList());
    else if (method == QLatin1String("GetProfile"))
        emit profileFetched(profile, args.value(QStringLiteral("profile_id")).toString(), status,
                            reply.value(QStringLiteral("json")).toString());
    else if (method == QLatin1String("SaveProfile"))
        emit profileSaved(profile, status, reply.value(QStringLiteral("profile_id")).toString(), errors);
    else if (method == QLatin1String("ValidateProfile"))
        emit profileValidated(status, errors);
    else if (method == QLatin1String("DeleteProfile"))
        emit profileDeleted(profile, args.value(QStringLiteral("profile_id")).toString(), status);
    else if (method == QLatin1String("AssignProfile"))
        emit profileAssigned(profile, args.value(QStringLiteral("scope")).toString(), args.value(QStringLiteral("scope_id")).toString(),
                             args.value(QStringLiteral("profile_id")).toString(), status);
    else if (method == QLatin1String("GetEffectiveProfile"))
        emit effectiveProfileFetched(profile, args.value(QStringLiteral("device_id")).toString(),
                                     args.value(QStringLiteral("app_id")).toString(), status,
                                     reply.value(QStringLiteral("json")).toString(), reply.value(QStringLiteral("chain")).toStringList());
}

QVariantList Input::mockProfileCalls() const
{
    auto *mock = qobject_cast<MockInputBackend *>(m_backend.get());
    return mock ? mock->profileCalls() : QVariantList();
}

void Input::mockClearProfileCalls()
{
    if (auto *mock = qobject_cast<MockInputBackend *>(m_backend.get()))
        mock->clearProfileCalls();
}

void Input::mockResetProfiles()
{
    if (auto *mock = qobject_cast<MockInputBackend *>(m_backend.get()))
        mock->resetProfiles();
}

void Input::mockHoldSaves(bool hold)
{
    if (auto *mock = qobject_cast<MockInputBackend *>(m_backend.get()))
        mock->holdSaves(hold);
}

void Input::mockSetProfileStatusOnce(const QString &method, const QString &status)
{
    if (auto *mock = qobject_cast<MockInputBackend *>(m_backend.get()))
        mock->setProfileStatusOnce(method, status);
}

void Input::mockSetProfileStatus(const QString &method, const QString &status)
{
    if (auto *mock = qobject_cast<MockInputBackend *>(m_backend.get()))
        mock->setProfileStatus(method, status);
}

void Input::setRoute(const QString &route, const QString &instance, const QString &appId, const QString &profile)
{
    const bool same = route == m_route && instance == m_instance && appId == m_appId && profile == m_profile;
    // The same route again: nothing to do while its call is on its way or was answered "ok"; a
    // failed or refused one is sent again.
    if (same && (m_status.isEmpty() || m_status == QLatin1String("ok")))
        return;
    if (!same) {
        m_route = route;
        m_instance = instance;
        m_appId = appId;
        m_profile = profile;
        emit routeChanged();
    }
    send();
}

void Input::send()
{
    if (!m_status.isEmpty()) {
        m_status.clear();
        emit statusChanged();
    }
    m_backend->setRoute(m_route, m_instance, m_appId, m_profile);
}

QVariantList Input::mockCalls() const
{
    if (auto *mock = qobject_cast<MockInputBackend *>(m_backend.get()))
        return mock->calls();
    return {};
}

void Input::mockClearCalls()
{
    if (auto *mock = qobject_cast<MockInputBackend *>(m_backend.get()))
        mock->clearCalls();
}

QString Input::mockServiceRoute() const
{
    auto *mock = qobject_cast<MockInputBackend *>(m_backend.get());
    return mock ? mock->route() : QString();
}

QString Input::mockServiceInstance() const
{
    auto *mock = qobject_cast<MockInputBackend *>(m_backend.get());
    return mock ? mock->instance() : QString();
}

QString Input::mockServiceProfile() const
{
    auto *mock = qobject_cast<MockInputBackend *>(m_backend.get());
    return mock ? mock->profile() : QString();
}

bool Input::mockPads() const
{
    auto *mock = qobject_cast<MockInputBackend *>(m_backend.get());
    return mock ? mock->pads() : false;
}

int Input::mockPadGeneration() const
{
    auto *mock = qobject_cast<MockInputBackend *>(m_backend.get());
    return mock ? mock->padGeneration() : 0;
}

void Input::mockFail(bool fail)
{
    if (auto *mock = qobject_cast<MockInputBackend *>(m_backend.get()))
        mock->setFail(fail);
}

void Input::mockRestart()
{
    if (auto *mock = qobject_cast<MockInputBackend *>(m_backend.get()))
        mock->restart();
}

void Input::mockNameOwned(bool owned)
{
    if (auto *mock = qobject_cast<MockInputBackend *>(m_backend.get()))
        mock->setNameOwned(owned);
}

void Input::refreshDevices()
{
    m_backend->refreshDevices();
}

void Input::requestCapabilities(const QString &deviceId)
{
    m_backend->getCapabilities(deviceId);
}

void Input::startTest(const QString &deviceId, bool holdLeftStick)
{
    m_backend->startTest(deviceId, holdLeftStick);
}

void Input::stopTest(const QString &deviceId)
{
    m_backend->stopTest(deviceId);
}

void Input::mockActiveInput(const QString &deviceId, const QString &family)
{
    if (auto *mock = qobject_cast<MockInputBackend *>(m_backend.get()))
        mock->sendActiveInput(deviceId, family);
}

void Input::mockUserActive()
{
    if (auto *mock = qobject_cast<MockInputBackend *>(m_backend.get()))
        emit mock->userActive();
}

QString Input::mockConfirmButton(const QString &profile) const
{
    auto *mock = qobject_cast<MockInputBackend *>(m_backend.get());
    return mock ? mock->confirmButtonOf(profile) : QString();
}

void Input::mockAddDevice(const QVariantMap &device)
{
    if (auto *mock = qobject_cast<MockInputBackend *>(m_backend.get()))
        mock->addDevice(device);
}

void Input::mockRemoveDevice(const QString &id)
{
    if (auto *mock = qobject_cast<MockInputBackend *>(m_backend.get()))
        mock->removeDevice(id);
}

void Input::mockListFail(bool fail)
{
    if (auto *mock = qobject_cast<MockInputBackend *>(m_backend.get()))
        mock->setListFail(fail);
}

void Input::mockTestInput(const QString &id, const QString &input, int value, const QString &source)
{
    if (auto *mock = qobject_cast<MockInputBackend *>(m_backend.get()))
        mock->sendTestInput(id, input, value, source);
}

void Input::mockEndTest(const QString &id, const QString &reason)
{
    if (auto *mock = qobject_cast<MockInputBackend *>(m_backend.get()))
        mock->endTest(id, reason);
}

bool Input::mockTestRunning(const QString &id) const
{
    auto *mock = qobject_cast<MockInputBackend *>(m_backend.get());
    return mock ? mock->testRunning(id) : false;
}

bool Input::mockTestHoldsLeftStick(const QString &id) const
{
    auto *mock = qobject_cast<MockInputBackend *>(m_backend.get());
    return mock ? mock->testHoldsLeftStick(id) : false;
}

void Input::mockStickNavigates(bool on)
{
    if (auto *mock = qobject_cast<MockInputBackend *>(m_backend.get()))
        mock->setStickNavigates(on);
}

void Input::mockResetDevices()
{
    if (auto *mock = qobject_cast<MockInputBackend *>(m_backend.get()))
        mock->resetDevices();
}
