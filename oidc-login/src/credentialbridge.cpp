#include "credentialbridge.h"

CredentialBridge::CredentialBridge(QObject *parent)
    : QObject(parent)
{
}

QString CredentialBridge::username() const
{
    return m_username;
}

QString CredentialBridge::password() const
{
    return m_password;
}

bool CredentialBridge::isComplete() const
{
    return !m_username.isEmpty() && !m_password.isEmpty();
}

void CredentialBridge::clear()
{
    m_username.clear();
    m_password.clear();
}

void CredentialBridge::storeUsername(const QString &username)
{
    if (username.isEmpty() || username == m_username)
        return;
    m_username = username;
    emit usernameStored();
    emit credentialsStored();
}

void CredentialBridge::storePassword(const QString &password)
{
    if (password.isEmpty() || password == m_password)
        return;
    m_password = password;
    emit passwordStored();
    emit credentialsStored();
}