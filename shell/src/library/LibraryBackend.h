#pragma once

#include "RequestSequence.h"

#include <QList>
#include <QMap>
#include <QObject>
#include <QString>
#include <QStringList>
#include <QVariantMap>

// The launcher's runner resolution of a .play app for one choice (Library1: the item record's runner
// keys, which resolve the package default, and ResolveRunner's "Resolution record"; RUY-903, RUY-905).
// Everything "" (and no fallback) for a native game.
struct LibraryResolution
{
    QString runner;       // "<family> <version>" the launch would use, e.g. "proton-ge GE-Proton11-12"
    QString runnerSource; // "bundled" | "system" (with runner)
    QString runnerTested; // the version the developer tested with; "" when none
    QString resolveError; // one English sentence: why the launch would refuse; "" when it can start
    QString resolveCode;  // its stable code (resolve.*, launch.* or a format code), with resolveError
    bool fallback = false; // the choice cannot be honoured: runner is the package default's

    // As QML sees it: playRunner, playRunnerSource, playRunnerTested, playResolveError, playResolveCode,
    // playFallback.
    void insertInto(QVariantMap &out) const
    {
        out.insert(QStringLiteral("playRunner"), runner);
        out.insert(QStringLiteral("playRunnerSource"), runnerSource);
        out.insert(QStringLiteral("playRunnerTested"), runnerTested);
        out.insert(QStringLiteral("playResolveError"), resolveError);
        out.insert(QStringLiteral("playResolveCode"), resolveCode);
        out.insert(QStringLiteral("playFallback"), fallback);
    }
    QVariantMap toVariant() const
    {
        QVariantMap out;
        insertInto(out);
        return out;
    }
    // The other way (the mock's test hook).
    static LibraryResolution fromVariant(const QVariantMap &v)
    {
        LibraryResolution r;
        r.runner = v.value(QStringLiteral("playRunner")).toString();
        r.runnerSource = v.value(QStringLiteral("playRunnerSource")).toString();
        r.runnerTested = v.value(QStringLiteral("playRunnerTested")).toString();
        r.resolveError = v.value(QStringLiteral("playResolveError")).toString();
        r.resolveCode = v.value(QStringLiteral("playResolveCode")).toString();
        r.fallback = v.value(QStringLiteral("playFallback")).toBool();
        return r;
    }
};

// One item record of org.ruyaos.Library1 (api/dbus/org.ruyaos.Library1.xml, "Item record").
struct LibraryItem
{
    QString id;
    QString kind = QStringLiteral("game"); // "game" | "app"
    QString title;
    QString source;                        // "steam" | "flatpak"
    QString launch;
    QMap<QString, QString> art;            // role ("tile", "hero", "icon") -> path or URL
    qlonglong lastPlayed = 0;              // unix seconds, 0 if unknown

    // A .play app (RUY-852). The art map then also holds "logo", "card", "cover", "preview" and
    // "trailer" when the package has them.
    bool play = false;
    QStringList genres;
    int playersMin = 0;                    // 0, 0: unknown
    int playersMax = 0;
    QString controller;                    // "full" | "partial" | "none" | ""
    QMap<QString, QString> ageRating;      // OARS attribute -> none | mild | moderate | intense
    QString playTier;                      // "official" | "developer" | "unverified" | "" (unknown)
    QString playSigner;
    QString playSignerKeyId;               // trust.json's signer_id (32 hex); "" when unsigned
    QStringList playScreenshots;           // 1080p screenshot paths in order; empty when none
    // The launcher's own runner resolution for the package's default choice (RUY-903).
    LibraryResolution resolution;

    // The record as QML sees it (camelCase keys).
    QVariantMap toVariant() const
    {
        QVariantMap artMap;
        for (auto it = art.constBegin(); it != art.constEnd(); ++it)
            artMap.insert(it.key(), it.value());
        QVariantMap out = {
            {QStringLiteral("id"), id},
            {QStringLiteral("kind"), kind},
            {QStringLiteral("title"), title},
            {QStringLiteral("source"), source},
            {QStringLiteral("launch"), launch},
            {QStringLiteral("art"), artMap},
            {QStringLiteral("lastPlayed"), lastPlayed},
        };
        if (play) { // the keys of a .play app exist only for one; every other record is unchanged
            out.insert(QStringLiteral("play"), true);
            out.insert(QStringLiteral("genres"), genres);
            out.insert(QStringLiteral("playersMin"), playersMin);
            out.insert(QStringLiteral("playersMax"), playersMax);
            out.insert(QStringLiteral("controller"), controller);
            QVariantMap rating;
            for (auto it = ageRating.constBegin(); it != ageRating.constEnd(); ++it)
                rating.insert(it.key(), it.value());
            out.insert(QStringLiteral("ageRating"), rating);
            out.insert(QStringLiteral("playTier"), playTier);
            out.insert(QStringLiteral("playSigner"), playSigner);
            out.insert(QStringLiteral("playSignerKeyId"), playSignerKeyId);
            out.insert(QStringLiteral("playScreenshots"), playScreenshots);
            resolution.insertInto(out);
        }
        return out;
    }
};

// One runner of the image (Library1 "Runner record", ListRunners, RUY-959).
struct LibraryRunner
{
    QString family;  // "proton-ge", "wine"
    QString kind;    // "wine" | "proton" | "emulator" | "engine"
    QString version; // "GE-Proton11-12"
    QString licence; // SPDX; "" when runner.json names none
    QString sourceUrl;

    QVariantMap toVariant() const
    {
        return {
            {QStringLiteral("family"), family},
            {QStringLiteral("kind"), kind},
            {QStringLiteral("version"), version},
            {QStringLiteral("licence"), licence},
            {QStringLiteral("sourceUrl"), sourceUrl},
        };
    }
};

// Transport behind the Library QML singleton: org.ruyaos.Library1 over D-Bus, or a mock.
// Results arrive asynchronously through signals.
class LibraryBackend : public QObject
{
    Q_OBJECT

public:
    using QObject::QObject;

    virtual bool isMock() const = 0;
    virtual void listItems() = 0; // answers with itemsListed
    virtual void rescan() = 0;    // answers with rescanFinished
    // RUY-959. listRunners answers with runnersListed; the choice calls with their own signals.
    // `status` is a Library1 status string ("ok", "unknown", "not_play", "invalid", "failed").
    virtual void listRunners() = 0;
    virtual void getRunnerChoice(const QString &profile, const QString &id) = 0;
    virtual void setRunnerChoice(const QString &profile, const QString &id, const QString &choice) = 0;
    virtual void resolveRunner(const QString &id, const QString &choice) = 0;

signals:
    void itemsListed(const QList<LibraryItem> &items);
    // The list changed in the service: the facade lists again.
    void itemsChanged();
    void rescanFinished();
    void runnersListed(const QList<LibraryRunner> &runners);
    void runnerChoiceAnswered(const QString &profile, const QString &id, const QString &status, const QString &choice);
    void runnerChoiceSet(const QString &profile, const QString &id, const QString &choice, const QString &status);
    // resolution: all "" unless status is "ok".
    void runnerResolved(const QString &id, const QString &choice, const QString &status, const LibraryResolution &resolution);
    // Library1 RunnerChoiceChanged.
    void runnerChoiceChanged(const QString &profile, const QString &id, const QString &choice);

protected:
    // Replies can arrive out of order: number each ListItems request when it is sent and report a
    // reply only if no newer one was reported already (RequestSequence.h, T-181, T-191).
    quint64 beginListRequest() { return m_listSeq.begin(); }
    bool acceptList(quint64 request) { return m_listSeq.accept(request); }
    void deliverList(quint64 request, const QList<LibraryItem> &items)
    {
        if (acceptList(request))
            emit itemsListed(items);
    }
    // ListRunners replies, the same way.
    quint64 beginRunnersRequest() { return m_runnersSeq.begin(); }
    bool acceptRunners(quint64 request) { return m_runnersSeq.accept(request); }
    void deliverRunners(quint64 request, const QList<LibraryRunner> &runners)
    {
        if (acceptRunners(request))
            emit runnersListed(runners);
    }

private:
    RequestSequence m_listSeq;
    RequestSequence m_runnersSeq;
};
