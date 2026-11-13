#include "InputProfileCalls.h"

#include <QVariantMap>

namespace InputProfileCalls {

const QList<InputProfileMethod> &methods()
{
    static const QList<InputProfileMethod> table = {
        {QStringLiteral("ListProfiles"), {QStringLiteral("profile")},
         {QStringLiteral("status"), QStringLiteral("profiles")}},
        {QStringLiteral("GetProfile"), {QStringLiteral("profile"), QStringLiteral("profile_id")},
         {QStringLiteral("status"), QStringLiteral("json")}},
        {QStringLiteral("SaveProfile"), {QStringLiteral("profile"), QStringLiteral("json")},
         {QStringLiteral("status"), QStringLiteral("profile_id"), QStringLiteral("errors")}},
        {QStringLiteral("ValidateProfile"), {QStringLiteral("json")},
         {QStringLiteral("status"), QStringLiteral("errors")}},
        {QStringLiteral("DeleteProfile"), {QStringLiteral("profile"), QStringLiteral("profile_id")},
         {QStringLiteral("status")}},
        {QStringLiteral("AssignProfile"),
         {QStringLiteral("profile"), QStringLiteral("scope"), QStringLiteral("scope_id"), QStringLiteral("profile_id")},
         {QStringLiteral("status")}},
        {QStringLiteral("GetEffectiveProfile"),
         {QStringLiteral("profile"), QStringLiteral("device_id"), QStringLiteral("app_id")},
         {QStringLiteral("status"), QStringLiteral("json"), QStringLiteral("chain")}},
        // Not a profile member, but a call of the same shape (strings in, a status out); the Confirm
        // button row of Settings > Controllers (RUY-40).
        {QStringLiteral("SetConfirmButton"), {QStringLiteral("profile"), QStringLiteral("mode")},
         {QStringLiteral("status")}},
    };
    return table;
}

const InputProfileMethod *find(const QString &name)
{
    for (const InputProfileMethod &m : methods()) {
        if (m.name == name)
            return &m;
    }
    return nullptr;
}

QVariantList describe()
{
    QVariantList out;
    for (const InputProfileMethod &m : methods()) {
        out.append(QVariantMap{
            {QStringLiteral("name"), m.name},
            {QStringLiteral("in"), m.in},
            {QStringLiteral("out"), m.out},
        });
    }
    return out;
}

} // namespace InputProfileCalls
