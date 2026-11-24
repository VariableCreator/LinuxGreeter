//
// [maya-hm] Main.qml - Win11-style glass greeter (Qt5/Qt6 compatible)
// Keeps HM-Anmeldung (oidc-login), auto-login, session/keyboard selection.
// No QtQuick.Controls / QtQuick.Effects so it runs on Qt5 + Qt6 greeters.
//
// Main script for the SDDM theme
//
// (c) 2016 Sanjeev Premi (spremi@ymail.com)
//
// SPDX-License-Identifier: MIT
//                          (https://spdx.org/licenses/MIT.html)
//


import QtQuick 2.0
import SddmComponents 2.0

import "./components"

Rectangle {
  id: maya_root

  focus: true
  Keys.onPressed: {
    // Any key counts as activity (restarts the idle timer) and - while the
    // screensaver is up - dismisses it and puts the cursor into the password
    // field (see dismissLock).
    maya_root.noteActivity()
    if (maya_root.lockActive && !maya_root.lockAnimating) {
      maya_root.dismissLock()
      event.accepted = true
    }
  }

  property color primaryShade : config.primaryShade ? config.primaryShade : "#303F9F"
  property color primaryLight : config.primaryLight ? config.primaryLight : "#7986CB"
  property color primaryDark  : config.primaryDark  ? config.primaryDark  : "#1A237E"

  property color primaryHue1  : config.primaryHue1  ? config.primaryHue1  : "#5965B2"
  property color primaryHue2  : config.primaryHue2  ? config.primaryHue2  : "#303F9F"
  property color primaryHue3  : config.primaryHue3  ? config.primaryHue3  : "#2C3998"

  property color accentShade  : config.accentShade  ? config.accentShade  : "#FF4081"
  property color accentLight  : config.accentLight  ? config.accentLight  : "#FF80AB"

  property color accentHue1   : config.accentHue1   ? config.accentHue1   : "#FF669A"
  property color accentHue2   : config.accentHue2   ? config.accentHue2   : "#FF4081"
  property color accentHue3   : config.accentHue3   ? config.accentHue3   : "#E73677"

  property color normalText   : config.normalText   ? config.normalText   : "#ffffff"

  // Text color on the background image (light HM image -> dark blue).
  // Adjustable via theme.conf (onBackgroundText).
  property color onBackgroundText : config.onBackgroundText ? config.onBackgroundText : "#1A237E"

  property color successText  : config.successText  ? config.successText  : "#43a047"
  property color failureText  : config.failureText  ? config.failureText  : "#e53935"
  property color warningText  : config.warningText  ? config.warningText  : "#ff8f00"

  property color rebootColor  : config.rebootColor  ? config.rebootColor  : "#fb8c00"
  property color powerColor   : config.powerColor   ? config.powerColor   : "#ff1744"

  readonly property color defaultBg : primaryShade ? primaryShade : "#1e88e5"

  //
  // Indicates one unit of measure (in pixels)
  //
  readonly property int spUnit: 64

  //
  // Symmetric (equal) padding on all sides
  //
  readonly property int padSym : (spUnit / 8)

  //
  // Asymmetric padding in horizontal & vertical directions
  //
  readonly property int padAsymH : (spUnit / 2)
  readonly property int padAsymV : (spUnit / 8)

  //
  // Font sizes
  //
  readonly property int spFontNormal  : 24
  readonly property int spFontSmall   : 16

  // ---- Win11 look (Qt5/Qt6 compatible, no QtQuick.Effects) ----
  // Accent + glass tints.
  property color accentColor: config.accentColor ? config.accentColor : accentShade
  property color backgroundColor: config.backgroundColor ? config.backgroundColor : defaultBg
  property color textColor: config.textColor ? config.textColor : normalText
  readonly property string uiFontFamily: config.fontFamily ? config.fontFamily : ""
  readonly property bool use24HourClock: (config.use24HourClock === "true" || config.use24HourClock === "1")
  readonly property bool showLockScreen: (config.showLockScreen !== "false" && config.showLockScreen !== "0")
  property bool lockActive: showLockScreen
  property bool lockAnimating: false
  property bool loginFailed: false

  // ---- Screensaver / auto-lock ----
  // Seconds without any input until the lock screen appears.
  // 0 disables the automatic lock. Any input then dismisses it and moves the
  // cursor into the password field.
  readonly property int lockAfterSeconds: {
    var v = parseInt(config.lockAfterSeconds)
    return isNaN(v) ? 300 : v
  }

  // Restarts the idle countdown (called on every user interaction).
  function noteActivity() {
    // Only when the screensaver is actually armed: restart() forces
    // running=true and would override the OFF state (lockAfterSeconds=0 ->
    // interval 0 -> the timer would fire in a tight loop).
    if (lockAfterSeconds > 0 && showLockScreen)
      idleLockTimer.restart()
  }

  // Reference cursor position for "mouse wiggle unlocks". Set when the lock
  // appears; the FIRST hover event after that only stores the position (else
  // the screen would unlock instantly while the pointer is just resting).
  property point lockWakeRef: Qt.point(-1, -1)
  readonly property int lockWakeDistance: 24
  // Frosted-glass card tints (translucent dark, works without real blur)
  property color glassCard: Qt.rgba(0.09, 0.10, 0.13, 0.72)
  property color glassField: Qt.rgba(1, 1, 1, 0.08)
  property color glassBorder: Qt.rgba(1, 1, 1, 0.14)

  //
  // HM login (oidc-login browser, launched from the greeter)
  //
  readonly property string oidcLoginCommand   : config.oidcLoginCommand ? config.oidcLoginCommand : "/usr/bin/oidc-login"
  readonly property string hmLoginLabel       : config.hmLoginLabel ? config.hmLoginLabel : "HM Anmeldung"
  readonly property bool   hmLoginAutostart   : (config.hmLoginAutostart && config.hmLoginAutostart === "true")

  //
  // Auto-login after a successful HM login: the theme starts oidc-login with
  // "--autologin" (see launchHmLogin), the browser then additionally provides
  // "OIDC_AUTOLOGIN: <user>\t<pass>" and the theme logs
  // in directly (no second password, no "Login" click).
  // Can be disabled via theme.conf (autoLoginAfterHm=false) - then login
  // runs manually as before.
  //
  readonly property bool autoLoginAfterHm : (config.autoLoginAfterHm !== "false" && config.autoLoginAfterHm !== "0")

  // Is an automatic login attempt currently running? (prevents double login
  // and controls the hint if the automatic login fails)
  property bool hmAutoLoginRunning : false
  // true = the last failure was an auto-login -> keep the hint
  property bool hmFallbackHint     : false

  //
  // Background image (fullscreen, aspect ratio preserved, cropped if needed).
  // Relative to the theme directory, e.g. "images/background.png".
  // Leave empty for a solid-color background (defaultBg).
  //
  readonly property string backgroundImage     : config.backgroundImage ? config.backgroundImage : "images/background.png"

  //
  // Automatic login: evaluation of the oidc-login output.
  //
  // On success oidc-login writes in addition to "OIDC_ACCOUNT: <name>":
  //
  //   OIDC_AUTOLOGIN: <pct(user)>TAB<pct(pass)>
  //
  // Both fields are percent-encoded UTF-8 (QUrl::toPercentEncoding), so that
  // spaces, special chars and line breaks do not destroy the stdout line protocol.
  // decodeURIComponent converts back and yields real
  // UTF-8 chars (Qt.atob could only do Latin-1).
  //
  // Deliberately WITHOUT a separate .js file: a JS import requires the
  // QML module QtQml.WorkerScript in Qt6, which may be missing on a greeter system -
  // a theme that then fails to load would be a login outage.
  //

  function decodePercent(value) {
    if (value === undefined || value === null)
      return null
    try {
      return decodeURIComponent(value)
    } catch (e) {
      return null
    }
  }

  // Returns { user, password } or null (no line, broken encoding,
  // empty fields) -> null means: normal manual login.
  // Deliberately takes the LAST valid OIDC_AUTOLOGIN line: older output
  // (e.g. "stale test output" from a previous run) must not be mixed with
  // fresh credentials.
  function parseAutoLogin(out) {
    if (!out)
      return null

    var result = null
    var lines = out.split("\n")
    for (var i = 0; i < lines.length; ++i) {
      var match = lines[i].match(/^\s*OIDC_AUTOLOGIN:[ \t]*(.+)$/)
      if (!match)
        continue

      // Strip line ending; encoded values never end in whitespace because
      // QUrl::toPercentEncoding escapes those chars.
      var payload = match[1].replace(/[\r\n\s]+$/, "")
      var sep = payload.indexOf("\t")
      if (sep < 1)
        continue

      var user = decodePercent(payload.substring(0, sep))
      var password = decodePercent(payload.substring(sep + 1))
      if (!user || !password)
        continue

      result = { user: user, password: password }
    }
    return result
  }

  // ---- Win11 flow: lock screen (scrim) <-> sign-in card ----
  // The card itself never disappears: while locked it stays visible but
  // dimmed behind the scrim, so "wake up" always ends in a password prompt
  // instead of a black screen without one.
  function dismissLock() {
    if (!maya_root.lockActive || maya_root.lockAnimating)
      return
    maya_root.lockActive = false
    maya_root.lockAnimating = true
    // Fade-out runs via the opacity binding + Behavior; the timer clears
    // lockAnimating afterwards and hands the keyboard focus to the password
    // field (see lockSettleTimer).
    lockSettleTimer.restart()
  }

  function showLock() {
    if (maya_root.lockActive || maya_root.lockAnimating || !maya_root.showLockScreen)
      return
    maya_root.lockActive = true
    maya_root.lockAnimating = true
    // A password typed before the screen was dimmed must not survive in the
    // field (it would be sent by the next Enter).
    maya_password.text = ""
    maya_root.loginFailed = false
    lockWakeRef = Qt.point(-1, -1)
    lockSettleTimer.restart()
  }

  function triggerLogin() {
    if (maya_root.lockActive) {
      maya_root.dismissLock()
      return
    }
    maya_root.tryLogin()
  }
  //
  // Lazily created Process object (GreeterProcess module, see greeter-process/)
  //
  property var hmLoginProcess : null


  LayoutMirroring.enabled: Qt.locale().textDirection == Qt.RightToLeft
  LayoutMirroring.childrenInherit: true

  //
  // Background: image (fullscreen, PreserveAspectCrop) over gradient.
  // Plus a dark scrim + vignette so white text and the
  // glass card stay readable on a light HM image.
  //
  // Solid base area behind everything (covered by the monitor image).
  Rectangle {
    id: maya_bg
    anchors.fill: parent
    color: backgroundColor
  }

  // Soft Win11 gradient when no image is set / while loading.
  Rectangle {
    anchors.fill: parent
    visible: (maya_root.backgroundImage === "")
    gradient: Gradient {
      GradientStop { position: 0.0; color: Qt.lighter(backgroundColor, 1.35) }
      GradientStop { position: 0.55; color: backgroundColor }
      GradientStop { position: 1.0; color: Qt.darker(backgroundColor, 1.5) }
    }
  }

  TextConstants { id: textConstants }

  // Welcome text sits top-left above the HM logo in the background image.
  // -> push it further down so "Welcome to" does not overlap the logo.
  // (Header rectangle starts at y=spUnit instead of y=0.)

  Connections {
    target: sddm

    onLoginSucceeded: {
      prompt_bg.color = successText
      prompt_txt.text = textConstants.loginSucceeded

      maya_root.hmAutoLoginRunning = false
      maya_root.hmFallbackHint     = false
      maya_root.loginFailed = false

      maya_busy.visible = false;
      maya_busy_anim.stop()

      anim_success.start()
    }
    onLoginFailed: {
      prompt_bg.color = failureText

      if (maya_root.hmAutoLoginRunning) {
        // The automatic login (after the HM login) failed:
        // keep the hint and move focus to the password field so that
        // normal login is possible without detour.
        maya_root.hmFallbackHint = true
        prompt_txt.text = qsTr("Automatische Anmeldung fehlgeschlagen – bitte mit dem HM-Passwort anmelden.")
        maya_password.focus = true
      } else {
        prompt_txt.text = textConstants.loginFailed
      }
      maya_root.hmAutoLoginRunning = false
      maya_root.loginFailed = true

      maya_busy.visible = false;
      maya_busy_anim.stop()

      loginShake.start()
      anim_failure.start()
    }
    onInformationMessage: {
      prompt_bg.color = failureText
      prompt_txt.text = message

      maya_root.hmAutoLoginRunning = false

      maya_busy.visible = false;
      maya_busy_anim.stop()

      anim_failure.start()
    }
  }

  //
  // HM login: starts the oidc-login web browser and reports its status in
  // the prompt line at the bottom of the screen.
  //
  Timer {
    id      : hmPromptTimer
    interval: 10000

    onTriggered: {
      // After a failed auto-login keep the hint: it
      // explains why the password must now be entered.
      if (maya_root.hmFallbackHint)
        return
      prompt_bg.color = "transparent"
      prompt_txt.text = ""
    }
  }

  function showHmPrompt(message, color) {
    prompt_bg.color   = color ? color : warningText
    prompt_txt.text   = message
    hmPromptTimer.restart()
  }

  // Discards the collected browser output in the plugin (contains the
  // password during auto-login). Only exists when the plugin is current.
  function clearHmOutput() {
    if (maya_root.hmLoginProcess
        && typeof maya_root.hmLoginProcess.clearOutput === "function")
      maya_root.hmLoginProcess.clearOutput()
  }

  function launchHmLogin() {
    if (maya_root.hmLoginProcess && maya_root.hmLoginProcess.running)
      return

    if (maya_root.hmLoginProcess === null) {
      // Graceful degradation: if the GreeterProcess module is not installed
      // the theme still loads and only shows an error message here.
      maya_root.hmLoginProcess = Qt.createQmlObject(
        "import QtQuick 2.0; import GreeterProcess 1.0; Process { }",
        maya_root, "hmLoginProcess")

      if (maya_root.hmLoginProcess === null) {
        maya_root.showHmPrompt(qsTr("HM-Anmeldung nicht möglich: GreeterProcess-Modul ist nicht installiert."), failureText)
        return
      }

      maya_root.hmLoginProcess.finished.connect(maya_root.onHmLoginFinished)
      maya_root.hmLoginProcess.errorOccurred.connect(maya_root.onHmLoginError)
    }

    maya_root.hmAutoLoginRunning = false
    maya_root.hmFallbackHint     = false

    // Argument list for oidc-login: with active auto-login "--autologin" is
    // passed, so the browser emits the captured credentials on stdout
    // (OIDC_AUTOLOGIN) and the greeter can log in directly (see autoLoginAfterHm).
    var hmArgs = maya_root.autoLoginAfterHm ? ["--autologin"] : []

    maya_root.hmLoginProcess.program    = maya_root.oidcLoginCommand
    maya_root.hmLoginProcess.arguments  = hmArgs

    if (!maya_root.hmLoginProcess.start()) {
      maya_root.showHmPrompt(qsTr("Der oidc-login Browser läuft bereits."), warningText)
    }
  }

  // Logs the user in without a second input. Username AND password
  // come from "OIDC_AUTOLOGIN: ..." (the local account name/local password
  // as created by oidc-session-account). The OIDC_ACCOUNT name only serves
  // as proof that the account was created; autoLogin.user is deliberately used
  // as the login name so both values are guaranteed to come from ONE
  // line. The local password is the captured HM password
  // (the script sets it via chpasswd), so PAM/pam_unix authenticates the
  // login just like a manual entry.
  function startAutoLogin(user, password) {
    if (maya_root.hmAutoLoginRunning || !user || !password)
      return

    maya_root.hmAutoLoginRunning = true
    maya_root.hmFallbackHint     = false

    // The username is visibly pre-filled, the password deliberately
    // NOT (no echo in the password field) - it only goes to sddm.login().
    maya_username.text = user
    maya_password.text = ""

    maya_busy.visible = true;
    maya_busy_anim.start()

    maya_root.showHmPrompt(qsTr("HM-Anmeldung erfolgreich – Anmeldung als \"%1\" läuft …").arg(user),
                           successText)

    sddm.login(user, password, maya_session.index);
  }

  function onHmLoginFinished(exitCode) {
    var out = (maya_root.hmLoginProcess && maya_root.hmLoginProcess.output) ? maya_root.hmLoginProcess.output : ""
    // Take the LAST occurrence: buffer leftovers from an earlier run must not
    // be mixed with the fresh output (see parseAutoLogin).
    var accountMatches = out.match(/OIDC_ACCOUNT:\s*([A-Za-z0-9.__-]+)/g)
    var accountMatch = accountMatches ? accountMatches[accountMatches.length - 1].match(/OIDC_ACCOUNT:\s*([A-Za-z0-9.__-]+)/) : null
    var errorMatches  = out.match(/OIDC_ACCOUNT_ERROR:\s*([^\n]+)/g)
    var errorMatch = errorMatches ? errorMatches[errorMatches.length - 1].match(/OIDC_ACCOUNT_ERROR:\s*([^\n]+)/) : null

    // Auto-login only on successful account creation with complete
    // credentials. If the line is missing (older oidc-login version, auto-login
    // off), it stays with the previous manual flow.
    var autoLogin = null
    if (exitCode === 0 && accountMatch && accountMatch[1])
      autoLogin = maya_root.parseAutoLogin(out)

    // Credentials have been read -> clear the buffer in the plugin.
    maya_root.clearHmOutput()

    if (autoLogin) {
      maya_root.startAutoLogin(autoLogin.user, autoLogin.password)
      return
    }

    var message = ""
    var color = warningText

    if (exitCode === 0 && accountMatch && accountMatch[1]) {
      // Success: account was created → show name + pre-fill
      maya_username.text = accountMatch[1]
      message = qsTr("HM-Anmeldung abgeschlossen. Bitte melde dich als \"%1\" mit deinem HM-Passwort an.").arg(accountMatch[1])
      color = successText
    } else if (exitCode !== 0 && errorMatch && errorMatch[1]) {
      message = qsTr("HM-Anmeldung beendet (Code %1): %2").arg(exitCode).arg(errorMatch[1])
    } else if (exitCode === 0 && errorMatch && errorMatch[1]) {
      // Exit code 0, but account creation failed (e.g. no credentials)
      message = qsTr("Netz-Freigabe aktiv, aber Konto konnte nicht erstellt werden: %1").arg(errorMatch[1])
    } else if (exitCode === 0) {
      message = qsTr("HM-Anmeldung abgeschlossen. Bitte mit deinen HM-Zugangsdaten anmelden.")
      color = successText
    } else {
      message = qsTr("HM-Anmeldung abgebrochen (Code %1).").arg(exitCode)
    }

    maya_root.showHmPrompt(message, color)

    // No auto-login (e.g. account creation failed, credentials
    // incomplete or auto-login disabled): enable normal login
    // directly - keep the hint and move focus to the
    // password field so work can continue without a mouse click.
    maya_root.hmFallbackHint = true
    // The fullscreen browser took the keyboard focus; give it back to the
    // greeter (otherwise keystrokes vanish after the browser window closes).
    maya_root.forceActiveFocus()
    maya_root.noteActivity()
    if (maya_username.text !== "")
      maya_password.focus = true
  }

  function onHmLoginError(message) {
    maya_root.hmFallbackHint = true
    maya_root.showHmPrompt(qsTr("Fehler beim Start von oidc-login: %1").arg(message), failureText)
    maya_root.forceActiveFocus()
    maya_root.noteActivity()
  }


  signal tryLogin()

  onTryLogin : {
    maya_root.hmFallbackHint = false
    maya_root.loginFailed = false

    maya_busy.visible = true;
    maya_busy_anim.start()

    sddm.login(maya_username.text, maya_password.text, maya_session.index);
  }


  FontLoader {
    id: opensans_cond_light
    source: "fonts/OpenSans_CondLight.ttf"
  }

  Repeater {
    model: screenModel

    Item {
      Image {
        x       : geometry.x
        y       : geometry.y
        width   : geometry.width
        height  : geometry.height
        source  : maya_root.backgroundImage
        fillMode: Image.PreserveAspectCrop
        visible : (maya_root.backgroundImage !== "")
        asynchronous: true
        cache   : true
      }
    }
  }

  // Readability scrim over the image (soft gradient + vignette at the bottom).
  Rectangle {
    anchors.fill: parent
    gradient: Gradient {
      GradientStop { position: 0.0; color: Qt.rgba(0, 0, 0, 0.18) }
      GradientStop { position: 0.55; color: Qt.rgba(0, 0, 0, 0.30) }
      GradientStop { position: 1.0; color: Qt.rgba(0, 0, 0, 0.55) }
    }
  }

  // Subtle accent glows (Win11 bloom) - two soft circles.
  Rectangle {
    width: parent.width * 0.55
    height: width
    radius: width / 2
    x: -width * 0.22
    y: -height * 0.28
    color: accentColor
    opacity: 0.16
  }
  Rectangle {
    width: parent.width * 0.45
    height: width
    radius: width / 2
    x: parent.width - width * 0.72
    y: parent.height - height * 0.62
    color: accentColor
    opacity: 0.12
  }

  // Boot fade: starts slightly dimmed, fades in softly.
  Rectangle {
    id: boot_fade
    anchors.fill: parent
    color: "black"
    opacity: 1.0
    NumberAnimation on opacity {
      id: bootFadeAnim
      from: 1.0
      to: 0.0
      duration: 700
      easing.type: Easing.OutQuad
      running: false
    }
  }

  // ---- Lock screen / screensaver ----
  // Win11 look: big clock + hint over a scrim. The sign-in card stays visible
  // (dimmed) BELOW this layer and is re-enabled when the lock is dismissed, so
  // the user always ends up in a password prompt - never on a black screen
  // without one. Appears automatically after `lockAfterSeconds` without input.
  Item {
    id: lock_layer
    anchors.fill: parent
    // Above login_layer/top_bar/bottom_bar (declared later in the file).
    z: 10
    // NOTE: pure bindings - an animation or JS assignment to these properties
    // would DESTROY the binding and the screensaver could only appear once.
    visible: maya_root.lockActive || maya_root.lockAnimating
    opacity: (maya_root.lockActive || maya_root.lockAnimating) ? 1.0 : 0.0
    Behavior on opacity { NumberAnimation { duration: 240; easing.type: Easing.InOutQuad } }

    // Dark scrim: dims the card underneath instead of hiding it.
    Rectangle {
      anchors.fill: parent
      color: Qt.rgba(0, 0, 0, 0.55)
    }

    // Clock + hint sit ABOVE the sign-in card so the lock overlay and the
    // password prompt can never overlap, whatever the screen size.
    // No Column/positioner here: inside a positioner the anchored children of
    // this theme collapse (that made "Welcome to" and the hint overlap), so the
    // three lines are stacked with explicit anchors instead.
    Item {
      id: lock_clock
      anchors.horizontalCenter: parent.horizontalCenter
      width: Math.min(maya_root.width - 48, 460)
      // login_card is centered: (h - card)/2 - 10 is its y -> keep 24 px gap.
      y: Math.max(16, (maya_root.height - login_card.height) / 2 - 10 - height - 24)
      height: clock_face.height + 10 + welcome_txt.height + 8 + lock_hint.height

      SpClock {
        id: clock_face
        anchors.horizontalCenter: parent.horizontalCenter
        y: 0
        width: 420
        height: 200
        tColor: textColor
        use24Hour: maya_root.use24HourClock
        tFont.family: maya_root.uiFontFamily
      }

      Text {
        id: welcome_txt
        anchors.top: clock_face.bottom
        anchors.topMargin: 10
        anchors.left: parent.left
        anchors.right: parent.right
        horizontalAlignment: Text.AlignHCenter
        text: textConstants.welcomeText.arg(sddm.hostName)
        color: textColor
        opacity: 0.85
        font.pixelSize: 16
        font.family: maya_root.uiFontFamily
      }

      Text {
        id: lock_hint
        anchors.top: welcome_txt.bottom
        anchors.topMargin: 8
        anchors.left: parent.left
        anchors.right: parent.right
        horizontalAlignment: Text.AlignHCenter
        text: qsTr("Press any key or move the mouse – then enter your password")
        color: textColor
        // STATIC opacity on purpose: an endless "pulse" animation (the
        // original theme had one here) forces the greeter to redraw the whole
        // screen ~60 times per second - measured 60-150 % CPU on one core per
        // greeter, permanently, because the login screen sits there all day.
        // Without it an idle greeter is at ~0 %.
        opacity: 0.55
        font.pixelSize: 14
        font.family: maya_root.uiFontFamily
      }
    }

    // Click OR mouse movement wakes the screen (a wiggle is enough - no need to
    // hit anything). Both end in dismissLock(), which focuses the password field.
    // Only movement BEYOND lockWakeDistance counts, so a resting pointer (or the
    // hover event X delivers when the layer appears) cannot unlock by itself.
    MouseArea {
      anchors.fill: parent
      hoverEnabled: true
      enabled: maya_root.lockActive && !maya_root.lockAnimating
      onClicked: maya_root.dismissLock()
      onPositionChanged: {
        if (maya_root.lockWakeRef.x < 0) {
          maya_root.lockWakeRef = Qt.point(mouse.x, mouse.y)
          return
        }
        if (Math.abs(mouse.x - maya_root.lockWakeRef.x)
            + Math.abs(mouse.y - maya_root.lockWakeRef.y) > maya_root.lockWakeDistance)
          maya_root.dismissLock()
      }
    }
  }

  // Idle countdown of the screensaver. repeat:true + restart() from
  // noteActivity() = "fire once after N seconds of silence, then again".
  Timer {
    id: idleLockTimer
    repeat: true
    interval: maya_root.lockAfterSeconds * 1000
    running: maya_root.lockAfterSeconds > 0 && maya_root.showLockScreen
    onTriggered: {
      if (maya_root.lockActive || maya_root.lockAnimating)
        return
      // Never dim the screen out from under an active (auto-)login or while
      // the HM login browser is in the foreground.
      if (maya_root.hmAutoLoginRunning)
        return
      if (maya_root.hmLoginProcess && maya_root.hmLoginProcess.running)
        return
      maya_root.showLock()
    }
  }

  // Ends the fade (lockEnter/lockExit) of the screensaver and then either
  // hands the focus to the password field (unlocked) or to the root item
  // (locked). Runs AFTER the Behavior fade instead of animating properties from
  // JS - assigning to lock_layer.visible/opacity from JS would destroy their
  // bindings and the screensaver would only ever appear once.
  Timer {
    id: lockSettleTimer
    interval: 260
    onTriggered: {
      maya_root.lockAnimating = false
      if (maya_root.lockActive) {
        // Locked: keep the greeter reachable, swallow nothing but ensure the
        // root has the keyboard.
        maya_root.focus = true
        return
      }
      // Unlocked: keys/typing must land in the greeter, not in a void - grab
      // the focus for the root item first, then for the password field.
      maya_root.forceActiveFocus()
      maya_root.noteActivity()
      if (maya_username.text === "")
        maya_username.focus = true
      else
        maya_password.focus = true
    }
  }

  // Login shake on failure (Win11 wrong-password nudge).
  SequentialAnimation {
    id: loginShake
    loops: 2
    PropertyAnimation { target: login_card; property: "x"; to: (maya_root.width - login_card.width) / 2 - 12; duration: 55; easing.type: Easing.InOutQuad }
    PropertyAnimation { target: login_card; property: "x"; to: (maya_root.width - login_card.width) / 2 + 12; duration: 55; easing.type: Easing.InOutQuad }
    PropertyAnimation { target: login_card; property: "x"; to: (maya_root.width - login_card.width) / 2; duration: 55; easing.type: Easing.InOutQuad }
  }

  // ---- Win11: slim top bar (host left, clock + power right) ----
  Rectangle {
    id: top_bar
    x: 0
    y: 0
    width: parent.width
    height: 56
    // Stays visible under the lock scrim (dimmed), like the sign-in card.
    color: Qt.rgba(0, 0, 0, 0.28)
    Rectangle {
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.bottom: parent.bottom
      height: 1
      color: Qt.rgba(1, 1, 1, 0.10)
    }
    Row {
      x: 20
      y: 0
      width: parent.width / 2 - 20
      height: parent.height
      spacing: 10
      Rectangle {
        width: 9
        height: 9
        radius: 4.5
        anchors.verticalCenter: parent.verticalCenter
        color: (maya_root.hmLoginProcess && maya_root.hmLoginProcess.running) ? accentColor : Qt.rgba(1, 1, 1, 0.55)
      }
      Text {
        anchors.verticalCenter: parent.verticalCenter
        text: (maya_root.hmLoginProcess && maya_root.hmLoginProcess.running) ? (maya_root.hmLoginLabel + " ...") : sddm.hostName
        color: textColor
        opacity: 0.9
        font.pixelSize: 13
        font.family: maya_root.uiFontFamily
        elide: Text.ElideRight
      }
    }
    Row {
      anchors.right: parent.right
      anchors.rightMargin: 16
      anchors.verticalCenter: parent.verticalCenter
      spacing: 10
      ComboBox {
        id: maya_session
        model: sessionModel
        index: sessionModel.lastIndex
        width: 200
        height: 36
        anchors.verticalCenter: parent.verticalCenter
        color: glassField
        borderColor: glassBorder
        focusColor: accentColor
        hoverColor: accentColor
        textColor: textColor
        menuColor: glassCard
        font.pixelSize: 14
        // Icon paths must go through Qt.resolvedUrl
        arrowIcon: Qt.resolvedUrl("images/ic_arrow_drop_down_white_24px.svg")
        arrowColor: glassBorder
        KeyNavigation.tab: maya_layout
        KeyNavigation.backtab: maya_power
      }
      LayoutBox {
        id: maya_layout
        width: 130
        height: 36
        anchors.verticalCenter: parent.verticalCenter
        color: glassField
        borderColor: glassBorder
        focusColor: accentColor
        hoverColor: accentColor
        textColor: textColor
        menuColor: glassCard
        font.pixelSize: 14
        arrowIcon: Qt.resolvedUrl("images/ic_arrow_drop_down_white_24px.svg")
        arrowColor: glassBorder
        KeyNavigation.tab: maya_username
        KeyNavigation.backtab: maya_session
      }
      Text {
        anchors.verticalCenter: parent.verticalCenter
        text: Qt.formatDateTime(new Date(), maya_root.use24HourClock ? "HH:mm" : "hh:mm AP")
        color: textColor
        opacity: 0.85
        font.pixelSize: 13
        font.family: maya_root.uiFontFamily
        verticalAlignment: Text.AlignVCenter
        Timer {
          interval: 1000
          running: true
          repeat: true
          // Only touch the text when the MINUTE changes: this clock shows
          // HH:mm, and every assignment makes the greeter repaint the whole
          // screen (software rendering = ~10 % CPU permanently otherwise).
          onTriggered: {
            var t = Qt.formatDateTime(new Date(), maya_root.use24HourClock ? "HH:mm" : "hh:mm AP")
            if (parent.text !== t)
              parent.text = t
          }
        }
      }
    }
  }

  // ---- Win11: bottom bar (Restart + Shutdown, rechts unten) ----
  Item {
    id: bottom_bar
    anchors.left: parent.left
    anchors.right: parent.right
    anchors.bottom: parent.bottom
    height: 64
    // Stays visible under the lock scrim (dimmed), like the sign-in card.
    Rectangle {
      anchors.fill: parent
      color: Qt.rgba(0, 0, 0, 0.28)
      Rectangle {
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.top: parent.top
        height: 1
        color: Qt.rgba(1, 1, 1, 0.10)
      }
    }
    Row {
      anchors.right: parent.right
      anchors.rightMargin: 16
      anchors.verticalCenter: parent.verticalCenter
      spacing: 10
      SpButton {
        id: maya_reboot
        width: 150
        height: 44
        enabled: (sddm.canReboot === true)
        icon: Qt.resolvedUrl("images/ic_refresh_white_24px.svg")
        label: textConstants.reboot
        labelColor: textColor
        tooltip: textConstants.reboot
        KeyNavigation.tab: maya_power
        KeyNavigation.backtab: maya_hm_login
        onClicked: sddm.reboot()
      }
      SpButton {
        id: maya_power
        width: 150
        height: 44
        enabled: (sddm.canPowerOff === true)
        icon: Qt.resolvedUrl("images/ic_power_settings_new_white_24px.svg")
        label: textConstants.shutdown
        labelColor: textColor
        tooltip: textConstants.shutdown
        KeyNavigation.tab: maya_session
        KeyNavigation.backtab: maya_reboot
        onClicked: sddm.powerOff()
      }
    }
  }

  // ---- Win11: centered glass login card ----
  // Never hidden: while the screensaver is up the card stays visible but
  // dimmed behind the lock scrim (you can see where to type), and only the
  // input handling is switched off (enabled) until it is dismissed.
  Item {
    id: login_layer
    anchors.fill: parent
    visible: true
    enabled: !maya_root.lockActive
    opacity: maya_root.lockActive ? 0.35 : 1.0
    Behavior on opacity { NumberAnimation { duration: 220; easing.type: Easing.InOutQuad } }
    Rectangle {
      id: login_card
      width: 400
      height: central_col.implicitHeight + 56
      x: (maya_root.width - width) / 2
      y: (maya_root.height - height) / 2 - 10
      color: glassCard
      radius: 12
      border.color: glassBorder
      border.width: 1
      // Mouse movement over the card counts as activity too (declared first,
      // so the fields/buttons above it still get the clicks).
      MouseArea {
        anchors.fill: parent
        hoverEnabled: true
        onPositionChanged: maya_root.noteActivity()
        onPressed: maya_root.noteActivity()
      }
      Rectangle {
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.top: parent.top
        anchors.topMargin: 1
        height: 22
        radius: 11
        gradient: Gradient {
          GradientStop { position: 0.0; color: Qt.rgba(1, 1, 1, 0.10) }
          GradientStop { position: 1.0; color: Qt.rgba(1, 1, 1, 0.0) }
        }
      }
      Column {
        id: central_col
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.top: parent.top
        anchors.margins: 28
        spacing: 12
        Text {
          text: textConstants.userName
          color: textColor
          opacity: 0.75
          font.pixelSize: 13
          font.family: maya_root.uiFontFamily
        }
        Rectangle {
          anchors.left: parent.left
          anchors.right: parent.right
          height: 38
          radius: 6
          color: glassField
          border.color: accentColor
          border.width: 0
          TextBox {
            id: maya_username
            anchors.fill: parent
            anchors.leftMargin: 12
            anchors.rightMargin: 12
            color: Qt.rgba(0,0,0,0)
            borderColor: Qt.rgba(0,0,0,0)
            focusColor: Qt.rgba(0,0,0,0)
            hoverColor: Qt.rgba(0,0,0,0)
            textColor: textColor
            font.pixelSize: 15
            text: ""
            KeyNavigation.tab: maya_password
            KeyNavigation.backtab: maya_layout
            onTextChanged: maya_root.noteActivity()
          }
        }
        Text {
          text: textConstants.password
          color: textColor
          opacity: 0.75
          font.pixelSize: 13
          font.family: maya_root.uiFontFamily
        }
        Rectangle {
          anchors.left: parent.left
          anchors.right: parent.right
          height: 38
          radius: 6
          color: glassField
          border.color: maya_root.loginFailed ? failureText : Qt.rgba(0,0,0,0)
          border.width: 2
          PasswordBox {
            id: maya_password
            anchors.fill: parent
            anchors.leftMargin: 12
            anchors.rightMargin: 12
            color: Qt.rgba(0,0,0,0)
            borderColor: Qt.rgba(0,0,0,0)
            focusColor: Qt.rgba(0,0,0,0)
            hoverColor: Qt.rgba(0,0,0,0)
            textColor: textColor
            image: Qt.resolvedUrl("images/ic_warning_white_24px.svg")
            tooltipEnabled: true
            tooltipText: textConstants.capslockWarning
            tooltipFG: textColor
            tooltipBG: glassCard
            font.pixelSize: 15
            KeyNavigation.tab: maya_login
            KeyNavigation.backtab: maya_username
            onTextChanged: maya_root.noteActivity()
            Keys.onPressed: {
              if ((event.key === Qt.Key_Return) || (event.key === Qt.Key_Enter)) {
                maya_root.triggerLogin()
                event.accepted = true
              }
            }
          }
        }

        Button {
          id: maya_login
          anchors.left: parent.left
          anchors.right: parent.right
          height: 38
          text: textConstants.login
          color: accentColor
          textColor: "white"
          borderColor: Qt.rgba(1,1,1,0.18)
          pressedColor: Qt.darker(accentColor, 1.25)
          activeColor: Qt.lighter(accentColor, 1.12)
          font.pixelSize: 15
          font.weight: Font.DemiBold
          KeyNavigation.tab: maya_hm_login
          KeyNavigation.backtab: maya_password
          onClicked: maya_root.triggerLogin()
          Keys.onPressed: {
            if ((event.key === Qt.Key_Return) || (event.key === Qt.Key_Enter)) {
              maya_root.triggerLogin()
              event.accepted = true
            }
          }
        }
        Button {
          id: maya_hm_login
          anchors.left: parent.left
          anchors.right: parent.right
          height: 38
          enabled: !(maya_root.hmLoginProcess && maya_root.hmLoginProcess.running)
          text: maya_root.hmLoginLabel
          color: Qt.rgba(1,1,1,0.10)
          textColor: textColor
          borderColor: Qt.rgba(1,1,1,0.18)
          pressedColor: Qt.rgba(1,1,1,0.05)
          activeColor: Qt.rgba(1,1,1,0.16)
          font.pixelSize: 14
          font.weight: Font.DemiBold
          KeyNavigation.tab: maya_reboot
          KeyNavigation.backtab: maya_login
          onClicked: maya_root.launchHmLogin()
        }
      }
    }
  }


  //
  // Busy dots (Win11 spinner, centered above prompt toast)
  //
  Item {
    id: maya_busy
    anchors.horizontalCenter: parent.horizontalCenter
    y: parent.height - 150
    width: 120
    height: 24
    visible: false
    property int dotPhase: 0
    Row {
      anchors.centerIn: parent
      spacing: 10
      Repeater {
        model: 5
        Rectangle {
          width: 10
          height: 10
          radius: 5
          color: accentColor
          opacity: (maya_busy.dotPhase % 5) === index ? 1.0 : 0.3
        }
      }
    }
    Timer {
      id: maya_busy_anim
      interval: 150
      running: false
      repeat: true
      onTriggered: maya_busy.dotPhase = (maya_busy.dotPhase + 1) % 5
    }
    function start() { maya_busy_anim.start() }
    function stop() { maya_busy_anim.stop() }
  }

  //
  // Prompt toast (Win11 pill above bottom edge)
  //
  Rectangle {
    id: prompt_bg
    anchors.horizontalCenter: parent.horizontalCenter
    y: parent.height - 110
    width: Math.min(parent.width - 48, prompt_txt.implicitWidth + 40)
    height: 40
    visible: prompt_txt.text !== ""
    color: Qt.rgba(0, 0, 0, 0.55)
    radius: 20
    border.color: Qt.rgba(1, 1, 1, 0.12)
    border.width: 1
    Text {
      id: prompt_txt
      anchors.centerIn: parent
      width: parent.width - 40
      color: textColor
      text: ""
      font.pixelSize: 14
      font.family: maya_root.uiFontFamily
      horizontalAlignment: Text.AlignHCenter
      verticalAlignment: Text.AlignVCenter
      elide: Text.ElideRight
    }
    SequentialAnimation on color {
      id: anim_success
      running: false
      ColorAnimation {
        from: Qt.rgba(0, 0, 0, 0.55)
        to: Qt.rgba(0.26, 0.63, 0.28, 0.75)
        duration: 250
      }
    }
    SequentialAnimation on color {
      id: anim_failure
      running: false
      ColorAnimation {
        from: Qt.rgba(0, 0, 0, 0.55)
        to: Qt.rgba(0.90, 0.22, 0.21, 0.75)
        duration: 250
      }
      PauseAnimation {
        duration: 500
      }
      ColorAnimation {
        from: Qt.rgba(0.90, 0.22, 0.21, 0.75)
        to: Qt.rgba(0, 0, 0, 0.55)
        duration: 500
      }
      onStopped: {
        maya_password.text = ""
        if (!maya_root.hmFallbackHint)
          prompt_txt.text = ""
      }
    }
  }


  Component.onCompleted: {
    bootFadeAnim.start()
    // lock_layer.visible/opacity are BOUND to lockActive/lockAnimating now -
    // never assign them here (that would destroy the binding).
    // Start the idle countdown once the greeter is up (guarded, see
    // noteActivity).
    maya_root.noteActivity()
    // Start the oidc-login browser automatically (optional, see theme.conf)
    if (maya_root.hmLoginAutostart)
      maya_root.launchHmLogin()

    if (maya_root.lockActive)
      return
    if (maya_username.text === "")
      maya_username.focus = true
    else
      maya_password.focus = true
  }
}
