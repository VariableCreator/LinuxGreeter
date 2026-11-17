#ifndef CREDENTIALBRIDGE_H
#define CREDENTIALBRIDGE_H

#include <QObject>
#include <QString>


/****************************************************************************
** CredentialBridge
**
** Receives username + password from the EXPLICITLY named fields of the HM
** login form (name="j_username"/"j_password", id="username"/"password",
** autocomplete="username webauthn"/"password webauthn"). No heuristic
** guessing happens anywhere. The object is exposed as "oidcBridge" via a
** QWebChannel to the isolated browser world
** (QWebEngineScript::ApplicationWorld). The login page itself
** has no access to the channel and cannot see/manipulate the capture.
****************************************************************************/

class CredentialBridge : public QObject
{
    Q_OBJECT

public:
    explicit CredentialBridge(QObject *parent = nullptr);

    QString username() const;
    QString password() const;

    // Complete = username and password are both present.
    bool isComplete() const;

    // Discards the stored credentials (after login).
    void clear();

public slots:
    // Incremental capture. IMPORTANT: these values survive across all
    // navigations/page changes (the bridge lives for the whole
    // session), so user and password can be combined even
    // when entered on different pages/origins (e.g. HM login
    // redirecting to an external identity provider).
    void storeUsername(const QString &username);
    void storePassword(const QString &password);

signals:
    void credentialsStored();
    void usernameStored();
    void passwordStored();

private:
    QString m_username;
    QString m_password;
};

#endif // CREDENTIALBRIDGE_H