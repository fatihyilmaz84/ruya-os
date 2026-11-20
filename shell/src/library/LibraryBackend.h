#pragma once

#include "RequestSequence.h"

#include <QList>
#include <QMap>
#include <QObject>
#include <QString>
#include <QStringList>
#include <QVariantMap>

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
    // The launcher's own runner resolution for the package's default choice (RUY-903); all "" for a native game.
    QString playRunner;                    // "<family> <version>" the launch would use, e.g. "wine 10.2"
    QString playRunnerSource;              // "bundled" | "system" (with playRunner)
    QString playRunnerTested;              // the version the developer tested with; "" when none
    QString playResolveError;              // one sentence: why the launch would refuse; "" when it can start

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
            out.insert(QStringLiteral("playRunner"), playRunner);
            out.insert(QStringLiteral("playRunnerSource"), playRunnerSource);
            out.insert(QStringLiteral("playRunnerTested"), playRunnerTested);
            out.insert(QStringLiteral("playResolveError"), playResolveError);
        }
        return out;
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

signals:
    void itemsListed(const QList<LibraryItem> &items);
    // The list changed in the service: the facade lists again.
    void itemsChanged();
    void rescanFinished();

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

private:
    RequestSequence m_listSeq;
};
