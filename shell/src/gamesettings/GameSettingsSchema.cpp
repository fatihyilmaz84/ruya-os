#include "GameSettingsSchema.h"

#include <QHash>
#include <QJsonArray>
#include <QJsonDocument>
#include <QJsonObject>
#include <QJsonParseError>
#include <QRegularExpression>
#include <QSet>
#include <QStringDecoder>

#include <cmath>

namespace GameSettingsSchema {

namespace {

const QRegularExpression &idPattern()
{
    static const QRegularExpression re(QStringLiteral("\\A[a-z0-9_.]{1,64}\\z"));
    return re;
}

const QRegularExpression &optionValuePattern()
{
    static const QRegularExpression re(QStringLiteral("\\A[A-Za-z0-9_.-]{1,64}\\z"));
    return re;
}

const QRegularExpression &languageKeyPattern()
{
    static const QRegularExpression re(QStringLiteral("\\A[a-z]{2,3}(-[A-Za-z0-9]{2,8})?\\z"));
    return re;
}

bool isBadCodePoint(uint c)
{
    return c < 0x20 || (c >= 0x7f && c <= 0x9f)           // control characters
        || c == 0x2028 || c == 0x2029                      // line and paragraph separators
        || c == 0x61c || c == 0x200e || c == 0x200f        // Arabic letter mark, left/right-to-right marks
        || (c >= 0x202a && c <= 0x202e)                    // embeddings and overrides
        || (c >= 0x2066 && c <= 0x2069);                   // isolates
}

// What went wrong with a piece of text, or "" when it is fine.
QString textProblem(const QJsonValue &v, int maxLen)
{
    if (!v.isString())
        return QStringLiteral("must be text");
    const QList<uint> points = v.toString().toUcs4();
    if (points.isEmpty())
        return QStringLiteral("is empty");
    if (points.size() > maxLen)
        return QStringLiteral("is longer than %1 characters").arg(maxLen);
    for (uint c : points) {
        if (isBadCodePoint(c))
            return QStringLiteral("contains a control or bidirectional character (U+%1)")
                .arg(QString::number(c, 16).rightJustified(4, QLatin1Char('0')).toUpper());
    }
    return {};
}

// The candidates for a language, best first: "tr_TR.UTF-8" -> tr-tr, tr, en.
QStringList languageCandidates(const QString &language)
{
    QString l = language.toLower();
    l.replace(QLatin1Char('_'), QLatin1Char('-'));
    const int cut = l.indexOf(QRegularExpression(QStringLiteral("[.@]")));
    if (cut >= 0)
        l.truncate(cut);
    QStringList out;
    if (!l.isEmpty())
        out << l;
    const int dash = l.indexOf(QLatin1Char('-'));
    if (dash > 0)
        out << l.left(dash);
    out << QStringLiteral("en");
    return out;
}

// A label, description, option label or info text: a string, or { "en": ..., "tr": ... }. Returns "" or
// what is wrong; `out` is the text in the asked language.
QString readLocalised(const QJsonValue &v, int maxLen, const QStringList &candidates, QString *out)
{
    if (v.isString()) {
        const QString p = textProblem(v, maxLen);
        if (p.isEmpty())
            *out = v.toString();
        return p;
    }
    if (!v.isObject())
        return QStringLiteral("must be text or an object of texts by language");
    const QJsonObject o = v.toObject();
    if (o.size() > MaxLanguages)
        return QStringLiteral("has more than %1 languages").arg(MaxLanguages);
    if (!o.contains(QStringLiteral("en")))
        return QStringLiteral("has no \"en\" text");
    QHash<QString, QString> byLanguage;
    for (auto it = o.begin(); it != o.end(); ++it) {
        if (!languageKeyPattern().match(it.key()).hasMatch())
            return QStringLiteral("has a language key that is not a language code");
        const QString p = textProblem(it.value(), maxLen);
        if (!p.isEmpty())
            return QStringLiteral("(%1) %2").arg(it.key(), p);
        byLanguage.insert(it.key().toLower(), it.value().toString());
    }
    for (const QString &c : candidates) {
        if (byLanguage.contains(c)) {
            *out = byLanguage.value(c);
            return {};
        }
    }
    return QStringLiteral("has no \"en\" text");   // unreachable: "en" is the last candidate
}

bool readInt(const QJsonValue &v, double *out)
{
    if (!v.isDouble())
        return false;
    const double d = v.toDouble();
    if (!std::isfinite(d) || d != std::floor(d) || d < -2147483648.0 || d > 2147483647.0)
        return false;
    *out = d;
    return true;
}

bool readNumber(const QJsonValue &v, double *out)
{
    if (!v.isDouble())
        return false;
    const double d = v.toDouble();
    if (!std::isfinite(d) || std::fabs(d) > 1e9)
        return false;
    *out = d;
    return true;
}

QString numberText(double d)
{
    return QString::number(d, 'g', 12);
}

struct Parsed
{
    QString id;
    QString type;
    QString category;
    QVariantMap row;
    QStringList optionValues;      // enum
    double min = 0;                // int, float
    double max = 0;
    QString whenId;                // visibleWhen
    QJsonValue whenEquals;
};

struct Parser
{
    QStringList candidates;
    QString error;

    bool fail(int index, const QString &id, const QString &message)
    {
        const QString name = idPattern().match(id).hasMatch() ? QStringLiteral("settings[%1] \"%2\"").arg(index).arg(id)
                                                              : QStringLiteral("settings[%1]").arg(index);
        error = name + QLatin1String(": ") + message;
        return false;
    }

    bool localised(const QJsonObject &o, const char *key, int maxLen, bool required, int index,
                   const QString &id, QString *out)
    {
        const QString k = QLatin1String(key);
        if (!o.contains(k)) {
            if (required)
                return fail(index, id, QStringLiteral("\"%1\" is missing").arg(k));
            out->clear();
            return true;
        }
        const QString p = readLocalised(o.value(k), maxLen, candidates, out);
        return p.isEmpty() ? true : fail(index, id, QStringLiteral("\"%1\" %2").arg(k, p));
    }

    bool setting(int index, const QJsonValue &value, Parsed *out)
    {
        if (!value.isObject())
            return fail(index, {}, QStringLiteral("is not an object"));
        const QJsonObject o = value.toObject();

        QString id;
        const QJsonValue idValue = o.value(QStringLiteral("id"));
        if (!idValue.isString() || !idPattern().match(idValue.toString()).hasMatch())
            return fail(index, {}, QStringLiteral("\"id\" must be 1 to 64 characters of a-z, 0-9, _ and ."));
        id = idValue.toString();

        const QJsonValue typeValue = o.value(QStringLiteral("type"));
        if (!typeValue.isString())
            return fail(index, id, QStringLiteral("\"type\" is missing"));
        const QString type = typeValue.toString();
        static const QStringList types = {QStringLiteral("bool"), QStringLiteral("enum"), QStringLiteral("int"),
                                          QStringLiteral("float"), QStringLiteral("action"), QStringLiteral("info")};
        if (!types.contains(type))
            return fail(index, id, QStringLiteral("unknown type \"%1\" (bool, enum, int, float, action or info)")
                                       .arg(type.left(40)));

        QStringList allowed = {QStringLiteral("id"), QStringLiteral("label"), QStringLiteral("description"),
                               QStringLiteral("type"), QStringLiteral("category"), QStringLiteral("visibleWhen"),
                               QStringLiteral("restart")};
        if (type == QLatin1String("bool"))
            allowed << QStringLiteral("default");
        else if (type == QLatin1String("enum"))
            allowed << QStringLiteral("default") << QStringLiteral("options");
        else if (type == QLatin1String("int") || type == QLatin1String("float"))
            allowed << QStringLiteral("default") << QStringLiteral("min") << QStringLiteral("max")
                    << QStringLiteral("step") << QStringLiteral("unit");
        else if (type == QLatin1String("info"))
            allowed << QStringLiteral("default");
        for (auto it = o.begin(); it != o.end(); ++it) {
            if (!allowed.contains(it.key()))
                return fail(index, id, QStringLiteral("a %1 setting has no key \"%2\"").arg(type, it.key().left(40)));
        }

        const QJsonValue categoryValue = o.value(QStringLiteral("category"));
        if (!categoryValue.isString())
            return fail(index, id, QStringLiteral("\"category\" is missing"));
        const QString category = categoryValue.toString();
        if (!categoryOrder().contains(category))
            return fail(index, id, QStringLiteral("unknown category \"%1\" (%2)").arg(category.left(40), categoryOrder().join(QLatin1String(", "))));

        QString label, description;
        if (!localised(o, "label", MaxLabel, true, index, id, &label)
            || !localised(o, "description", MaxDescription, false, index, id, &description))
            return false;

        bool restart = false;
        if (o.contains(QStringLiteral("restart"))) {
            if (!o.value(QStringLiteral("restart")).isBool())
                return fail(index, id, QStringLiteral("\"restart\" must be true or false"));
            restart = o.value(QStringLiteral("restart")).toBool();
        }

        QVariantMap row{
            {QStringLiteral("id"), id},
            {QStringLiteral("type"), type},
            {QStringLiteral("label"), label},
            {QStringLiteral("description"), description},
            {QStringLiteral("category"), category},
            {QStringLiteral("restart"), restart},
            {QStringLiteral("visibleWhen"), QVariantMap()},
        };
        Parsed p;
        p.id = id;
        p.type = type;
        p.category = category;

        if (o.contains(QStringLiteral("visibleWhen"))) {
            const QJsonValue w = o.value(QStringLiteral("visibleWhen"));
            if (!w.isObject())
                return fail(index, id, QStringLiteral("\"visibleWhen\" must be { \"id\": ..., \"equals\": ... }"));
            const QJsonObject wo = w.toObject();
            for (auto it = wo.begin(); it != wo.end(); ++it) {
                if (it.key() != QLatin1String("id") && it.key() != QLatin1String("equals"))
                    return fail(index, id, QStringLiteral("\"visibleWhen\" has no key \"%1\" (one condition, no expressions)")
                                               .arg(it.key().left(40)));
            }
            const QJsonValue wid = wo.value(QStringLiteral("id"));
            const QJsonValue weq = wo.value(QStringLiteral("equals"));
            if (!wid.isString() || !idPattern().match(wid.toString()).hasMatch() || !wo.contains(QStringLiteral("equals")))
                return fail(index, id, QStringLiteral("\"visibleWhen\" needs an \"id\" and an \"equals\""));
            if (!(weq.isBool() || weq.isString() || weq.isDouble()))
                return fail(index, id, QStringLiteral("\"visibleWhen\" \"equals\" must be true/false, text or a number"));
            p.whenId = wid.toString();
            p.whenEquals = weq;
            row[QStringLiteral("visibleWhen")] = QVariantMap{{QStringLiteral("id"), p.whenId},
                                                             {QStringLiteral("equals"), weq.toVariant()}};
        }

        if (type == QLatin1String("bool")) {
            if (!o.value(QStringLiteral("default")).isBool())
                return fail(index, id, QStringLiteral("\"default\" must be true or false"));
            row[QStringLiteral("default")] = o.value(QStringLiteral("default")).toBool();
        } else if (type == QLatin1String("enum")) {
            if (!enumRow(index, id, o, &row, &p))
                return false;
        } else if (type == QLatin1String("int") || type == QLatin1String("float")) {
            if (!numberRow(index, id, o, type == QLatin1String("int"), &row, &p))
                return false;
        } else if (type == QLatin1String("info")) {
            if (o.contains(QStringLiteral("default"))) {
                QString text;
                if (!localised(o, "default", MaxLabel, true, index, id, &text))
                    return false;
                row[QStringLiteral("default")] = text;
            } else {
                row[QStringLiteral("default")] = QString();
            }
        }
        p.row = row;
        *out = p;
        return true;
    }

    bool enumRow(int index, const QString &id, const QJsonObject &o, QVariantMap *row, Parsed *p)
    {
        const QJsonValue optionsValue = o.value(QStringLiteral("options"));
        if (!optionsValue.isArray())
            return fail(index, id, QStringLiteral("an enum needs \"options\""));
        const QJsonArray options = optionsValue.toArray();
        if (options.isEmpty())
            return fail(index, id, QStringLiteral("\"options\" is empty"));
        if (options.size() > MaxOptions)
            return fail(index, id, QStringLiteral("has %1 options; at most %2").arg(options.size()).arg(MaxOptions));
        QVariantList list;
        QSet<QString> seen;
        for (int i = 0; i < options.size(); ++i) {
            if (!options.at(i).isObject())
                return fail(index, id, QStringLiteral("option %1 is not an object").arg(i));
            const QJsonObject oo = options.at(i).toObject();
            for (auto it = oo.begin(); it != oo.end(); ++it) {
                if (it.key() != QLatin1String("value") && it.key() != QLatin1String("label"))
                    return fail(index, id, QStringLiteral("option %1 has no key \"%2\"").arg(i).arg(it.key().left(40)));
            }
            const QJsonValue value = oo.value(QStringLiteral("value"));
            if (!value.isString() || !optionValuePattern().match(value.toString()).hasMatch())
                return fail(index, id, QStringLiteral("option %1: \"value\" must be 1 to 64 characters of letters, digits, _ . and -").arg(i));
            if (seen.contains(value.toString()))
                return fail(index, id, QStringLiteral("option value \"%1\" is listed twice").arg(value.toString()));
            seen.insert(value.toString());
            QString optionLabel;
            if (!oo.contains(QStringLiteral("label")))
                return fail(index, id, QStringLiteral("option %1: \"label\" is missing").arg(i));
            const QString problem = readLocalised(oo.value(QStringLiteral("label")), MaxLabel, candidates, &optionLabel);
            if (!problem.isEmpty())
                return fail(index, id, QStringLiteral("option %1: \"label\" %2").arg(i).arg(problem));
            list.append(QVariantMap{{QStringLiteral("value"), value.toString()}, {QStringLiteral("label"), optionLabel}});
            p->optionValues << value.toString();
        }
        const QJsonValue def = o.value(QStringLiteral("default"));
        if (!def.isString() || !p->optionValues.contains(def.toString()))
            return fail(index, id, QStringLiteral("\"default\" must be the value of one of the options"));
        (*row)[QStringLiteral("options")] = list;
        (*row)[QStringLiteral("default")] = def.toString();
        return true;
    }

    bool numberRow(int index, const QString &id, const QJsonObject &o, bool isInt, QVariantMap *row, Parsed *p)
    {
        auto read = [&](const char *key, double *out) {
            const QJsonValue v = o.value(QLatin1String(key));
            if (isInt ? readInt(v, out) : readNumber(v, out))
                return true;
            fail(index, id, isInt ? QStringLiteral("\"%1\" must be a whole number between -2147483648 and 2147483647").arg(QLatin1String(key))
                                  : QStringLiteral("\"%1\" must be a number between -1000000000 and 1000000000").arg(QLatin1String(key)));
            return false;
        };
        double min = 0, max = 0, def = 0, step = 0;
        if (!read("min", &min) || !read("max", &max) || !read("default", &def))
            return false;
        if (min >= max)
            return fail(index, id, QStringLiteral("\"min\" %1 must be below \"max\" %2").arg(numberText(min), numberText(max)));
        if (def < min || def > max)
            return fail(index, id, QStringLiteral("the default %1 is outside %2..%3").arg(numberText(def), numberText(min), numberText(max)));
        if (o.contains(QStringLiteral("step"))) {
            if (!read("step", &step))
                return false;
            if (step <= 0 || step > max - min)
                return fail(index, id, QStringLiteral("\"step\" %1 must be above 0 and at most max - min").arg(numberText(step)));
        } else {
            step = isInt ? 1.0 : (max - min) / 100.0;
        }
        QString unit;
        if (o.contains(QStringLiteral("unit"))) {
            const QString problem = textProblem(o.value(QStringLiteral("unit")), MaxUnit);
            if (!problem.isEmpty())
                return fail(index, id, QStringLiteral("\"unit\" %1").arg(problem));
            unit = o.value(QStringLiteral("unit")).toString();
        }
        p->min = min;
        p->max = max;
        if (isInt) {
            (*row)[QStringLiteral("default")] = static_cast<qlonglong>(def);
            (*row)[QStringLiteral("min")] = static_cast<qlonglong>(min);
            (*row)[QStringLiteral("max")] = static_cast<qlonglong>(max);
            (*row)[QStringLiteral("step")] = static_cast<qlonglong>(step);
        } else {
            (*row)[QStringLiteral("default")] = def;
            (*row)[QStringLiteral("min")] = min;
            (*row)[QStringLiteral("max")] = max;
            (*row)[QStringLiteral("step")] = step;
        }
        (*row)[QStringLiteral("unit")] = unit;
        return true;
    }
};

// visibleWhen: the target is another setting that has a value, the compared value fits it, and
// following the conditions never comes back (A needs B needs A). Returns "" or the problem.
QString checkConditions(const QList<Parsed> &all)
{
    QHash<QString, int> byId;
    for (int i = 0; i < all.size(); ++i)
        byId.insert(all.at(i).id, i);
    for (int i = 0; i < all.size(); ++i) {
        const Parsed &p = all.at(i);
        if (p.whenId.isEmpty())
            continue;
        const QString name = QStringLiteral("settings[%1] \"%2\"").arg(i).arg(p.id);
        if (p.whenId == p.id)
            return name + QStringLiteral(": \"visibleWhen\" points at the setting itself");
        if (!byId.contains(p.whenId))
            return name + QStringLiteral(": \"visibleWhen\" points at \"%1\", which is not in the file").arg(p.whenId);
        const Parsed &target = all.at(byId.value(p.whenId));
        const QString t = target.type;
        if (t == QLatin1String("action") || t == QLatin1String("info"))
            return name + QStringLiteral(": \"visibleWhen\" points at \"%1\", which is %2 and has no value to compare")
                              .arg(p.whenId, t == QLatin1String("action") ? QStringLiteral("an action") : QStringLiteral("an info row"));
        const QJsonValue eq = p.whenEquals;
        const bool fits = (t == QLatin1String("bool") && eq.isBool())
            || (t == QLatin1String("enum") && eq.isString() && target.optionValues.contains(eq.toString()))
            || ((t == QLatin1String("int") || t == QLatin1String("float")) && eq.isDouble());
        if (!fits)
            return name + QStringLiteral(": \"visibleWhen\" \"equals\" does not fit the %1 setting \"%2\"").arg(t, p.whenId);
        // Every setting has at most one condition, so the chain from here is a line; it comes back to
        // the start (or loops further down) only when it is longer than the file.
        QStringList chain{p.id};
        QString at = p.whenId;
        for (int step = 0; step <= all.size(); ++step) {
            if (chain.contains(at)) {
                chain << at;
                return name + QStringLiteral(": \"visibleWhen\" forms a cycle (%1)").arg(chain.join(QLatin1String(" -> ")));
            }
            chain << at;
            const Parsed &next = all.at(byId.value(at));
            if (next.whenId.isEmpty() || !byId.contains(next.whenId))
                break;
            at = next.whenId;
        }
    }
    return {};
}

} // namespace

const QStringList &categoryOrder()
{
    static const QStringList order = {
        QStringLiteral("graphics"), QStringLiteral("display"), QStringLiteral("controls"), QStringLiteral("audio"),
        QStringLiteral("gameplay"), QStringLiteral("interface"), QStringLiteral("accessibility"),
        QStringLiteral("advanced"),
    };
    return order;
}

bool isPlainText(const QString &text)
{
    return textProblem(QJsonValue(text), 1 << 20).isEmpty();
}

Result parse(const QByteArray &bytes, const QString &language)
{
    Result r;
    auto refuse = [&r](const QString &why) {
        r.ok = false;
        r.error = why;
        r.categories.clear();
        r.count = 0;
        return r;
    };

    if (bytes.size() > MaxFileBytes)
        return refuse(QStringLiteral("the file is %1 bytes; at most %2 (64 KiB)").arg(bytes.size()).arg(MaxFileBytes));
    QStringDecoder decoder(QStringDecoder::Utf8, QStringDecoder::Flag::Stateless);
    const QString decoded = decoder.decode(bytes);
    Q_UNUSED(decoded)
    if (decoder.hasError())
        return refuse(QStringLiteral("the file is not valid UTF-8"));

    QJsonParseError parseError;
    const QJsonDocument doc = QJsonDocument::fromJson(bytes, &parseError);
    if (parseError.error != QJsonParseError::NoError)
        return refuse(QStringLiteral("not valid JSON: %1 (at byte %2)").arg(parseError.errorString()).arg(parseError.offset));
    if (!doc.isObject())
        return refuse(QStringLiteral("the file must be a JSON object"));
    const QJsonObject root = doc.object();
    for (auto it = root.begin(); it != root.end(); ++it) {
        if (it.key() != QLatin1String("version") && it.key() != QLatin1String("settings"))
            return refuse(QStringLiteral("unknown top-level key \"%1\"").arg(it.key().left(40)));
    }
    const QJsonValue version = root.value(QStringLiteral("version"));
    if (!version.isDouble())
        return refuse(QStringLiteral("\"version\" is missing"));
    if (version.toDouble() != 1.0)
        return refuse(QStringLiteral("unsupported \"version\" %1; this console reads version 1").arg(numberText(version.toDouble())));
    if (!root.value(QStringLiteral("settings")).isArray())
        return refuse(QStringLiteral("\"settings\" is missing or not a list"));
    const QJsonArray settings = root.value(QStringLiteral("settings")).toArray();
    if (settings.isEmpty())
        return refuse(QStringLiteral("\"settings\" is empty"));
    if (settings.size() > MaxSettings)
        return refuse(QStringLiteral("the file has %1 settings; at most %2").arg(settings.size()).arg(MaxSettings));

    Parser parser;
    parser.candidates = languageCandidates(language);
    QList<Parsed> all;
    QSet<QString> ids;
    for (int i = 0; i < settings.size(); ++i) {
        Parsed p;
        if (!parser.setting(i, settings.at(i), &p))
            return refuse(parser.error);
        if (ids.contains(p.id))
            return refuse(QStringLiteral("settings[%1] \"%2\": the id is used twice").arg(i).arg(p.id));
        ids.insert(p.id);
        all.append(p);
    }
    const QString problem = checkConditions(all);
    if (!problem.isEmpty())
        return refuse(problem);

    for (const QString &category : categoryOrder()) {
        QVariantList rows;
        for (const Parsed &p : all) {
            if (p.category == category)
                rows.append(p.row);
        }
        if (!rows.isEmpty())
            r.categories.append(QVariantMap{{QStringLiteral("id"), category}, {QStringLiteral("rows"), rows}});
    }
    r.count = all.size();
    r.ok = true;
    return r;
}

} // namespace GameSettingsSchema
