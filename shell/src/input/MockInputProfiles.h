#pragma once

#include <QHash>
#include <QJsonObject>
#include <QMap>
#include <QString>
#include <QStringList>
#include <QVariantList>
#include <QVariantMap>

#include <functional>

// The controller profile members of org.ruyaos.Input1 in memory (RUY-42), for MockInputBackend:
// the service's rules in brief (services/ruya-inputd/src/book.rs and profile.rs). The built-ins
// "default" and "nintendo"; per console profile the stored profiles and the global assignment;
// SaveProfile's refusals (a built-in id or scope, a missing parent, a cycle, more than 8 links, a
// 65th profile); DeleteProfile re-parents; the summary keys of the XML. Validation covers the
// top level, ids, names, scope, inherits, match, output, mappings (inputs, targets, button and axis
// codes), settings (ranges, curves, inner + outer < 1), the list limits and the 64 KiB cap; the
// complete rules are the service's (its Rust tests and tests/profile_schema.rs).
class MockInputProfiles
{
public:
    // The family of a connected pad ("" when it has none), or a null string when no pad has that id.
    using FamilyOf = std::function<QString(const QString &deviceId)>;
    using AppIdOk = std::function<bool(const QString &appId)>;

    MockInputProfiles(FamilyOf familyOf, AppIdOk appIdOk);

    // One call of the table (InputProfileCalls.h): `args` by in-argument name, the reply by
    // out-argument name. `changed` is set to the console profile whose profiles changed, else "".
    QVariantMap call(const QString &method, const QVariantMap &args, QString *changed);
    void reset();

private:
    struct Shelf
    {
        QMap<QString, QJsonObject> profiles;
        QString global;
    };

    static QStringList validate(const QString &text, QJsonObject *out);
    const QJsonObject *profile(const QString &console, const QString &id) const;
    // From the profile to "default"; on failure `status` and `why` say what is wrong.
    QList<QJsonObject> chain(const QMap<QString, QJsonObject> &stored, const QString &id, QString *status,
                             QString *why) const;
    QVariantMap summary(const QString &console, const QJsonObject &p) const;
    QString applying(const QString &console, const QString &family, const QString &device) const;

    FamilyOf m_familyOf;
    AppIdOk m_appIdOk;
    QMap<QString, QJsonObject> m_builtins;
    QHash<QString, Shelf> m_shelves;
};
