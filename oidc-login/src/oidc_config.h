#ifndef OIDC_CONFIG_H
#define OIDC_CONFIG_H

#include <QByteArray>
#include <QFile>
#include <QMap>
#include <QString>
#include <QStringList>

/****************************************************************************
** OidcConfig
**
** Minimal reader for the central flat KEY=VALUE config file
** (/etc/oidc-login/oidc-login.conf, override via $OIDC_CONFIG).
** Same rules as config/oidc-config.sh + config/oidc_config.py:
**   '#' comment, quotes stripped, env var already set ALWAYS wins.
****************************************************************************/

class OidcConfig
{
public:
    static QString configPath()
    {
        const QByteArray env = qgetenv("OIDC_CONFIG");
        if (!env.isEmpty() && QFile::exists(QString::fromUtf8(env)))
            return QString::fromUtf8(env);
        if (QFile::exists(QStringLiteral("/etc/oidc-login/oidc-login.conf")))
            return QStringLiteral("/etc/oidc-login/oidc-login.conf");
        return QString();
    }

    static QMap<QString, QString> readFile(const QString &path)
    {
        QMap<QString, QString> out;
        if (path.isEmpty())
            return out;
        QFile f(path);
        if (!f.open(QIODevice::ReadOnly | QIODevice::Text))
            return out;
        while (!f.atEnd()) {
            QString line = QString::fromUtf8(f.readLine()).trimmed();
            if (line.isEmpty() || line.startsWith(QLatin1Char('#')))
                continue;
            const int eq = line.indexOf(QLatin1Char('='));
            if (eq < 0)
                continue;
            QString key = line.left(eq).trimmed();
            QString val = line.mid(eq + 1).trimmed();
            if (val.length() >= 2
                    && ((val.startsWith(QLatin1Char('"')) && val.endsWith(QLatin1Char('"')))
                        || (val.startsWith(QLatin1Char('\'')) && val.endsWith(QLatin1Char('\'')))))
                val = val.mid(1, val.length() - 2);
            if (key.isEmpty())
                continue;
            bool ok = true;
            for (QChar c : key) {
                if (!(c.isLetterOrNumber() || c == QLatin1Char('_'))) { ok = false; break; }
            }
            if (!ok)
                continue;
            out.insert(key, val);
        }
        return out;
    }

    // Value with precedence: env (if non-empty) > config file > fallback.
    static QString get(const QMap<QString, QString> &cfg, const char *key,
                       const QString &fallback = QString())
    {
        const QByteArray env = qgetenv(key);
        if (!env.isEmpty())
            return QString::fromUtf8(env);
        const QString k = QString::fromLatin1(key);
        if (cfg.contains(k))
            return cfg.value(k);
        return fallback;
    }

    static QStringList getList(const QMap<QString, QString> &cfg, const char *key,
                               const QString &fallbackCsv = QString())
    {
        const QString raw = get(cfg, key, fallbackCsv);
        QStringList out;
        for (const QString &p : raw.split(QLatin1Char(','))) {
            const QString t = p.trimmed();
            if (!t.isEmpty())
                out << t;
        }
        return out;
    }

    static QMap<QString, QString> load()
    {
        return readFile(configPath());
    }
};

#endif // OIDC_CONFIG_H
