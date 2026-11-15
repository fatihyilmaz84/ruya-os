#include "Input.h"

#include "DBusInputBackend.h"
#include "InputProfileCalls.h"
#include "MockInputBackend.h"
#include "Storage.h"

#include <QCoreApplication>
#include <QDate>
#include <QGuiApplication>
#include <QWindow>
#include <QInputDevice>
#include <QKeyEvent>
#include <QJsonDocument>
#include <QJsonObject>
#include <QTimer>

#include <algorithm>
#include <utility>

namespace {
// The import cap (06 §7): a profile file is at most 64 KiB, refused unread when larger.
constexpr int ImportCap = 64 * 1024;
} // namespace

Input::Input(std::unique_ptr<InputBackend> backend, QObject *parent)
    : QObject(parent)
    , m_backend(std::move(backend))
{
    // Key presses tell the keyboard apart from the pads (06 §11.4).
    if (QCoreApplication::instance())
        QCoreApplication::instance()->installEventFilter(this);
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
        // A new process knows no seats (RUY-121): the route alone reads as a keyboard sign-in, so the
        // players the shell last knew join again, after the route, as their pads are listed.
        replayPlayers();
        m_backend->refreshDevices();
        m_backend->refreshPlayers();
        m_backend->readConfirmButton();
        refreshConfirmButtons();
    });
    connect(m_backend.get(), &InputBackend::confirmButtonsRead, this,
            [this](const QString &profile, const QString &status, const QVariantMap &buttons) {
                if (profile != m_profile)
                    return;                       // asked for the profile before a switch
                const bool ok = status == QLatin1String("ok");
                if (!ok)
                    qInfo("ruya-shell: Input1 GetConfirmButtons answered %s", qPrintable(status));
                m_confirmsStored = ok ? buttons : QVariantMap();
                const bool availabilityChanged = ok != m_confirmsAvailable;
                m_confirmsAvailable = ok;
                showConfirmButtons(availabilityChanged);
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
                m_padDevice = deviceId;
                m_padFamily = family;
                setActiveInput(deviceId, family);
            });
    connect(m_backend.get(), &InputBackend::userActive, this, &Input::userActive);
    connect(m_backend.get(), &InputBackend::devicesListed, this, [this](bool ok, const QVariantList &devices) {
        if (ok && devices != m_devices) {
            m_devices = devices;
            emit devicesChanged();
        }
        if (ok) {
            // The navigator's pad is gone: so is the service's navigator. Not while a restarted service
            // has yet to list it (the replay sets it again once it is listed, like the players).
            if (!m_navigator.isEmpty() && m_replayNavigator != m_navigator
                && std::none_of(m_devices.cbegin(), m_devices.cend(), [this](const QVariant &d) {
                       return d.toMap().value(QStringLiteral("id")).toString() == m_navigator;
                   }))
                setNavigatorShown(QString());
            continueReplay();
        }
        const QString state = ok ? QStringLiteral("ok") : QStringLiteral("failed");
        if (state != m_devicesState) {
            m_devicesState = state;
            emit devicesStateChanged();
        }
    });
    connect(m_backend.get(), &InputBackend::devicesChanged, this, [this] { m_backend->refreshDevices(); });
    connect(m_backend.get(), &InputBackend::playersListed, this, [this](bool ok, const QVariantList &players) {
        if (!ok || players == m_players)
            return;
        m_players = players;
        emit playersChanged();
    });
    connect(m_backend.get(), &InputBackend::joinFinished, this,
            [this](const QString &deviceId, const QString &profile, const QString &status, uint slot) {
                if (status != QLatin1String("ok"))
                    qInfo("ruya-shell: Input1 JoinPlayer %s as %s answered %s", qPrintable(deviceId),
                          qPrintable(profile), qPrintable(status));
                // The shell's own replay after a restart is nobody's join: it is not announced.
                const QString key = deviceId + QLatin1Char('|') + profile;
                if (m_replays.value(key) > 0) {
                    if (--m_replays[key] == 0)
                        m_replays.remove(key);
                    return;
                }
                emit joinFinished(deviceId, profile, status, int(slot));
            });
    connect(m_backend.get(), &InputBackend::navigatorFinished, this,
            [this](const QString &deviceId, const QString &status) {
                if (status != QLatin1String("ok")) {
                    qInfo("ruya-shell: Input1 SetNavigator %s answered %s", qPrintable(deviceId),
                          qPrintable(status));
                    if (deviceId == m_navigator)
                        setNavigatorShown(QString());
                }
                // The shell's own replay after a restart is nobody's call: it is not announced.
                if (m_navigatorReplays > 0) {
                    --m_navigatorReplays;
                    return;
                }
                emit navigatorFinished(deviceId, status);
            });
    connect(m_backend.get(), &InputBackend::foreignInput, this, [this](const QString &deviceId, const QString &kind) {
        if (kind == QLatin1String("player-guide")) {
            uint slot = 0;
            for (const QVariant &p : std::as_const(m_players)) {
                const QVariantMap player = p.toMap();
                if (player.value(QStringLiteral("device_id")).toString() == deviceId)
                    slot = player.value(QStringLiteral("slot")).toUInt();
            }
            qInfo("ruya-shell: player %u's Guide (no players' Hub yet)", slot);
        }
        emit foreignInput(deviceId, kind);
    });
    connect(m_backend.get(), &InputBackend::leaveFinished, this, [this](uint slot, const QString &status) {
        if (status != QLatin1String("ok"))
            qInfo("ruya-shell: Input1 LeavePlayer %u answered %s", slot, qPrintable(status));
        emit leaveFinished(int(slot), status);
    });
    connect(m_backend.get(), &InputBackend::capabilitiesFinished, this, &Input::capabilitiesFinished);
    connect(m_backend.get(), &InputBackend::testStartFinished, this, &Input::testStartFinished);
    connect(m_backend.get(), &InputBackend::testInput, this, &Input::testInput);
    connect(m_backend.get(), &InputBackend::testEnded, this, &Input::testEnded);
    connect(m_backend.get(), &InputBackend::profileReply, this, &Input::onProfileReply);
    connect(m_backend.get(), &InputBackend::profilesChanged, this, &Input::profilesChanged);
    m_replayTimer.setSingleShot(true);
    connect(&m_replayTimer, &QTimer::timeout, this, [this] {
        // The hold ran out: the players whose pad is still not listed are dropped, the ones behind
        // them (listed) join now.
        QSet<QString> listed;
        for (const QVariant &d : std::as_const(m_devices))
            listed.insert(d.toMap().value(QStringLiteral("id")).toString());
        for (auto it = m_replayQueue.begin(); it != m_replayQueue.end();) {
            if (listed.contains(it->device)) {
                ++it;
                continue;
            }
            qInfo("ruya-shell: Input1 replay: player %u's pad %s did not come back within the hold; dropped",
                  it->slot, qPrintable(it->device));
            it = m_replayQueue.erase(it);
        }
        continueReplay();
    });
    m_backend->refreshDevices();
    m_backend->refreshPlayers();
    m_backend->readConfirmButton();
    refreshConfirmButtons();
}

Input::~Input() = default;

// Seat 1 first, as the route's profile (a seat 1 without a pad has nothing to join), then the other
// players by slot, so each gets its own seat back in the restarted service.
void Input::replayPlayers()
{
    m_replayQueue.clear();
    m_replayTimer.stop();
    m_replayProfile = m_profile;
    m_replayNavigator = m_profile.isEmpty() ? QString() : m_navigator;
    if (m_profile.isEmpty())
        return;
    QList<QVariantMap> seats;
    for (const QVariant &p : std::as_const(m_players))
        seats.append(p.toMap());
    std::sort(seats.begin(), seats.end(), [](const QVariantMap &a, const QVariantMap &b) {
        return a.value(QStringLiteral("slot")).toUInt() < b.value(QStringLiteral("slot")).toUInt();
    });
    for (const QVariantMap &p : std::as_const(seats)) {
        const uint slot = p.value(QStringLiteral("slot")).toUInt();
        const QString device = p.value(QStringLiteral("device_id")).toString();
        const QString profile = slot == 1 ? m_profile : p.value(QStringLiteral("profile")).toString();
        if (device.isEmpty() || profile.isEmpty())
            continue;
        m_replayQueue.append({device, profile, slot});
    }
    // A player whose pad is not listed within the hold would have expired as a held seat (RUY-644).
    if (!m_replayQueue.isEmpty())
        m_replayTimer.start(m_replayHoldMs);
}

// A restarted service lists its pads only after its first scan, which may come after the shell's
// route: each player joins again once the service lists its pad, in slot order; a pad not listed
// yet waits for the next list (every device signal asks for one). A profile change drops the rest.
void Input::continueReplay()
{
    if (m_replayQueue.isEmpty() && m_replayNavigator.isEmpty())
        return;
    if (m_profile != m_replayProfile) {
        m_replayQueue.clear();
        m_replayTimer.stop();
        m_replayNavigator.clear();
        return;
    }
    QSet<QString> listed;
    for (const QVariant &d : std::as_const(m_devices))
        listed.insert(d.toMap().value(QStringLiteral("id")).toString());
    // The navigator too (RUY-38), after the players' joins sent in this turn, so the service has the
    // seats first; a navigator the shell dropped or changed meanwhile is not set again.
    QString navigator;
    if (m_replayNavigator != m_navigator)
        m_replayNavigator.clear();
    else if (listed.contains(m_replayNavigator))
        navigator = std::exchange(m_replayNavigator, QString());
    // In slot order, and not past a pad that is still away: a later seat must not take a lower
    // number than it had (RUY-644; JoinPlayer gives the lowest free seat).
    QList<Replay> waiting;
    bool blocked = false;
    for (const Replay &r : std::as_const(m_replayQueue)) {
        if (blocked || !listed.contains(r.device)) {
            blocked = true;
            waiting.append(r);
            continue;
        }
        qInfo("ruya-shell: Input1 has a new owner: player %u joins again on %s", r.slot, qPrintable(r.device));
        ++m_replays[r.device + QLatin1Char('|') + r.profile];
        m_backend->joinPlayer(r.device, r.profile);
    }
    m_replayQueue = waiting;
    if (m_replayQueue.isEmpty())
        m_replayTimer.stop();
    if (!navigator.isEmpty()) {
        qInfo("ruya-shell: Input1 has a new owner: %s drives the UI again", qPrintable(navigator));
        ++m_navigatorReplays;
        m_backend->setNavigator(navigator);
    }
}

void Input::setNavigatorShown(const QString &deviceId)
{
    if (deviceId == m_navigator)
        return;
    m_navigator = deviceId;
    emit navigatorChanged();
}

void Input::setNavigator(const QString &deviceId)
{
    setNavigatorShown(deviceId);
    m_backend->setNavigator(deviceId);
}

QString Input::mockNavigator() const
{
    auto *mock = qobject_cast<MockInputBackend *>(m_backend.get());
    return mock ? mock->navigator() : QString();
}

void Input::mockPadButton(const QString &deviceId, const QString &button)
{
    auto *mock = qobject_cast<MockInputBackend *>(m_backend.get());
    const int key = mock ? mock->padButton(deviceId, button) : 0;
    QWindow *window = QGuiApplication::focusWindow();
    if (!key || !window)
        return;
    // As a key of the service's virtual keyboard: the source is told apart first (06 §11.4), then the
    // focused item gets it.
    noteKeyFrom(QStringLiteral("RuyaOS Navigation"), key);
    QKeyEvent press(QEvent::KeyPress, key, Qt::NoModifier);
    QKeyEvent release(QEvent::KeyRelease, key, Qt::NoModifier);
    QCoreApplication::sendEvent(window, &press);
    QCoreApplication::sendEvent(window, &release);
}

void Input::joinPlayer(const QString &deviceId, const QString &profile)
{
    m_backend->joinPlayer(deviceId, profile);
}

void Input::leavePlayer(int slot)
{
    m_backend->leavePlayer(slot < 0 ? 0u : uint(slot));
}

QVariantList Input::mockPlayers() const
{
    auto *mock = qobject_cast<MockInputBackend *>(m_backend.get());
    return mock ? mock->players() : QVariantList();
}

void Input::mockFailJoin(const QString &status)
{
    if (auto *mock = qobject_cast<MockInputBackend *>(m_backend.get()))
        mock->setFailJoin(status);
}

void Input::mockPlayersDelayMs(int ms)
{
    if (auto *mock = qobject_cast<MockInputBackend *>(m_backend.get()))
        mock->setPlayersDelayMs(ms);
}

void Input::mockSeatHoldMs(int ms)
{
    if (auto *mock = qobject_cast<MockInputBackend *>(m_backend.get()))
        mock->setSeatHoldMs(ms);
    m_replayHoldMs = ms;
}

int Input::mockReplayPending() const
{
    return int(m_replayQueue.size());
}

// What the rows show: the service's choices with every change still on its way on top, so a read
// that answers before a set does not take the new value back.
void Input::showConfirmButtons(bool force)
{
    QVariantMap next = m_confirmsStored;
    for (auto it = m_confirmsWanted.cbegin(); it != m_confirmsWanted.cend(); ++it) {
        if (it.value() == QLatin1String("family"))
            next.remove(it.key());
        else
            next.insert(it.key(), it.value());
    }
    if (!force && next == m_confirms)
        return;
    m_confirms = next;
    emit confirmButtonsChanged();
}

void Input::forgetConfirmButtons()
{
    const bool had = !m_confirms.isEmpty() || m_confirmsAvailable;
    m_confirms.clear();
    m_confirmsStored.clear();
    m_confirmsWanted.clear();
    m_confirmsInFlight.clear();
    m_confirmsAvailable = false;
    if (had)
        emit confirmButtonsChanged();
}

void Input::refreshConfirmButtons()
{
    if (m_profile.isEmpty()) {
        forgetConfirmButtons();           // nobody signed in: no choices to show
        return;
    }
    m_backend->readConfirmButtons(m_profile);
}

void Input::setConfirmButton(const QString &deviceId, const QString &mode)
{
    const QString shown = m_confirms.value(deviceId, QStringLiteral("family")).toString();
    if (mode == shown && m_confirmsAvailable)
        return;
    // Shown at once; the answer confirms it or puts the stored value back.
    m_confirmsWanted.insert(deviceId, mode);
    m_confirmsInFlight[deviceId] += 1;
    showConfirmButtons(false);
    callProfile(QStringLiteral("SetConfirmButton"),
                {{QStringLiteral("profile"), m_profile}, {QStringLiteral("device"), deviceId}, {QStringLiteral("mode"), mode}},
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

void Input::forgetConsoleProfile(const QString &profile)
{
    callProfile(QStringLiteral("ForgetConsoleProfile"), {{QStringLiteral("profile"), profile}}, Purpose::Plain);
}

void Input::storedConsoleProfiles()
{
    callProfile(QStringLiteral("StoredConsoleProfiles"), {}, Purpose::Plain);
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
        if (profile != m_profile)
            return;                           // a set for the profile before a switch
        const QString device = args.value(QStringLiteral("device")).toString();
        const QString mode = args.value(QStringLiteral("mode")).toString();
        if (m_confirmsInFlight.contains(device) && --m_confirmsInFlight[device] <= 0) {
            m_confirmsInFlight.remove(device);
            m_confirmsWanted.remove(device);   // the newest change has its answer
        }
        const bool ok = status == QLatin1String("ok");
        if (ok) {
            if (mode == QLatin1String("family"))
                m_confirmsStored.remove(device);
            else
                m_confirmsStored.insert(device, mode);
        } else {
            qInfo("ruya-shell: Input1 SetConfirmButton for %s answered %s", qPrintable(device), qPrintable(status));
        }
        showConfirmButtons(false);
        if (!ok)
            emit confirmButtonRefused(device, status);
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
    else if (method == QLatin1String("ForgetConsoleProfile")) {
        // Not retried and not shown: the next start's sweep forgets what is left (RUY-468).
        if (status != QLatin1String("ok"))
            qWarning("ruya-shell: Input1 ForgetConsoleProfile for %s answered %s", qPrintable(profile), qPrintable(status));
        emit consoleProfileForgotten(profile, status);
    } else if (method == QLatin1String("StoredConsoleProfiles")) {
        if (status != QLatin1String("ok"))
            qWarning("ruya-shell: Input1 StoredConsoleProfiles answered %s", qPrintable(status));
        emit storedConsoleProfilesListed(status, reply.value(QStringLiteral("profiles")).toStringList());
    }
}

QStringList Input::mockStoredConsoleProfiles() const
{
    auto *mock = qobject_cast<MockInputBackend *>(m_backend.get());
    return mock ? mock->storedConsoles() : QStringList();
}

void Input::mockAddStoredConsoleProfile(const QString &profile)
{
    if (auto *mock = qobject_cast<MockInputBackend *>(m_backend.get()))
        mock->addStoredConsole(profile);
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
        const bool profileChanged = profile != m_profile;
        m_route = route;
        m_instance = instance;
        m_appId = appId;
        m_profile = profile;
        emit routeChanged();
        if (profileChanged) {
            // The service drops its navigator with the profile (RUY-38).
            setNavigatorShown(QString());
            // Another profile's choices: the last one's are not shown while its own are on their way.
            m_confirmsStored.clear();
            m_confirmsWanted.clear();
            m_confirmsInFlight.clear();
            showConfirmButtons(false);
            refreshConfirmButtons();
        }
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

void Input::setActiveInput(const QString &deviceId, const QString &family)
{
    if (deviceId == m_activeDevice && family == m_activeFamily)
        return;
    m_activeDevice = deviceId;
    m_activeFamily = family;
    emit activeInputChanged();
}

QString Input::keyboardSourceOf(const QString &deviceName, int key)
{
    // The keys the shell navigates or types with (shell/CLAUDE.md's key table, the text entry, 06
    // §11.2's keyboard column); not volume, media or power keys, which a remote or a power
    // button sends as a keyboard too.
    const bool counts = key < Qt::Key_Escape
                        || (key >= Qt::Key_Escape && key <= Qt::Key_PageDown)
                        || key == Qt::Key_Menu || key == Qt::Key_HomePage
                        || key == Qt::Key_Super_L || key == Qt::Key_Super_R || key == Qt::Key_Meta;
    if (!counts || deviceName.isEmpty() || deviceName == QLatin1String("core keyboard"))
        return {};
    return deviceName == QLatin1String("RuyaOS Navigation") ? QStringLiteral("pad") : QStringLiteral("keyboard");
}

void Input::noteKeyFrom(const QString &deviceName, int key)
{
    if (!m_keySourcesLogged.contains(deviceName) && m_keySourcesLogged.size() < 16) {
        // Once per source device, so the Dell and the VM show what Qt reports as a key's source.
        m_keySourcesLogged.insert(deviceName);
        qInfo("ruya-shell: key events come from \"%s\"", qPrintable(deviceName));
    }
    const QString source = keyboardSourceOf(deviceName, key);
    if (source == QLatin1String("keyboard")) {
        if (m_activeFamily != QLatin1String("keyboard"))
            qInfo("ruya-shell: active input is the keyboard (\"%s\")", qPrintable(deviceName));
        setActiveInput(QString(), QStringLiteral("keyboard"));
    } else if (source == QLatin1String("pad") && m_activeFamily == QLatin1String("keyboard")) {
        setActiveInput(m_padDevice, m_padFamily);
    }
}

bool Input::eventFilter(QObject *watched, QEvent *event)
{
    // A key reaches the window and then the focused item: both pass here, which changes nothing.
    if (event->type() == QEvent::KeyPress) {
        auto *key = static_cast<QKeyEvent *>(event);
        if (!key->isAutoRepeat())
            noteKeyFrom(key->device() ? key->device()->name() : QString(), key->key());
    }
    return QObject::eventFilter(watched, event);
}

void Input::mockKeyFrom(const QString &deviceName, int key)
{
    noteKeyFrom(deviceName, key);
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

QString Input::mockConfirmButton(const QString &profile, const QString &deviceId) const
{
    auto *mock = qobject_cast<MockInputBackend *>(m_backend.get());
    return mock ? mock->confirmButtonOf(profile, deviceId) : QString();
}

void Input::mockDelayConfirmButtons(bool delayed)
{
    if (auto *mock = qobject_cast<MockInputBackend *>(m_backend.get()))
        mock->setConfirmButtonsDelayed(delayed);
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
