#include "MockInputProfiles.h"

#include <QJsonArray>
#include <QJsonDocument>
#include <QJsonParseError>
#include <QRegularExpression>
#include <QSet>

#include <algorithm>

namespace {
constexpr int MaxBytes = 64 * 1024;
constexpr int MaxLevels = 8;
constexpr int MaxProfiles = 64;
const QString DefaultId = QStringLiteral("default");
const QString NintendoId = QStringLiteral("nintendo");

const QStringList &buttons()
{
    static const QStringList list = {
        QStringLiteral("south"), QStringLiteral("east"), QStringLiteral("west"), QStringLiteral("north"),
        QStringLiteral("l1"), QStringLiteral("r1"), QStringLiteral("l3"), QStringLiteral("r3"),
        QStringLiteral("start"), QStringLiteral("select"), QStringLiteral("guide"), QStringLiteral("dpad_up"),
        QStringLiteral("dpad_down"), QStringLiteral("dpad_left"), QStringLiteral("dpad_right"),
        QStringLiteral("paddle1"), QStringLiteral("paddle2"), QStringLiteral("paddle3"), QStringLiteral("paddle4"),
        QStringLiteral("misc1"), QStringLiteral("touchpad_click"),
    };
    return list;
}

const QStringList &axes()
{
    static const QStringList list = {
        QStringLiteral("left_x"), QStringLiteral("left_y"), QStringLiteral("right_x"),
        QStringLiteral("right_y"), QStringLiteral("left_trigger"), QStringLiteral("right_trigger"),
    };
    return list;
}

const QStringList &motion()
{
    static const QStringList list = {
        QStringLiteral("gyro_x"), QStringLiteral("gyro_y"), QStringLiteral("gyro_z"), QStringLiteral("accel_x"),
        QStringLiteral("accel_y"), QStringLiteral("accel_z"), QStringLiteral("touchpad"),
    };
    return list;
}

// The buttons of the virtual pad (Guide never reaches it), in the service's order.
const QStringList &padButtons()
{
    static const QStringList list = {
        QStringLiteral("south"), QStringLiteral("east"), QStringLiteral("west"), QStringLiteral("north"),
        QStringLiteral("l1"), QStringLiteral("r1"), QStringLiteral("select"), QStringLiteral("start"),
        QStringLiteral("l3"), QStringLiteral("r3"), QStringLiteral("dpad_up"), QStringLiteral("dpad_down"),
        QStringLiteral("dpad_left"), QStringLiteral("dpad_right"),
    };
    return list;
}

bool matches(const QString &pattern, const QString &s)
{
    return QRegularExpression(pattern).match(s).hasMatch();
}

bool validId(const QString &s)
{
    return matches(QStringLiteral("^[a-z0-9][a-z0-9._-]{0,63}$"), s);
}

bool plainText(const QString &s)
{
    for (const QChar c : s) {
        const ushort u = c.unicode();
        if (c.category() == QChar::Other_Control || (u >= 0x202a && u <= 0x202e) || (u >= 0x2066 && u <= 0x2069))
            return false;
    }
    return true;
}

QJsonObject stickDefaults()
{
    return QJsonObject{
        {QStringLiteral("inner_deadzone"), 0.08}, {QStringLiteral("outer_deadzone"), 0.02},
        {QStringLiteral("anti_deadzone"), 0}, {QStringLiteral("sensitivity"), 1},
        {QStringLiteral("curve"), QStringLiteral("linear")}, {QStringLiteral("invert_x"), false},
        {QStringLiteral("invert_y"), false}, {QStringLiteral("smoothing"), 0},
    };
}

// Collects "path: message" lines, like the service.
struct Check
{
    QStringList errors;

    void err(const QString &path, const QString &msg) { errors.append((path.isEmpty() ? QStringLiteral("/") : path) + QStringLiteral(": ") + msg); }

    bool object(const QJsonValue &v, const QString &path, const QStringList &known, const QStringList &required)
    {
        if (!v.isObject()) {
            err(path, QStringLiteral("not an object"));
            return false;
        }
        const QJsonObject o = v.toObject();
        for (const QString &k : o.keys()) {
            if (!known.contains(k))
                err(path, QStringLiteral("unknown field ") + k);
        }
        for (const QString &r : required) {
            if (!o.contains(r))
                err(path, QStringLiteral("\"%1\" is required").arg(r));
        }
        return true;
    }

    void text(const QJsonValue &v, const QString &path, int min, int max)
    {
        if (!v.isString())
            return err(path, QStringLiteral("not a string"));
        const QString s = v.toString();
        const int len = int(s.toUcs4().size());
        if (len < min || len > max)
            return err(path, QStringLiteral("length %1, allowed %2 to %3").arg(len).arg(min).arg(max));
        if (!plainText(s))
            err(path, QStringLiteral("contains a control or text-direction character"));
    }

    void pattern(const QJsonValue &v, const QString &path, const QString &re)
    {
        if (!v.isString() || !matches(re, v.toString()))
            err(path, QStringLiteral("%1 is not a valid value here").arg(v.toVariant().toString()));
    }

    void oneOf(const QJsonValue &v, const QString &path, const QStringList &values)
    {
        if (!v.isString() || !values.contains(v.toString()))
            err(path, QStringLiteral("%1 is not one of %2").arg(v.toVariant().toString(), values.join(QStringLiteral(", "))));
    }

    void number(const QJsonValue &v, const QString &path, double min, double max)
    {
        if (!v.isDouble())
            return err(path, QStringLiteral("not a number"));
        if (v.toDouble() < min || v.toDouble() > max)
            err(path, QStringLiteral("%1, allowed %2 to %3").arg(v.toDouble()).arg(min).arg(max));
    }

    void boolean(const QJsonValue &v, const QString &path)
    {
        if (!v.isBool())
            err(path, QStringLiteral("not a boolean"));
    }

    bool array(const QJsonValue &v, const QString &path, int min, int max)
    {
        if (!v.isArray()) {
            err(path, QStringLiteral("not an array"));
            return false;
        }
        const int n = int(v.toArray().size());
        if (n < min)
            err(path, QStringLiteral("%1 items, minItems %2").arg(n).arg(min));
        if (n > max)
            err(path, QStringLiteral("%1 items, maxItems %2").arg(n).arg(max));
        return true;
    }

    void input(const QJsonValue &v, const QString &path)
    {
        if (v.isString()) {
            const QString s = v.toString();
            if (!buttons().contains(s) && !axes().contains(s) && !motion().contains(s))
                err(path, QStringLiteral("\"%1\" is not an input").arg(s));
            return;
        }
        object(v, path, {QStringLiteral("raw")}, {QStringLiteral("raw")});
    }

    void target(const QJsonValue &v, const QString &path)
    {
        if (!object(v, path, {QStringLiteral("type"), QStringLiteral("code"), QStringLiteral("invert"), QStringLiteral("scale")},
                    {QStringLiteral("type")}))
            return;
        const QJsonObject o = v.toObject();
        static const QStringList types = {
            QStringLiteral("button"), QStringLiteral("axis"), QStringLiteral("key"), QStringLiteral("mouse_button"),
            QStringLiteral("mouse_move"), QStringLiteral("scroll"), QStringLiteral("layer"), QStringLiteral("macro"),
            QStringLiteral("action"), QStringLiteral("none"),
        };
        oneOf(o.value(QStringLiteral("type")), path + QStringLiteral("/type"), types);
        if (o.contains(QStringLiteral("code")))
            pattern(o.value(QStringLiteral("code")), path + QStringLiteral("/code"), QStringLiteral("^[a-z0-9_]{1,32}$"));
        if (o.contains(QStringLiteral("scale")))
            number(o.value(QStringLiteral("scale")), path + QStringLiteral("/scale"), -8, 8);
        const QString type = o.value(QStringLiteral("type")).toString();
        const QStringList *names = type == QLatin1String("button") ? &buttons() : type == QLatin1String("axis") ? &axes() : nullptr;
        if (!names)
            return;
        if (!o.contains(QStringLiteral("code")))
            err(path, QStringLiteral("a %1 target needs a code").arg(type));
        else if (!names->contains(o.value(QStringLiteral("code")).toString()))
            err(path + QStringLiteral("/code"), QStringLiteral("\"%1\" is not a %2").arg(o.value(QStringLiteral("code")).toString(), type));
    }

    void mappings(const QJsonValue &v, const QString &path)
    {
        if (!array(v, path, 0, 256))
            return;
        const QJsonArray a = v.toArray();
        for (int n = 0; n < a.size(); ++n) {
            const QString p = path + QLatin1Char('/') + QString::number(n);
            if (!object(a.at(n), p,
                        {QStringLiteral("from"), QStringLiteral("to"), QStringLiteral("mode"), QStringLiteral("hold_ms"),
                         QStringLiteral("turbo_hz"), QStringLiteral("threshold")},
                        {QStringLiteral("from"), QStringLiteral("to")}))
                continue;
            const QJsonObject m = a.at(n).toObject();
            if (m.contains(QStringLiteral("from")))
                input(m.value(QStringLiteral("from")), p + QStringLiteral("/from"));
            if (m.contains(QStringLiteral("to")))
                target(m.value(QStringLiteral("to")), p + QStringLiteral("/to"));
            if (m.contains(QStringLiteral("threshold")))
                number(m.value(QStringLiteral("threshold")), p + QStringLiteral("/threshold"), 0, 1);
            if (m.contains(QStringLiteral("turbo_hz")))
                number(m.value(QStringLiteral("turbo_hz")), p + QStringLiteral("/turbo_hz"), 1, 30);
        }
    }

    void stick(const QJsonValue &v, const QString &path)
    {
        if (!object(v, path,
                    {QStringLiteral("inner_deadzone"), QStringLiteral("outer_deadzone"), QStringLiteral("anti_deadzone"),
                     QStringLiteral("sensitivity"), QStringLiteral("curve"), QStringLiteral("invert_x"),
                     QStringLiteral("invert_y"), QStringLiteral("smoothing")},
                    {}))
            return;
        const QJsonObject o = v.toObject();
        const auto num = [&](const char *key, double min, double max) {
            const QString k = QLatin1String(key);
            if (o.contains(k))
                number(o.value(k), path + QLatin1Char('/') + k, min, max);
        };
        num("inner_deadzone", 0, 0.9);
        num("outer_deadzone", 0, 0.5);
        num("anti_deadzone", 0, 0.9);
        num("sensitivity", 0.1, 4);
        num("smoothing", 0, 1);
        if (o.contains(QStringLiteral("curve")))
            oneOf(o.value(QStringLiteral("curve")), path + QStringLiteral("/curve"),
                  {QStringLiteral("linear"), QStringLiteral("precise"), QStringLiteral("aggressive")});
        for (const QString &k : {QStringLiteral("invert_x"), QStringLiteral("invert_y")}) {
            if (o.contains(k))
                boolean(o.value(k), path + QLatin1Char('/') + k);
        }
        if (o.contains(QStringLiteral("inner_deadzone")) && o.contains(QStringLiteral("outer_deadzone"))
            && o.value(QStringLiteral("inner_deadzone")).toDouble() + o.value(QStringLiteral("outer_deadzone")).toDouble() >= 1.0)
            err(path, QStringLiteral("inner_deadzone and outer_deadzone add up to 1 or more"));
    }
};

// What the virtual pad does with one input after the resolved mappings (the service's engine.rs):
// a mapping that v1 does not apply leaves the input as it is.
QString routeOf(const QString &input, const QMap<QString, QJsonObject> &mappings, bool isAxis)
{
    const QString identity = (isAxis ? QStringLiteral("axis:") : QStringLiteral("button:")) + input + QStringLiteral(":1:1:0.5");
    if (!mappings.contains(input))
        return identity;
    const QJsonObject m = mappings.value(input);
    if (m.value(QStringLiteral("mode")).toString(QStringLiteral("press")) != QLatin1String("press"))
        return identity;
    const QJsonObject to = m.value(QStringLiteral("to")).toObject();
    const QString type = to.value(QStringLiteral("type")).toString();
    const QString code = to.value(QStringLiteral("code")).toString();
    const QString shape = QStringLiteral(":%1:%2:%3")
                              .arg(to.value(QStringLiteral("invert")).toBool() ? -1 : 1)
                              .arg(to.value(QStringLiteral("scale")).toDouble(1.0))
                              .arg(m.value(QStringLiteral("threshold")).toDouble(0.5));
    if (type == QLatin1String("none"))
        return QStringLiteral("none") + shape;
    if ((type == QLatin1String("button") && padButtons().contains(code)) || (type == QLatin1String("axis") && axes().contains(code)))
        return type + QLatin1Char(':') + code + shape;
    return identity;
}

struct Resolved
{
    QMap<QString, QJsonObject> mappings; // by input (a raw input by its JSON)
    QList<QJsonObject> order;            // the merged mappings, in order
    QJsonObject left = stickDefaults();
    QJsonObject right = stickDefaults();
    double triggerThreshold = 0;
    QJsonObject other; // gyro_enabled, rumble_enabled, rumble_strength

    QStringList routes() const
    {
        QStringList out;
        for (const QString &b : padButtons())
            out.append(routeOf(b, mappings, false));
        for (const QString &a : axes())
            out.append(routeOf(a, mappings, true));
        return out;
    }

    int buttonsDiffering(const Resolved &other) const
    {
        int n = 0;
        for (const QString &b : padButtons()) {
            if (routeOf(b, mappings, false) != routeOf(b, other.mappings, false))
                ++n;
        }
        return n;
    }
};

QString inputKey(const QJsonValue &from)
{
    return from.isString() ? from.toString() : QString::fromUtf8(QJsonDocument(from.toObject()).toJson(QJsonDocument::Compact));
}

Resolved merge(const QList<QJsonObject> &rootFirst)
{
    Resolved r;
    for (const QJsonObject &p : rootFirst) {
        for (const QJsonValue &m : p.value(QStringLiteral("mappings")).toArray())
            r.mappings.insert(inputKey(m.toObject().value(QStringLiteral("from"))), m.toObject());
        const QJsonObject s = p.value(QStringLiteral("settings")).toObject();
        for (const QString &k : s.value(QStringLiteral("left_stick")).toObject().keys())
            r.left.insert(k, s.value(QStringLiteral("left_stick")).toObject().value(k));
        for (const QString &k : s.value(QStringLiteral("right_stick")).toObject().keys())
            r.right.insert(k, s.value(QStringLiteral("right_stick")).toObject().value(k));
        if (s.contains(QStringLiteral("trigger_threshold")))
            r.triggerThreshold = s.value(QStringLiteral("trigger_threshold")).toDouble();
        for (const QString &k : {QStringLiteral("gyro_enabled"), QStringLiteral("rumble_enabled"), QStringLiteral("rumble_strength")}) {
            if (s.contains(k))
                r.other.insert(k, s.value(k));
        }
    }
    for (const QJsonObject &m : r.mappings)
        r.order.append(m);
    return r;
}

QVariantMap failedReply(const QStringList &out)
{
    QVariantMap reply;
    for (const QString &name : out)
        reply.insert(name, QVariant());
    reply.insert(QStringLiteral("status"), QStringLiteral("failed"));
    return reply;
}
} // namespace

MockInputProfiles::MockInputProfiles(FamilyOf familyOf, AppIdOk appIdOk)
    : m_familyOf(std::move(familyOf))
    , m_appIdOk(std::move(appIdOk))
{
    const auto swap = [](const char *from, const char *to) {
        return QJsonObject{{QStringLiteral("from"), QLatin1String(from)},
                           {QStringLiteral("to"), QJsonObject{{QStringLiteral("type"), QStringLiteral("button")},
                                                              {QStringLiteral("code"), QLatin1String(to)}}}};
    };
    const QJsonObject builtinScope{{QStringLiteral("type"), QStringLiteral("builtin")}};
    m_builtins.insert(DefaultId, QJsonObject{
                                     {QStringLiteral("schema_version"), 1},
                                     {QStringLiteral("id"), DefaultId},
                                     {QStringLiteral("name"), QStringLiteral("Default")},
                                     {QStringLiteral("description"), QStringLiteral("Every button as it is on the controller.")},
                                     {QStringLiteral("scope"), builtinScope},
                                     {QStringLiteral("output"), QJsonObject{{QStringLiteral("type"), QStringLiteral("xbox")}}},
                                     {QStringLiteral("mappings"), QJsonArray()},
                                 });
    QJsonObject nintendo = m_builtins.value(DefaultId);
    nintendo.insert(QStringLiteral("id"), NintendoId);
    nintendo.insert(QStringLiteral("name"), QStringLiteral("Nintendo layout"));
    nintendo.insert(QStringLiteral("description"),
                    QStringLiteral("South and east, west and north swapped, as the labels sit on a Nintendo controller."));
    nintendo.insert(QStringLiteral("inherits"), DefaultId);
    nintendo.insert(QStringLiteral("mappings"), QJsonArray{swap("south", "east"), swap("east", "south"),
                                                            swap("west", "north"), swap("north", "west")});
    m_builtins.insert(NintendoId, nintendo);
}

void MockInputProfiles::reset()
{
    m_shelves.clear();
}

QStringList MockInputProfiles::validate(const QString &text, QJsonObject *out)
{
    const qsizetype bytes = text.toUtf8().size();
    if (bytes > MaxBytes)
        return {QStringLiteral("/: %1 bytes, larger than %2 bytes").arg(bytes).arg(MaxBytes)};
    QJsonParseError error;
    const QJsonDocument doc = QJsonDocument::fromJson(text.toUtf8(), &error);
    if (error.error != QJsonParseError::NoError)
        return {QStringLiteral("/: not JSON")};
    if (!doc.isObject())
        return {QStringLiteral("/: not an object")};
    const QJsonObject o = doc.object();
    Check c;
    c.object(o, QString(),
             {QStringLiteral("schema_version"), QStringLiteral("id"), QStringLiteral("name"), QStringLiteral("description"),
              QStringLiteral("scope"), QStringLiteral("inherits"), QStringLiteral("match"), QStringLiteral("output"),
              QStringLiteral("mappings"), QStringLiteral("layers"), QStringLiteral("chords"), QStringLiteral("macros"),
              QStringLiteral("settings")},
             {QStringLiteral("schema_version"), QStringLiteral("id"), QStringLiteral("name"), QStringLiteral("scope")});
    if (o.contains(QStringLiteral("schema_version")) && o.value(QStringLiteral("schema_version")).toDouble() != 1.0)
        c.err(QStringLiteral("/schema_version"), QStringLiteral("must be 1"));
    if (o.contains(QStringLiteral("id")))
        c.pattern(o.value(QStringLiteral("id")), QStringLiteral("/id"), QStringLiteral("^[a-z0-9][a-z0-9._-]{0,63}$"));
    if (o.contains(QStringLiteral("name")))
        c.text(o.value(QStringLiteral("name")), QStringLiteral("/name"), 1, 64);
    if (o.contains(QStringLiteral("description")))
        c.text(o.value(QStringLiteral("description")), QStringLiteral("/description"), 0, 512);
    if (o.contains(QStringLiteral("scope"))) {
        const QJsonObject s = o.value(QStringLiteral("scope")).toObject();
        const QString type = s.value(QStringLiteral("type")).toString();
        const QString key = type == QLatin1String("platform") ? QStringLiteral("platform_id")
                            : type == QLatin1String("game")   ? QStringLiteral("game_id")
                                                              : QString();
        if (type != QLatin1String("builtin") && type != QLatin1String("global") && key.isEmpty()) {
            c.err(QStringLiteral("/scope"), QStringLiteral("type is not one of builtin, global, platform, game"));
        } else {
            const QStringList known = key.isEmpty() ? QStringList{QStringLiteral("type")} : QStringList{QStringLiteral("type"), key};
            c.object(s, QStringLiteral("/scope"), known, known);
            if (!key.isEmpty() && s.contains(key))
                c.pattern(s.value(key), QStringLiteral("/scope/") + key, QStringLiteral("^[A-Za-z0-9][A-Za-z0-9._-]{0,254}$"));
        }
    }
    if (o.contains(QStringLiteral("inherits"))) {
        c.pattern(o.value(QStringLiteral("inherits")), QStringLiteral("/inherits"), QStringLiteral("^[a-z0-9][a-z0-9._-]{0,63}$"));
        if (o.value(QStringLiteral("inherits")) == o.value(QStringLiteral("id")))
            c.err(QStringLiteral("/inherits"), QStringLiteral("a profile cannot inherit from itself"));
    }
    if (o.contains(QStringLiteral("match")) && c.object(o.value(QStringLiteral("match")), QStringLiteral("/match"),
                                                        {QStringLiteral("family"), QStringLiteral("device")}, {})) {
        const QJsonObject m = o.value(QStringLiteral("match")).toObject();
        if (m.contains(QStringLiteral("family")))
            c.oneOf(m.value(QStringLiteral("family")), QStringLiteral("/match/family"),
                    {QStringLiteral("xbox"), QStringLiteral("playstation"), QStringLiteral("nintendo"), QStringLiteral("generic")});
        if (m.contains(QStringLiteral("device")))
            c.pattern(m.value(QStringLiteral("device")), QStringLiteral("/match/device"), QStringLiteral("^[a-z0-9:-]{1,64}$"));
    }
    if (o.contains(QStringLiteral("output"))
        && c.object(o.value(QStringLiteral("output")), QStringLiteral("/output"), {QStringLiteral("type")}, {QStringLiteral("type")}))
        c.oneOf(o.value(QStringLiteral("output")).toObject().value(QStringLiteral("type")), QStringLiteral("/output/type"),
                {QStringLiteral("xbox"), QStringLiteral("playstation"), QStringLiteral("generic"),
                 QStringLiteral("keyboard_mouse"), QStringLiteral("none")});
    if (o.contains(QStringLiteral("mappings")))
        c.mappings(o.value(QStringLiteral("mappings")), QStringLiteral("/mappings"));
    if (o.contains(QStringLiteral("layers")))
        c.array(o.value(QStringLiteral("layers")), QStringLiteral("/layers"), 0, 8);
    if (o.contains(QStringLiteral("chords")))
        c.array(o.value(QStringLiteral("chords")), QStringLiteral("/chords"), 0, 32);
    if (o.contains(QStringLiteral("macros")))
        c.array(o.value(QStringLiteral("macros")), QStringLiteral("/macros"), 0, 16);
    if (o.contains(QStringLiteral("settings"))
        && c.object(o.value(QStringLiteral("settings")), QStringLiteral("/settings"),
                    {QStringLiteral("gyro_enabled"), QStringLiteral("rumble_enabled"), QStringLiteral("rumble_strength"),
                     QStringLiteral("left_stick"), QStringLiteral("right_stick"), QStringLiteral("trigger_threshold")},
                    {})) {
        const QJsonObject s = o.value(QStringLiteral("settings")).toObject();
        for (const QString &k : {QStringLiteral("left_stick"), QStringLiteral("right_stick")}) {
            if (s.contains(k))
                c.stick(s.value(k), QStringLiteral("/settings/") + k);
        }
        for (const QString &k : {QStringLiteral("rumble_strength"), QStringLiteral("trigger_threshold")}) {
            if (s.contains(k))
                c.number(s.value(k), QStringLiteral("/settings/") + k, 0, 1);
        }
        for (const QString &k : {QStringLiteral("gyro_enabled"), QStringLiteral("rumble_enabled")}) {
            if (s.contains(k))
                c.boolean(s.value(k), QStringLiteral("/settings/") + k);
        }
    }
    if (c.errors.isEmpty() && out)
        *out = o;
    return c.errors;
}

QString MockInputProfiles::slotOf(const QJsonObject &p)
{
    const QJsonObject m = p.value(QStringLiteral("match")).toObject();
    if (m.contains(QStringLiteral("device")))
        return QStringLiteral("device:") + m.value(QStringLiteral("device")).toString();
    if (m.contains(QStringLiteral("family")))
        return QStringLiteral("family:") + m.value(QStringLiteral("family")).toString();
    return QString();
}

bool MockInputProfiles::validSlot(const QString &scopeId)
{
    if (scopeId.isEmpty())
        return true;
    if (scopeId.startsWith(QLatin1String("family:"))) {
        static const QStringList families{QStringLiteral("xbox"), QStringLiteral("playstation"), QStringLiteral("nintendo"),
                                          QStringLiteral("generic")};
        return families.contains(scopeId.mid(7));
    }
    if (scopeId.startsWith(QLatin1String("device:")))
        return matches(QStringLiteral("^[a-z0-9:-]{1,64}$"), scopeId.mid(7));
    return false;
}

const QJsonObject *MockInputProfiles::profile(const QString &console, const QString &id) const
{
    const auto shelf = m_shelves.constFind(console);
    if (shelf != m_shelves.constEnd()) {
        const auto it = shelf->profiles.constFind(id);
        if (it != shelf->profiles.constEnd())
            return &it.value();
    }
    const auto it = m_builtins.constFind(id);
    return it != m_builtins.constEnd() ? &it.value() : nullptr;
}

QList<QJsonObject> MockInputProfiles::chain(const QMap<QString, QJsonObject> &stored, const QString &id, QString *status,
                                            QString *why) const
{
    QList<QJsonObject> out;
    QSet<QString> seen;
    QString cur = id;
    for (;;) {
        const QJsonObject p = stored.contains(cur) ? stored.value(cur) : m_builtins.value(cur);
        if (p.isEmpty()) {
            *status = QStringLiteral("invalid");
            *why = QStringLiteral("no profile \"%1\"").arg(cur);
            return {};
        }
        seen.insert(cur);
        out.append(p);
        if (cur == DefaultId)
            return out;
        const QString next = p.value(QStringLiteral("inherits")).toString(DefaultId);
        if (seen.contains(next)) {
            *status = QStringLiteral("not-allowed");
            *why = QStringLiteral("\"%1\" would inherit from itself through \"%2\"").arg(id, next);
            return {};
        }
        if (out.size() > MaxLevels) {
            *status = QStringLiteral("not-allowed");
            *why = QStringLiteral("\"%1\" would inherit through more than %2 levels").arg(id).arg(MaxLevels);
            return {};
        }
        cur = next;
    }
}

QVariantMap MockInputProfiles::summary(const QString &console, const QJsonObject &p) const
{
    const Shelf shelf = m_shelves.value(console);
    QString status;
    QString why;
    const QString id = p.value(QStringLiteral("id")).toString();
    QList<QJsonObject> own = chain(shelf.profiles, id, &status, &why);
    QStringList ids;
    for (const QJsonObject &c : own)
        ids.append(c.value(QStringLiteral("id")).toString());
    std::reverse(own.begin(), own.end());
    const Resolved resolved = merge(own);
    QList<QJsonObject> parentChain = own;
    if (!parentChain.isEmpty())
        parentChain.removeLast();
    const Resolved parent = merge(parentChain);
    const Resolved base;
    const bool builtin = p.value(QStringLiteral("scope")).toObject().value(QStringLiteral("type")).toString() == QLatin1String("builtin");
    const QJsonObject m = p.value(QStringLiteral("match")).toObject();
    const QJsonObject scope = p.value(QStringLiteral("scope")).toObject();
    const QString scopeType = scope.value(QStringLiteral("type")).toString();
    const QString scopeId = scope.value(scopeType == QLatin1String("platform") ? QStringLiteral("platform_id") : QStringLiteral("game_id")).toString();
    return {
        {QStringLiteral("id"), id},
        {QStringLiteral("name"), p.value(QStringLiteral("name")).toString()},
        {QStringLiteral("scope"), scopeType},
        {QStringLiteral("scope_id"), scopeId},
        {QStringLiteral("inherits"), p.value(QStringLiteral("inherits")).toString()},
        {QStringLiteral("builtin"), builtin},
        {QStringLiteral("assigned"), shelf.global.value(slotOf(p)) == id},
        {QStringLiteral("global_slot"), slotOf(p)},
        {QStringLiteral("match_family"), m.value(QStringLiteral("family")).toString()},
        {QStringLiteral("match_device"), m.value(QStringLiteral("device")).toString()},
        {QStringLiteral("layout"), ids.contains(NintendoId) ? QStringLiteral("nintendo") : QStringLiteral("standard")},
        {QStringLiteral("remapped"), uint(resolved.buttonsDiffering(parent))},
        {QStringLiteral("left_stick_changed"), resolved.left != stickDefaults()},
        {QStringLiteral("right_stick_changed"), resolved.right != stickDefaults()},
        {QStringLiteral("changed"), resolved.routes() != base.routes() || resolved.left != stickDefaults()
                                        || resolved.right != stickDefaults() || resolved.triggerThreshold != 0},
    };
}

QString MockInputProfiles::applying(const QString &console, const QString &family, const QString &device) const
{
    // Its device's slot, else its family's, else all controllers' (a slot's profile counts while
    // its match names that slot and fits the pad), else the default.
    const QMap<QString, QString> global = m_shelves.value(console).global;
    QStringList order;
    if (!device.isEmpty())
        order.append(QStringLiteral("device:") + device);
    if (!family.isEmpty())
        order.append(QStringLiteral("family:") + family);
    order.append(QString());
    for (const QString &slot : order) {
        const QString id = global.value(slot);
        const QJsonObject *p = id.isEmpty() ? nullptr : profile(console, id);
        if (!p || slotOf(*p) != slot)
            continue;
        const QJsonObject m = p->value(QStringLiteral("match")).toObject();
        const bool fits = (!m.contains(QStringLiteral("family")) || m.value(QStringLiteral("family")).toString() == family)
                          && (!m.contains(QStringLiteral("device")) || m.value(QStringLiteral("device")).toString() == device);
        if (fits)
            return id;
    }
    return DefaultId;
}

QVariantMap MockInputProfiles::call(const QString &method, const QVariantMap &args, QString *changed)
{
    changed->clear();
    const QString console = args.value(QStringLiteral("profile")).toString();
    const auto answer = [](const QString &status, QVariantMap more = {}) {
        more.insert(QStringLiteral("status"), status);
        return more;
    };
    if (method == QLatin1String("ValidateProfile")) {
        const QStringList errors = validate(args.value(QStringLiteral("json")).toString(), nullptr);
        return answer(errors.isEmpty() ? QStringLiteral("ok") : QStringLiteral("invalid"), {{QStringLiteral("errors"), errors}});
    }
    // The console profile: the form of ruya-profiles' ids (the service also wants the account).
    static const QRegularExpression consoleId(QStringLiteral("^[A-Za-z0-9_-]{1,32}$"));
    if (!consoleId.match(console).hasMatch()) {
        QVariantMap empty;
        if (method == QLatin1String("ListProfiles"))
            empty.insert(QStringLiteral("profiles"), QVariantList());
        if (method == QLatin1String("GetProfile"))
            empty.insert(QStringLiteral("json"), QString());
        if (method == QLatin1String("SaveProfile")) {
            empty.insert(QStringLiteral("profile_id"), QString());
            empty.insert(QStringLiteral("errors"), QStringList());
        }
        if (method == QLatin1String("GetEffectiveProfile")) {
            empty.insert(QStringLiteral("json"), QString());
            empty.insert(QStringLiteral("chain"), QStringList());
        }
        return answer(QStringLiteral("unknown-profile"), empty);
    }
    Shelf &shelf = m_shelves[console];
    if (method == QLatin1String("ListProfiles")) {
        QVariantList rows;
        for (const QJsonObject &p : m_builtins)
            rows.append(summary(console, p));
        for (const QJsonObject &p : shelf.profiles)
            rows.append(summary(console, p));
        return answer(QStringLiteral("ok"), {{QStringLiteral("profiles"), rows}});
    }
    if (method == QLatin1String("GetProfile")) {
        const QJsonObject *p = profile(console, args.value(QStringLiteral("profile_id")).toString());
        if (!p)
            return answer(QStringLiteral("unknown-profile"), {{QStringLiteral("json"), QString()}});
        return answer(QStringLiteral("ok"), {{QStringLiteral("json"), QString::fromUtf8(QJsonDocument(*p).toJson(QJsonDocument::Indented))}});
    }
    if (method == QLatin1String("SaveProfile")) {
        QJsonObject p;
        const QStringList errors = validate(args.value(QStringLiteral("json")).toString(), &p);
        const auto refuse = [&](const QString &status, const QString &id, const QString &line) {
            return answer(status, {{QStringLiteral("profile_id"), id}, {QStringLiteral("errors"), QStringList{line}}});
        };
        if (!errors.isEmpty())
            return answer(QStringLiteral("invalid"), {{QStringLiteral("profile_id"), QString()}, {QStringLiteral("errors"), errors}});
        const QString id = p.value(QStringLiteral("id")).toString();
        if (m_builtins.contains(id))
            return refuse(QStringLiteral("not-allowed"), id, QStringLiteral("/id: \"%1\" is a built-in profile").arg(id));
        if (p.value(QStringLiteral("scope")).toObject().value(QStringLiteral("type")).toString() == QLatin1String("builtin"))
            return refuse(QStringLiteral("not-allowed"), id, QStringLiteral("/scope: only the console has built-in profiles"));
        if (!shelf.profiles.contains(id) && shelf.profiles.size() >= MaxProfiles)
            return refuse(QStringLiteral("not-allowed"), id, QStringLiteral("/: at most %1 profiles per console profile").arg(MaxProfiles));
        const QString parent = p.value(QStringLiteral("inherits")).toString();
        if (!parent.isEmpty() && !profile(console, parent))
            return refuse(QStringLiteral("invalid"), id, QStringLiteral("/inherits: no profile \"%1\"").arg(parent));
        QMap<QString, QJsonObject> trial = shelf.profiles;
        trial.insert(id, p);
        for (const QString &other : trial.keys()) {
            QString status;
            QString why;
            if (chain(trial, other, &status, &why).isEmpty())
                return refuse(status, id, QStringLiteral("/inherits: ") + why);
        }
        shelf.profiles.insert(id, p);
        // A match that names another slot takes the profile out of its old one.
        for (auto it = shelf.global.begin(); it != shelf.global.end();) {
            if (it.value() == id && it.key() != slotOf(p))
                it = shelf.global.erase(it);
            else
                ++it;
        }
        *changed = console;
        return answer(QStringLiteral("ok"), {{QStringLiteral("profile_id"), id}, {QStringLiteral("errors"), QStringList()}});
    }
    if (method == QLatin1String("DeleteProfile")) {
        const QString id = args.value(QStringLiteral("profile_id")).toString();
        if (m_builtins.contains(id))
            return answer(QStringLiteral("not-allowed"));
        if (!shelf.profiles.contains(id))
            return answer(QStringLiteral("unknown-profile"));
        const QJsonValue grand = shelf.profiles.value(id).value(QStringLiteral("inherits"));
        for (auto it = shelf.profiles.begin(); it != shelf.profiles.end(); ++it) {
            if (it->value(QStringLiteral("inherits")).toString() != id)
                continue;
            if (grand.isUndefined())
                it->remove(QStringLiteral("inherits"));
            else
                it->insert(QStringLiteral("inherits"), grand);
        }
        for (auto it = shelf.global.begin(); it != shelf.global.end();) {
            if (it.value() == id)
                it = shelf.global.erase(it);
            else
                ++it;
        }
        shelf.profiles.remove(id);
        *changed = console;
        return answer(QStringLiteral("ok"));
    }
    if (method == QLatin1String("AssignProfile")) {
        const QString id = args.value(QStringLiteral("profile_id")).toString();
        const QString slot = args.value(QStringLiteral("scope_id")).toString();
        if (args.value(QStringLiteral("scope")).toString() != QLatin1String("global") || !validSlot(slot))
            return answer(QStringLiteral("invalid"));
        if (!id.isEmpty()) {
            const QJsonObject *p = profile(console, id);
            if (!p)
                return answer(QStringLiteral("unknown-profile"));
            const QString type = p->value(QStringLiteral("scope")).toObject().value(QStringLiteral("type")).toString();
            if (type != QLatin1String("builtin") && type != QLatin1String("global"))
                return answer(QStringLiteral("invalid"));
            if (slotOf(*p) != slot)
                return answer(QStringLiteral("invalid"));
            shelf.global.insert(slot, id);
        } else {
            shelf.global.remove(slot);
        }
        *changed = console;
        return answer(QStringLiteral("ok"));
    }
    if (method == QLatin1String("GetEffectiveProfile")) {
        const QVariantMap empty{{QStringLiteral("json"), QString()}, {QStringLiteral("chain"), QStringList()}};
        const QString appId = args.value(QStringLiteral("app_id")).toString();
        if (!appId.isEmpty() && !m_appIdOk(appId))
            return answer(QStringLiteral("invalid"), empty);
        const QString device = args.value(QStringLiteral("device_id")).toString();
        QString family;
        if (!device.isEmpty()) {
            family = m_familyOf(device);
            if (family.isNull())
                return answer(QStringLiteral("unknown-device"), empty);
        }
        const QString id = applying(console, family, device);
        QString status;
        QString why;
        QList<QJsonObject> links = chain(shelf.profiles, id, &status, &why);
        QStringList ids;
        for (const QJsonObject &c : links)
            ids.append(c.value(QStringLiteral("id")).toString());
        QJsonObject flat = links.isEmpty() ? QJsonObject() : links.constFirst();
        std::reverse(links.begin(), links.end());
        const Resolved r = merge(links);
        flat.remove(QStringLiteral("inherits"));
        QJsonArray mappings;
        for (const QJsonObject &m : r.order)
            mappings.append(m);
        flat.insert(QStringLiteral("mappings"), mappings);
        QJsonObject settings = r.other;
        settings.insert(QStringLiteral("left_stick"), r.left);
        settings.insert(QStringLiteral("right_stick"), r.right);
        settings.insert(QStringLiteral("trigger_threshold"), r.triggerThreshold);
        flat.insert(QStringLiteral("settings"), settings);
        return answer(QStringLiteral("ok"), {{QStringLiteral("json"), QString::fromUtf8(QJsonDocument(flat).toJson(QJsonDocument::Indented))},
                                             {QStringLiteral("chain"), ids}});
    }
    return failedReply({});
}
