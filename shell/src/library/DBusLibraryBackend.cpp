#include "DBusLibraryBackend.h"

#include <QDBusArgument>
#include <QDBusMessage>
#include <QDBusPendingCallWatcher>
#include <QDBusPendingReply>
#include <QDBusVariant>

#include <utility>

namespace {
const QString Service = QStringLiteral("org.ruyaos.Library1");
const QString Path = QStringLiteral("/org/ruyaos/Library1");
const QString Interface = QStringLiteral("org.ruyaos.Library1");
const QString PropertiesInterface = QStringLiteral("org.freedesktop.DBus.Properties");
const QString ActiveProfile = QStringLiteral("ActiveProfile");

QDBusConnection chooseBus()
{
    return qEnvironmentVariable("RUYA_DBUS") == QLatin1String("session") ? QDBusConnection::sessionBus()
                                                                          : QDBusConnection::systemBus();
}

// a{ss}
QMap<QString, QString> parseArt(const QDBusArgument &arg)
{
    QMap<QString, QString> out;
    arg.beginMap();
    while (!arg.atEnd()) {
        QString key;
        QString value;
        arg.beginMapEntry();
        arg >> key >> value;
        arg.endMapEntry();
        out.insert(key, value);
    }
    arg.endMap();
    return out;
}

// a{sv}
QVariantMap parseDict(const QDBusArgument &arg)
{
    QVariantMap out;
    arg.beginMap();
    while (!arg.atEnd()) {
        QString key;
        QDBusVariant value;
        arg.beginMapEntry();
        arg >> key >> value;
        arg.endMapEntry();
        out.insert(key, value.variant());
    }
    arg.endMap();
    return out;
}

// The Resolution record (and the runner keys of an item record).
LibraryResolution toResolution(const QVariantMap &d)
{
    LibraryResolution r;
    r.runner = d.value(QStringLiteral("play_runner")).toString();
    r.runnerSource = d.value(QStringLiteral("play_runner_source")).toString();
    r.runnerTested = d.value(QStringLiteral("play_runner_tested")).toString();
    r.resolveError = d.value(QStringLiteral("play_resolve_error")).toString();
    r.resolveCode = d.value(QStringLiteral("play_resolve_code")).toString();
    r.fallback = d.value(QStringLiteral("play_fallback")).toBool();
    return r;
}

LibraryRunner toRunner(const QVariantMap &d)
{
    LibraryRunner r;
    r.family = d.value(QStringLiteral("family")).toString();
    r.kind = d.value(QStringLiteral("kind")).toString();
    r.version = d.value(QStringLiteral("version")).toString();
    r.licence = d.value(QStringLiteral("licence")).toString();
    r.sourceUrl = d.value(QStringLiteral("source_url")).toString();
    return r;
}

// aa{sv}, each record through convert.
template <typename T, typename Convert>
QList<T> records(const QVariant &v, Convert convert)
{
    QList<T> out;
    const QDBusArgument arg = v.value<QDBusArgument>();
    arg.beginArray();
    while (!arg.atEnd())
        out.append(convert(parseDict(arg)));
    arg.endArray();
    return out;
}

LibraryItem toItem(const QVariantMap &d)
{
    LibraryItem i;
    i.id = d.value(QStringLiteral("id")).toString();
    i.kind = d.value(QStringLiteral("kind"), i.kind).toString();
    i.title = d.value(QStringLiteral("title")).toString();
    i.source = d.value(QStringLiteral("source")).toString();
    i.launch = d.value(QStringLiteral("launch")).toString();
    const QVariant art = d.value(QStringLiteral("art"));
    if (art.canConvert<QDBusArgument>())
        i.art = parseArt(art.value<QDBusArgument>());
    i.lastPlayed = d.value(QStringLiteral("last_played")).toLongLong();
    i.play = d.value(QStringLiteral("play")).toBool();
    if (i.play) {
        i.genres = d.value(QStringLiteral("genres")).toStringList();
        const QVariant players = d.value(QStringLiteral("players"));
        if (players.canConvert<QDBusArgument>()) { // (uu)
            const QDBusArgument arg = players.value<QDBusArgument>();
            uint lo = 0;
            uint hi = 0;
            arg.beginStructure();
            arg >> lo >> hi;
            arg.endStructure();
            i.playersMin = int(lo);
            i.playersMax = int(hi);
        }
        i.controller = d.value(QStringLiteral("controller")).toString();
        const QVariant rating = d.value(QStringLiteral("age_rating"));
        if (rating.canConvert<QDBusArgument>())
            i.ageRating = parseArt(rating.value<QDBusArgument>()); // a{ss} as well
        i.playTier = d.value(QStringLiteral("play_tier")).toString();
        i.playSigner = d.value(QStringLiteral("play_signer")).toString();
        i.playSignerKeyId = d.value(QStringLiteral("play_signer_key_id")).toString();
        i.playScreenshots = d.value(QStringLiteral("play_screenshots")).toStringList();
        i.resolution = toResolution(d);
    }
    return i;
}
} // namespace

DBusLibraryBackend::DBusLibraryBackend(QObject *parent)
    : LibraryBackend(parent)
    , m_bus(chooseBus())
    , m_watcher(Service, m_bus, QDBusServiceWatcher::WatchForRegistration, this)
{
    connect(&m_watcher, &QDBusServiceWatcher::serviceRegistered, this, [this] {
        fetchActive();
        listItems();
        listRunners();
    });
    m_bus.connect(Service, Path, Interface, QStringLiteral("ItemsChanged"), this, SIGNAL(itemsChanged()));
    m_bus.connect(Service, Path, Interface, QStringLiteral("RunnerChoiceChanged"), this,
                  SIGNAL(runnerChoiceChanged(QString, QString, QString)));
    m_bus.connect(Service, Path, PropertiesInterface, QStringLiteral("PropertiesChanged"), this,
                  SLOT(onPropertiesChanged(QString, QVariantMap, QStringList)));
    fetchActive();
}

void DBusLibraryBackend::fetchActive()
{
    auto msg = QDBusMessage::createMethodCall(Service, Path, PropertiesInterface, QStringLiteral("Get"));
    msg << Interface << ActiveProfile;
    auto *watcher = new QDBusPendingCallWatcher(m_bus.asyncCall(msg), this);
    connect(watcher, &QDBusPendingCallWatcher::finished, this, [this](QDBusPendingCallWatcher *w) {
        w->deleteLater();
        QDBusPendingReply<QDBusVariant> reply = *w;
        if (reply.isValid())
            setActive(reply.value().variant().toString());
    });
}

void DBusLibraryBackend::setActive(const QString &profile)
{
    if (profile == m_activeProfile)
        return;
    m_activeProfile = profile;
    emit activeProfileChanged(profile);
}

void DBusLibraryBackend::onPropertiesChanged(const QString &interface, const QVariantMap &changed,
                                             const QStringList &invalidated)
{
    if (interface != Interface)
        return;
    if (changed.contains(ActiveProfile))
        setActive(changed.value(ActiveProfile).toString());
    else if (invalidated.contains(ActiveProfile))
        fetchActive();
}

void DBusLibraryBackend::call(const QString &method, const QVariantList &args, int outArgs, Answer done)
{
    auto msg = QDBusMessage::createMethodCall(Service, Path, Interface, method);
    msg.setArguments(args);
    auto *watcher = new QDBusPendingCallWatcher(m_bus.asyncCall(msg), this);
    connect(watcher, &QDBusPendingCallWatcher::finished, this,
            [method, outArgs, done = std::move(done)](QDBusPendingCallWatcher *w) {
                w->deleteLater();
                const QDBusMessage reply = w->reply();
                const bool ok = reply.type() == QDBusMessage::ReplyMessage && reply.arguments().size() >= outArgs;
                if (!ok)
                    qWarning("ruya-shell: Library1 %s failed: %s", qPrintable(method), qPrintable(reply.errorMessage()));
                done(ok, reply.arguments());
            });
}

void DBusLibraryBackend::listItems()
{
    const quint64 request = beginListRequest();
    call(QStringLiteral("ListItems"), {}, 1, [this, request](bool ok, const QVariantList &out) {
        if (!ok) {
            acceptList(request); // a failure is an outcome too: an older reply after it is stale
            return;
        }
        deliverList(request, records<LibraryItem>(out.constFirst(), toItem));
    });
}

void DBusLibraryBackend::listRunners()
{
    const quint64 request = beginRunnersRequest();
    call(QStringLiteral("ListRunners"), {}, 1, [this, request](bool ok, const QVariantList &out) {
        if (!ok) {
            acceptRunners(request);
            return;
        }
        deliverRunners(request, records<LibraryRunner>(out.constFirst(), toRunner));
    });
}

void DBusLibraryBackend::getRunnerChoice(const QString &profile, const QString &id)
{
    call(QStringLiteral("GetRunnerChoice"), {profile, id}, 2, [this, profile, id](bool ok, const QVariantList &out) {
        if (ok)
            emit runnerChoiceAnswered(profile, id, out.at(0).toString(), out.at(1).toString());
        else
            emit runnerChoiceAnswered(profile, id, QStringLiteral("failed"), QString());
    });
}

void DBusLibraryBackend::setRunnerChoice(const QString &profile, const QString &id, const QString &choice)
{
    call(QStringLiteral("SetRunnerChoice"), {profile, id, choice}, 1,
         [this, profile, id, choice](bool ok, const QVariantList &out) {
             emit runnerChoiceSet(profile, id, choice, ok ? out.constFirst().toString() : QStringLiteral("failed"));
         });
}

void DBusLibraryBackend::resolveRunner(const QString &id, const QString &choice)
{
    call(QStringLiteral("ResolveRunner"), {id, choice}, 2, [this, id, choice](bool ok, const QVariantList &out) {
        if (ok)
            emit runnerResolved(id, choice, out.at(0).toString(),
                                toResolution(parseDict(out.at(1).value<QDBusArgument>())));
        else
            emit runnerResolved(id, choice, QStringLiteral("failed"), LibraryResolution());
    });
}

void DBusLibraryBackend::rescan()
{
    call(QStringLiteral("Rescan"), {}, 0, [this](bool, const QVariantList &) { emit rescanFinished(); });
}
