#ifndef MAINWINDOW_H
#define MAINWINDOW_H

#include <QMainWindow>
#include <QList>
#include <QNetworkCookie>
#include <QStringList>
#include <QWebEnginePage>
#include <QWebEngineUrlRequestInterceptor>

#include "oidc_config.h"

class CredentialBridge;
class QWebChannel;
class QWebEnginePage;
class QPushButton;
class QTimer;

QT_BEGIN_NAMESPACE
namespace Ui { class MainWindow; }
QT_END_NAMESPACE


class RequestInterceptor : public QWebEngineUrlRequestInterceptor
{
    Q_OBJECT

public:
    explicit RequestInterceptor(CredentialBridge *bridge, QObject *parent = nullptr);

    virtual void interceptRequest(QWebEngineUrlRequestInfo &info) override;

    // Central config (/etc/oidc-login/oidc-login.conf; env > file).
    static QMap<QString, QString> s_config;
    static QStringList cfgList(const char *key, const QString &fallbackCsv = QString())
    { return OidcConfig::getList(s_config, key, fallbackCsv); }

private:
    // Every member below is filled from the central config file
    // (oidc-login.conf)
    QString targetPage;
    // Also accepted target pages: after login the OIDC flow lands on
    // /redirect_uri and then possibly on other paths. Without this list
    // the cookie watcher is only installed on an exactly matching call -
    // and then the greeter never catches the cookie.
    QStringList acceptedPages;
    // The RP cookie (mod_auth_openidc_session) triggers the post-login phase.
    // The IdP cookies (sso.hm.edu) are additionally co-stored.
    QString m_targetCookieName;
    QStringList m_idpCookieNames;
    QString helperApplication;
    QStringList helperApplicationParams;
    QString sessionAccountCommand;
    CredentialBridge *m_bridge = nullptr;
    bool m_quiet = false;
    // Auto-login: on success additionally emits the captured credentials
    // (percent-encoded, see emitAutoLogin) on stdout so the greeter
    // can call sddm.login() directly. Initialized false; overwritten at
    // runtime from OIDC_AUTOLOGIN (env > /etc/oidc-login/oidc-login.conf),
    // which the greeter sets via the "--autologin" flag when
    // theme.conf autoLoginAfterHm / config/oidc-login.conf AUTO_LOGIN_AFTER_HM
    // is true.
    bool m_autoLoginAfterHm = false;
    void reactOnSessionCookieFound(const QList<QNetworkCookie> &cookies);

    // Writes "OIDC_AUTOLOGIN: <pct(user)>\t<pct(pass)>" to stdout.
    // Percent-encoding (QUrl::toPercentEncoding) instead of raw values, so that
    // spaces/special chars/line breaks do not
    // destroy the line protocol.
    void emitAutoLogin(const QString &userName, const QString &passWord);

signals:
    // Triggered once the OIDC cookie is found and the
    // post-login phase (network release + account creation) starts. From this
    // point on the user must not cancel the login anymore.
    void postLoginStarted();
};


class CustomWebEnginePage : public QWebEnginePage
{
    Q_OBJECT

public:
    explicit CustomWebEnginePage(QObject* parent = nullptr) : QWebEnginePage(parent) {};

protected:
    QWebEnginePage* createWindow(WebWindowType type) override;
};


class MainWindow : public QMainWindow
{
    Q_OBJECT

public:
    MainWindow(QWidget *parent = nullptr);
    ~MainWindow();
    void loadURL(QUrl url);

protected:
    virtual void showEvent(QShowEvent *event) override;
    virtual void keyPressEvent(QKeyEvent *event) override;
    virtual bool eventFilter(QObject* obj, QEvent* event) override;
    // Closing the window (title bar/WM) behaves like the cancel button.
    virtual void closeEvent(QCloseEvent *event) override;

private slots:
    // Closes the browser without completing the HM login (cancel
    // button in the window / closing the window). Nothing is
    // released and no account is created; the greeter stays unchanged and
    // afterwards accepts normal as well as HM logins again.
    void abortLogin();

private:
    // Start page (OIDC_AUTOLOAD) - filled from the central config.
    QString autoloadPage;
    // Empty = allow all domains (the HM login spans several hosts/
    // external identity providers). Can be narrowed via OIDC_CAPTURE_PATTERNS.
    QStringList captureMatchPatterns = QStringList();
    Ui::MainWindow *ui;
    bool isInitiallyShown;
    CredentialBridge *m_credentialBridge = nullptr;
    QWebChannel *m_webChannel = nullptr;
    // Cancel button in the status bar (in the SDDM greeter there is no
    // window manager and hence no title bar/Alt+F4).
    QPushButton *m_cancelButton = nullptr;
    // After the cookie find the post-login phase runs (release + account); an
    // abort must no longer interrupt it.
    bool m_postLoginRunning = false;
    // Prevents triggering the abort multiple times.
    bool m_abortRequested = false;
    void setupCredentialCapture();
    void installCredentialCapture(QWebEnginePage *page);
    void afterWindowVisible();
    void setupAbortUi();
};
#endif // MAINWINDOW_H
