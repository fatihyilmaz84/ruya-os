#pragma once

#include "RequestSequence.h"

#include <QList>
#include <QMap>
#include <QObject>
#include <QString>
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

    // The record as QML sees it (camelCase keys).
    QVariantMap toVariant() const
    {
        QVariantMap artMap;
        for (auto it = art.constBegin(); it != art.constEnd(); ++it)
            artMap.insert(it.key(), it.value());
        return {
            {QStringLiteral("id"), id},
            {QStringLiteral("kind"), kind},
            {QStringLiteral("title"), title},
            {QStringLiteral("source"), source},
            {QStringLiteral("launch"), launch},
            {QStringLiteral("art"), artMap},
            {QStringLiteral("lastPlayed"), lastPlayed},
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
