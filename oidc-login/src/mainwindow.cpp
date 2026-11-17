#include "mainwindow.h"
#include "credentialbridge.h"
#include "oidc_config.h"
#include "./ui_mainwindow.h"
#include <QMainWindow>

#include <QCloseEvent>
#include <QApplication>
#include <QCoreApplication>
#include <QFile>
#include <QMessageBox>
#include <QNetworkCookie>
#include <QProcess>
#include <QPushButton>
#include <QTextStream>
#include <QTimer>
#include <QUrl>
#include <QVariant>
#include <QWebChannel>
#include <QWebEngineCookieStore>
#include <QWebEngineHistory>
#include <QWebEngineProfile>
#include <QWebEngineScript>
#include <QWebEngineScriptCollection>

#include <cstdio>


// Opens new browser windows (popups / target="_blank") as a separate QDialog
// with its own QWebEngineView and returns that view's page, so the main window
// itself is not replaced.
QWebEnginePage* CustomWebEnginePage::createWindow(WebWindowType type) {
    // Create a dialog to contain the new QWebEngineView
    QDialog* dialog = new QDialog();
    dialog->setAttribute(Qt::WA_DeleteOnClose);
    dialog->setWindowFlags(dialog->windowFlags() | Qt::WindowMaximizeButtonHint | Qt::WindowMinMaxButtonsHint);

    QVBoxLayout* layout = new QVBoxLayout(dialog);
    QWebEngineView* newView = new QWebEngineView(dialog);
    layout->addWidget(newView);

    dialog->setLayout(layout);
    dialog->resize(1024, 720);
    dialog->show();

    return newView->page();
}


// Reads a Qt resource file (e.g. ":/capture/...") into a QString.
// Returns an empty string if the resource cannot be opened.
static QString readResource(const QString &path)
{
    QFile file(path);
    if (!file.open(QIODevice::ReadOnly)) {
        return QString();
    }
    return QString::fromUtf8(file.readAll());
}


// Central config (/etc/oidc-login/oidc-login.conf; env > file).
// Loaded once per process – see loadCentralConfig() calls below.
QMap<QString, QString> RequestInterceptor::s_config;

static void loadCentralConfig()
{
    if (!RequestInterceptor::s_config.isEmpty())
        return;
    RequestInterceptor::s_config = OidcConfig::load();
}
RequestInterceptor::RequestInterceptor(CredentialBridge *bridge, QObject *parent)
    : QWebEngineUrlRequestInterceptor(parent)
    , m_bridge(bridge)
{
    loadCentralConfig();
    const QMap<QString, QString> &cfg = s_config;
    // Browser start page + accepted target pages (OIDC_AUTOLOAD/_PAGES).
    targetPage = OidcConfig::get(cfg, "OIDC_AUTOLOAD");
    const QStringList pages = OidcConfig::getList(cfg, "OIDC_ACCEPTED_PAGES");
    if (!pages.isEmpty())
        acceptedPages = pages;
    // Cookie trigger.
    m_targetCookieName = OidcConfig::get(cfg, "OIDC_RP_COOKIE");
    const QStringList idp = OidcConfig::getList(cfg, "OIDC_IDP_COOKIES");
    if (!idp.isEmpty())
        m_idpCookieNames = idp;

    // Network grant helper: program + args from central config.
    helperApplication = OidcConfig::get(cfg, "OIDC_HELPER");
    const QString args = OidcConfig::get(cfg, "OIDC_HELPER_ARGS");
    if (!args.isEmpty())
        helperApplicationParams = QProcess::splitCommand(args);

    sessionAccountCommand = OidcConfig::get(cfg, "OIDC_SESSION_ACCOUNT");

    // Auto-login for the greeter (see main.cpp: --autologin command line).
    const QString autoLoginEnv = OidcConfig::get(cfg, "OIDC_AUTOLOGIN");
    m_autoLoginAfterHm = !autoLoginEnv.isEmpty()
            && autoLoginEnv.toLower() != "false";

    // In auto-login mode all modal dialogs are suppressed.
    if (m_autoLoginAfterHm)
        m_quiet = true;
}


// Hands the credentials to the greeter for automatic login.
// Format:  OIDC_AUTOLOGIN: <pct(user)>\t<pct(pass)>
// Both values are percent-encoded UTF-8 (QUrl::toPercentEncoding), so that
// tabs/line breaks/special chars do not break the stdout line protocol.
void RequestInterceptor::emitAutoLogin(const QString &userName, const QString &passWord)
{
    if (!m_autoLoginAfterHm || userName.isEmpty() || passWord.isEmpty())
        return;

    const QString encodedUser = QString::fromUtf8(QUrl::toPercentEncoding(userName));
    const QString encodedPass = QString::fromUtf8(QUrl::toPercentEncoding(passWord));

    QTextStream(stdout) << "OIDC_AUTOLOGIN: " << encodedUser << '\t' << encodedPass << '\n';
    QTextStream(stdout).flush();
}


// Called by QtWebEngine for every outgoing request. Once the target login
// page is requested it installs the cookieAdded watcher for the OIDC
// session cookie.
void RequestInterceptor::interceptRequest(QWebEngineUrlRequestInfo &info) {
    // React on specific web page being requested. Compared without
    // query string, so that "…/redirect_uri?code=…" also counts as the target page -
    // that is exactly where mod_auth_openidc sets its session after login.
    static bool watcherInstalled = false;
    const QString requestedPage = info.requestUrl().adjusted(
            QUrl::RemoveQuery | QUrl::RemoveFragment).toString();
    bool isTargetPage = false;
    if (requestedPage == this->targetPage)
        isTargetPage = true;
    for (const QString &page : this->acceptedPages) {
        if (requestedPage == page)
            isTargetPage = true;
    }
    if (isTargetPage && !watcherInstalled) {
        watcherInstalled = true;
        // Access the cookie store
        QWebEngineProfile *profile = QWebEngineProfile::defaultProfile();
        if (profile) {
            QWebEngineCookieStore *cookieStore = profile->cookieStore();
            if (cookieStore) {
                // RP cookie triggers the post-login phase; all known
                // SSO cookies (RP + IdP) are buffered so that afterwards they can be passed
                // to the account script COLLECTED
                // (a single cookie ALONE does not stop the credential prompt).
                auto capturedCookies = std::make_shared<QList<QNetworkCookie>>();
                connect(cookieStore, &QWebEngineCookieStore::cookieAdded, [this, capturedCookies](const QNetworkCookie &cookie){
                    const QString name = QString::fromUtf8(cookie.name());
                    // Remember IdP cookies (replace - the latest state wins).
                    if (this->m_idpCookieNames.contains(name)) {
                        for (int i = 0; i < capturedCookies->size(); ++i) {
                            if (capturedCookies->at(i).name() == cookie.name()
                                    && capturedCookies->at(i).domain() == cookie.domain()) {
                                capturedCookies->removeAt(i);
                                break;
                            }
                        }
                        capturedCookies->append(cookie);
                    }
                    if (cookie.name() == this->m_targetCookieName.toUtf8()) {
                        // Pass on the FULL cookie object (not just the
                        // value): host/path/expiry/flags are needed for the
                        // Firefox SSO export (sso-cookie/).
                        QList<QNetworkCookie> all = *capturedCookies;
                        all.append(cookie);
                        QTimer::singleShot(0, this, [this, all]() {
                            this->reactOnSessionCookieFound(all);
                        });
                    }
                });
                // Request to get all cookies for the target URL
                cookieStore->loadAllCookies();
            }
        }
    }
}

// Post-login handler: runs the network grant (check-and-grant.py) and then
// creates the temporary admin account from the captured credentials. Forwards
// the account name to stdout for the greeter and finally quits the application.
// Receives all collected SSO cookies (RP + IdP): the RP cookie
// (mod_auth_openidc_session) triggers, the IdP cookies (sso.hm.edu) are
// co-stored - without them every new IdP request asks for credentials.
void RequestInterceptor::reactOnSessionCookieFound(const QList<QNetworkCookie> &cookies)
{
    if (cookies.isEmpty())
        return;
    // The RP cookie is the trigger (and goes to check-and-grant.py).
    QNetworkCookie rpCookie;
    for (const QNetworkCookie &c : cookies) {
        if (c.name() == this->m_targetCookieName.toUtf8()) {
            rpCookie = c;
            break;
        }
    }
    if (rpCookie.name().isEmpty())
        rpCookie = cookies.last();
    const QString cookieValue = QString::fromUtf8(rpCookie.value());
    // Prevent multiple cookie events from starting the flow in parallel.
    static bool alreadyReacted = false;
    if (alreadyReacted) return;
    alreadyReacted = true;

    // No more aborting from here on: the network release and the
    // account creation are already running. MainWindow then disables the
    // cancel button (the interceptor does not know the UI).
    emit postLoginStarted();

    bool error = false;

    // In auto-login all dialogs are dropped (the greeter waits for the
    // process); no stdout error output is produced either.
    const auto showCritical = [this](const QString &title, const QString &text) {
        if (!m_quiet)
            QMessageBox::critical(nullptr, title, text);
    };
    const auto showWarning = [this](const QString &title, const QString &text) {
        if (!m_quiet)
            QMessageBox::warning(nullptr, title, text);
    };
    const auto showInfo = [this](const QString &title, const QString &text) {
        if (!m_quiet)
            QMessageBox::information(nullptr, title, text);
    };

    // 1) Network release via check-and-grant (existing behaviour, optional).
    //    OIDC_HELPER empty/disabled -> skip. errorReason collects the reason
    //    for stdout (see below): in auto-login stdout is the only
    //    channel because dialogs are suppressed.
    QString errorReason;
    QString helperScript = this->helperApplicationParams.value(0, QString());
    const QString helperDisabled = OidcConfig::get(s_config, "OIDC_HELPER", QStringLiteral("x")).trimmed().toLower();
    const bool helperOn = !(helperDisabled.isEmpty() || helperDisabled == QStringLiteral("0")
                            || helperDisabled == QStringLiteral("false") || helperDisabled == QStringLiteral("no")
                            || helperDisabled == QStringLiteral("disabled") || helperDisabled == QStringLiteral("none")
                            || helperDisabled == QStringLiteral("-"));
    if (helperOn && QFile::exists(helperScript)) {
        QProcess process;
        process.start(this->helperApplication, this->helperApplicationParams << cookieValue);
        // Wait for the process to start
        if (!process.waitForStarted()) {
            errorReason = tr("Failed to start process: %1").arg(process.errorString());
            showCritical(tr("Failure"), tr("Failed to start process:\n") + process.errorString());
            error = true;
        }
        // Wait for the process to finish
        if (!error && !process.waitForFinished()) {
            errorReason = tr("Process did not finish correctly: %1").arg(process.errorString());
            showCritical(tr("Failure"), tr("Process did not finish correctly:\n") + process.errorString());
            error = true;
        }
        // Check for errors
        if (!error && (process.exitStatus() != QProcess::NormalExit)) {
            errorReason = tr("Process crashed");
            showCritical(tr("Failure"), tr("Process crashed:\n"));
            error = true;
        }
        // Output the process output
        QByteArray output = process.readAllStandardOutput();
        QByteArray errorOutput = process.readAllStandardError();
        // Check the exit code
        if (process.exitCode() != 0) {
            if (errorReason.isEmpty())
                errorReason = tr("Network release failed with exit code %1").arg(process.exitCode());
            showCritical(tr("Failure"), tr("Process finished with exit code:\n") + QString("%1").arg(process.exitCode()));
            error = true;
        }
    // Network release skipped: %1 missing
    } else {
    }

    // In auto-login/kiosk mode no stdout error output is produced; the failure is silent.
    Q_UNUSED(error);

    // 2) Create temporary session admin account (sudo oidc-session-account create).
    //    Credentials come from the HM login (CredentialBridge).
    bool accountCreated = false;
    if (!error) {
        const QString userName = m_bridge ? m_bridge->username() : QString(); // not null check of bridge object: if null use empty string QString()
        // if not null execute m_bridge->username() which gives the username
        const QString passWord = m_bridge ? m_bridge->password() : QString();

        if (userName.isEmpty() || passWord.isEmpty()) {
            // Insufficient credentials captured; auto-login is skipped silently.
        } else {
            // SSO cookies for the Firefox export (sso-cookie/): all collected
            // cookies (RP + IdP) as a MULTI-LINE stdin protocol:
            //   line 1: base64(user)<TAB>base64(pass)
            //   line 2: number of cookies (decimal, e.g. "4")
            //   then ONE line per cookie:
            //     base64(name)<TAB>base64(value)<TAB>host<TAB>path<TAB>expiry<TAB>secure<TAB>httponly
            // Host/path/expiry/flags travel as plain text (metadata, never secret);
            // only name and value are base64 (they may contain special chars).
            // The cookie VALUE never appears as argv (ps-visible).
            // Fallback: empty domain -> host of the target page. A COOKIE WITHOUT
            // a domain is useless (Firefox would never send it); the local
            // machine name (hostname -f) would be wrong here (not an HM domain).
            auto cookieLine = [this](const QNetworkCookie &c) -> QString {
                QString host = c.domain();
                if (host.isEmpty())
                    host = QUrl(targetPage).host();
                if (!host.isEmpty() && !host.startsWith(QLatin1Char('.')))
                    host.prepend(QLatin1Char('.'));
                QString path = c.path();
                if (path.isEmpty())
                    path = QStringLiteral("/");
                QString expiry = QStringLiteral("0");
                if (!c.isSessionCookie() && c.expirationDate().isValid())
                    expiry = QString::number(c.expirationDate().toSecsSinceEpoch());
                return QString::fromUtf8(c.name().toBase64())
                        + QLatin1Char('\t')
                        + QString::fromUtf8(c.value().toBase64())
                        + QLatin1Char('\t') + host
                        + QLatin1Char('\t') + path
                        + QLatin1Char('\t') + expiry
                        + QLatin1Char('\t') + (c.isSecure() ? QStringLiteral("1") : QStringLiteral("0"))
                        + QLatin1Char('\t') + (c.isHttpOnly() ? QStringLiteral("1") : QStringLiteral("0"));
            };
            QProcess account;
            QStringList accountArgs;
            accountArgs << QStringLiteral("-n") << sessionAccountCommand
                        << QStringLiteral("create");
            account.start(QStringLiteral("sudo"), accountArgs);
            if (account.waitForStarted()) {
                QString payloadStr = QString::fromUtf8(userName.toUtf8().toBase64())
                        + QLatin1Char('\t') + QString::fromUtf8(passWord.toUtf8().toBase64()) + QLatin1Char('\n')
                        + QString::number(cookies.size()) + QLatin1Char('\n');
                for (const QNetworkCookie &c : cookies)
                    payloadStr += cookieLine(c) + QLatin1Char('\n');
                const QByteArray payload = payloadStr.toUtf8();
                account.write(payload); //stdin
                account.closeWriteChannel();

                if (account.waitForFinished(60000)) {
                    const QByteArray out = account.readAllStandardOutput();
                    const QByteArray err = account.readAllStandardError();
                    if (account.exitCode() == 0) {
                        accountCreated = true;
                        // Forward "OIDC_ACCOUNT: <name>" to stdout for the greeter
                        const QString accountName = QString::fromUtf8(out).trimmed()
                                                        .section(QLatin1Char(':'), 1).trimmed();
                        QTextStream(stdout) << QString::fromUtf8(out).trimmed() << '\n';
                        QTextStream(stdout).flush();
                        // Optional: also submit credentials for auto-login
                        // (the greeter logs in directly with them, no second input).
                        // IMPORTANT: use the sanitized account name from "OIDC_ACCOUNT: <name>",
                        // not the raw bridge name - sanitize_user()
                        // in the script may change it (lowercase, @-part removed, digits removed).
                        emitAutoLogin(accountName.isEmpty() ? userName : accountName, passWord);
                    } else {
                        showWarning(tr("HM Account"),
                                    tr("The temporary account could not be created:\n%1")
                                        .arg(QString::fromUtf8(err).trimmed()));
                    }
                } else {
                    // Helper timed out; no stdout report in auto-login mode.
                }
            } else {
                showCritical(tr("Failure"), tr("Failed to start the session account helper:\n") + account.errorString());
            }
        }
    }

    // Discard the credentials held in memory
    if (m_bridge)
        m_bridge->clear();

    // Inform on success. In auto-login no modal dialog is shown
    if (!error) {
        if (m_autoLoginAfterHm) {
            // Auto-login: no dialog, the greeter logs in directly.
        } else if (accountCreated) {
            showInfo(tr("Successfully Logged-In"),
                     tr("You now have access to the Internet and privileges to execute commands with root privileges (by using sudo).\n\nAt the login screen, please log in with your HM credentials to use the temporary local account with administrator rights."));
        } else {
            showInfo(tr("Successfully Logged-In"),
                     tr("You now have access to the Internet and privileges to execute commands with root privileges (by using sudo)."));
        }
    }
    QCoreApplication::quit();
}


// Main window setup: builds the UI, creates the CredentialBridge, installs the
// URL request interceptor and sets the custom web page.
MainWindow::MainWindow(QWidget *parent)
    : QMainWindow(parent)
    , ui(new Ui::MainWindow)
{
    ui->setupUi(this);
    isInitiallyShown = true;
    loadCentralConfig();

    // Remove blank space around webbrowser widget
    //ui->gridLayout->setSpacing(0); // Sets the spacing between widgets
    ui->gridLayout->setContentsMargins(0, 0, 0, 0);

    // Cancel button (the SDDM session has no window manager, so there
    // is neither a title-bar close button nor Alt+F4)
    setupAbortUi();

    // WebChannel + CredentialBridge for capturing the HM credentials
    setupCredentialCapture();

    // Intercept and modify web requests
    QWebEngineProfile *profile = QWebEngineProfile::defaultProfile();
    RequestInterceptor *interceptor = new RequestInterceptor(m_credentialBridge);
    profile->setUrlRequestInterceptor(interceptor);

    // From the cookie find on (post-login phase: network release, account creation)
    // aborting is no longer sensible/possible.
    connect(interceptor, &RequestInterceptor::postLoginStarted, this, [this]() {
        m_postLoginRunning = true;
        if (m_cancelButton) {
            m_cancelButton->setEnabled(false);
            m_cancelButton->setText(tr("Anmeldung läuft …"));
        }
    });

    // Set custom web engine page
    CustomWebEnginePage* customPage = new CustomWebEnginePage(this);
    ui->webEngineView->setPage(customPage);

    // Install the WebChannel transport + capture script in the isolated world
    // (ApplicationWorld). The injected script runs in the same world; the login
    // page itself can neither see nor manipulate the channel.
    installCredentialCapture(customPage);

    // Install event filter
    ui->webEngineView->installEventFilter(this);

    //ui->webEngineView->load(QUrl("https://moodle.hm.edu/"));
}

// Destructor: releases the allocated UI object.
MainWindow::~MainWindow()
{
    delete ui;
}

// Called when the window is shown: triggers the initial page load exactly once
// (guarded by isInitiallyShown).
void MainWindow::showEvent(QShowEvent *event)
{
    QMainWindow::showEvent(event);
    if (isInitiallyShown) {
        isInitiallyShown = false;
        // Replaced 2025-04-13 by direct call due to sporadic issues (application hangs) in test kiosk system
        //QTimer::singleShot(0, this, &MainWindow::afterWindowVisible);
        this->afterWindowVisible();
    }
}

// Keyboard shortcuts while the window itself has the focus: F5 reloads and
// Ctrl+Plus / Ctrl+Equal / Ctrl+Minus zoom the page.
// Alt+Left/Right (back/forward) is handled in eventFilter(), because that one is
// installed application-wide and thus also works while the web view has the focus.
// Backspace is deliberately NOT intercepted any more: the old branch called
// webEngineView->back() and would swallow every Backspace inside the login
// form, so text could no longer be deleted.
void MainWindow::keyPressEvent(QKeyEvent *event)
{
    if (event->key() == Qt::Key_F5) {
        ui->webEngineView->reload();  // reload the webpage
        event->accept();
        return;
    }
    if (event->modifiers() & Qt::ControlModifier) {
        if (event->key() == Qt::Key_Plus || event->key() == Qt::Key_Equal) {
            ui->webEngineView->setZoomFactor(ui->webEngineView->zoomFactor() + 0.1);
            event->accept();
            return;
    } else if (event->key() == Qt::Key_Minus) {
            ui->webEngineView->setZoomFactor(ui->webEngineView->zoomFactor() - 0.1);
            event->accept();
            return;
        }
    }
    QMainWindow::keyPressEvent(event);
}

// Creates the CredentialBridge and registers it on the WebChannel under the
// name "oidcBridge" (the browser's isolated world writes the captured
// credentials into it).
void MainWindow::setupCredentialCapture()
{
    // Bridge object: provided to the browser (isolated world) via the WebChannel
    m_credentialBridge = new CredentialBridge(this);
    m_webChannel = new QWebChannel(this);
    m_webChannel->registerObject(QStringLiteral("oidcBridge"), m_credentialBridge);
}

// Injects the credential-capture script into the given page: builds the JS
// source from the preamble (allowed hosts), the official qwebchannel client and
// the capture script, then installs the script and the WebChannel transport in
// the isolated world (QWebEngineScript::ApplicationWorld).
void MainWindow::installCredentialCapture(QWebEnginePage *page)
{
    if (!page || !m_webChannel)
        return;

    // Allowed domains: central config OIDC_CAPTURE_PATTERNS (env > file);
    // only honoured when the key exists (empty = watch all domains).
    QStringList patterns = captureMatchPatterns;
    if (RequestInterceptor::s_config.contains(QStringLiteral("OIDC_CAPTURE_PATTERNS")))
        patterns = RequestInterceptor::cfgList("OIDC_CAPTURE_PATTERNS");

    // Extract the domains from the patterns (for the JS hostname check)
    QStringList allowedHosts;
    for (const QString &pattern : patterns) {
        QString host = pattern;
        host.remove(QStringLiteral("https://"));
        host.remove(QStringLiteral("http://"));
        host.remove(QLatin1Char('*'));
        const int port = host.indexOf(QLatin1Char(':'));
        if (port >= 0)
            host.truncate(port);
        const int slash = host.indexOf(QLatin1Char('/'));
        if (slash >= 0)
            host.truncate(slash);
        if (!host.isEmpty() && !allowedHosts.contains(host))
            allowedHosts << host;
    }

    // JS preamble + official qwebchannel.js client (Qt 6.4.2) + capture script
    QStringList jsHosts;
    for (const QString &h : allowedHosts)
        jsHosts << QLatin1Char('\'') + h + QLatin1Char('\'');
    const QString preamble = QStringLiteral("var oidcAllowedHosts = [%1];\n")
            .arg(jsHosts.join(QStringLiteral(", ")));

    const QString scriptSource = preamble
            + readResource(QStringLiteral(":/capture/qwebchannel.js")) + QLatin1Char('\n')
            + readResource(QStringLiteral(":/capture/credential-capture.js"));

    QWebEngineScript script;
    script.setName(QStringLiteral("oidc-login-credential-capture"));
    script.setInjectionPoint(QWebEngineScript::DocumentCreation);
    // Also run in subframes (login/2FA pages partly use iframes).
    script.setRunsOnSubFrames(true);
    script.setSourceCode(scriptSource);

    // Register the script on the page itself (applies to all navigations of this
    // view) and install the WebChannel transport in the same isolated world.
    page->scripts().insert(script);
    page->setWebChannel(m_webChannel, QWebEngineScript::ApplicationWorld);
}

// Loads the given URL in the web engine view and briefly shows it in the status bar.
void MainWindow::loadURL(QUrl url)
{
    ui->statusbar->showMessage(url.toString(), 2500);
    ui->webEngineView->load(url);
}

// Loads the autoload page (central config OIDC_AUTOLOAD) once the window is shown.
void MainWindow::afterWindowVisible()
{
    QUrl url;
    loadCentralConfig();
    autoloadPage = OidcConfig::get(RequestInterceptor::s_config,
                                   "OIDC_AUTOLOAD");
    url.setUrl(autoloadPage);
    this->loadURL(url);

}


// Event filter for the web engine view. It is installed application-wide (qApp)
// because QtWebEngine delivers key events to its internal delegate widget
// instead of the QWebEngineView.
// Handled here: Alt+Left/Right (history back/forward).
//
// IMPORTANT: Backspace is deliberately NOT intercepted. Previously a
// Backspace branch called webEngineView->back() ("this event does not happen", because
// the filter only sat on the web view and KeyPress never arrived there). Since the
// filter is installed app-wide, that branch would swallow every Backspace in
// the login form - characters could no longer be deleted.
bool MainWindow::eventFilter(QObject* obj, QEvent* event)
{
    if (event->type() == QEvent::KeyPress) {
        QKeyEvent* keyEvent = static_cast<QKeyEvent*>(event);
        // Back/forward like in a browser (Alt+Left / Alt+Right). Replaces the
        // previously used Backspace and does not collide with text input.
        // Note: depending on the keyboard layout Alt may also arrive with Meta/GroupSwitch as
        // modifier, so we check via flag instead of exact equality.
        if (keyEvent->modifiers().testFlag(Qt::AltModifier)) {
            if (keyEvent->key() == Qt::Key_Left) {
                ui->webEngineView->back();
                return true;  // handled
            }
            if (keyEvent->key() == Qt::Key_Right) {
                ui->webEngineView->forward();
                return true;  // handled
            }
        }
    }
    return QMainWindow::eventFilter(obj, event);
}

// Creates the always visible "Abbrechen" button in the status bar and installs
// the application-wide event filter for the browser shortcuts (Alt+Left/Right).
// Background: the SDDM greeter runs in an X session without a window manager.
// Its child windows therefore have no window decorations (no title bar, no
// close button) and window-manager shortcuts like Alt+F4 do not work. Without
// this button the maximized browser window could not be closed at all, so the
// user was stuck and could not get back to the normal login.
void MainWindow::setupAbortUi()
{
    ui->statusbar->setSizeGripEnabled(false);

    m_cancelButton = new QPushButton(tr("Abbrechen und zur Anmeldung"), ui->statusbar);
    m_cancelButton->setObjectName(QStringLiteral("oidcCancelButton"));
    m_cancelButton->setMinimumHeight(40);
    m_cancelButton->setToolTip(tr("Schließt die HM-Anmeldung und kehrt zum Anmeldebildschirm zurück."));
    m_cancelButton->setCursor(Qt::PointingHandCursor);

    // Slightly larger/bolder than the default font: the button has to be found
    // quickly on a login screen (touch screens in the labs).
    QFont cancelFont = m_cancelButton->font();
    cancelFont.setPointSizeF(cancelFont.pointSizeF() + 2.0);
    cancelFont.setBold(true);
    m_cancelButton->setFont(cancelFont);

    connect(m_cancelButton, &QPushButton::clicked, this, &MainWindow::abortLogin);

    // Permanent widget = right hand side of the status bar, always visible
    // (the left side briefly shows the loaded URL).
    ui->statusbar->addPermanentWidget(m_cancelButton);

    // The filter must be installed application-wide no matter which widget has
    // the focus (the web view keeps the focus and consumes key events), so that
    // the browser shortcuts handled in eventFilter() (Alt+Left/Right) work.
    qApp->installEventFilter(this);
}

// Aborts the HM login: closes the browser and returns to the greeter without
// granting anything. The network release and the temporary session account only
// run in reactOnSessionCookieFound(), i.e. after a successful OIDC login, so
// aborting at any earlier point is side-effect free (only the captured
// credentials are dropped from memory).
//
// Exit code 3 (instead of 0) is important: the greeter theme reports exit code
// 0 without an "OIDC_ACCOUNT:" line as a successful login. Exit code 3 tells
// the theme this was a user cancellation, not a successful login.
void MainWindow::abortLogin()
{
    if (m_abortRequested || m_postLoginRunning)
        return;
    m_abortRequested = true;


    if (m_cancelButton)
        m_cancelButton->setEnabled(false);

    // Discard the credentials captured from the HM login form
    if (m_credentialBridge)
        m_credentialBridge->clear();

    QCoreApplication::exit(3);
}

// Closing the window (title bar / window manager) must not bypass the abort
// logic, otherwise the app would end with exit code 0 and the greeter would
// show a false "success" message.
void MainWindow::closeEvent(QCloseEvent *event)
{
    abortLogin();
    event->accept();
}
