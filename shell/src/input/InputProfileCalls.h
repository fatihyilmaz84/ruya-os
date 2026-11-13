#pragma once

#include <QList>
#include <QString>
#include <QStringList>
#include <QVariantList>

// The controller profile members of org.ruyaos.Input1 (api/dbus/org.ruyaos.Input1.xml, RUY-42), as
// one table: the method name, its in-arguments and its out-arguments in the XML's order and with
// the XML's names. The D-Bus client builds every call and reads every reply from it, the mock
// records the same names, and tst_input_profiles.qml checks the table against the XML, so the
// three cannot disagree on a name or an argument's place. Every in-argument is a string.
struct InputProfileMethod
{
    QString name;
    QStringList in;
    QStringList out;
};

namespace InputProfileCalls {
const QList<InputProfileMethod> &methods();
// The method of that name, or nullptr.
const InputProfileMethod *find(const QString &name);
// The table as [{ name, in: [...], out: [...] }] for the tests.
QVariantList describe();
} // namespace InputProfileCalls
