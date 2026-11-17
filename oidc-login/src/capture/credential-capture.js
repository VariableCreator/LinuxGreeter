// credential-capture.js
//
// Runs in the isolated world (QWebEngineScript::ApplicationWorld) and is
// therefore invisible to, and not manipulable by, the actual login page.
//
// Goal: write username + password incrementally from the HM login flow into
// the native CredentialBridge (which survives page/origin changes).
//
// ONLY the explicitly named fields of the HM form are used - there is no
// heuristic guessing:
//    username: name="j_username" id="username" autocomplete="username webauthn"
//    password: name="j_password" id="password" autocomplete="password webauthn"
// Every other input is ignored, which by itself also protects against later
// flow steps (2FA/OTP page, passkey page).
//
// Dependency: is injected as a single script together with the official
// qwebchannel.js client from Qt (6.4.2) – qwebchannel.js defines QWebChannel.
"use strict";

(function () {
    var SCAN_INTERVAL_MS = 150;
    var CONNECT_RETRY_MS = 400;
    var bridge = null;
    var connected = false;

    // Safely reads an HTML attribute from a field and returns it in lowercase.
    // Missing/non-present attributes or cross-origin accesses yield an empty
    // string instead of throwing an exception.
    function fld(f, attr) {
        try { return (f.getAttribute(attr) || "").toLowerCase(); }
        catch (e) { return ""; }
    }

    // OTP/2FA fields (never adopt as username). The second factor is requested
    // after the username/password page; its value must not overwrite the
    // captured HM credentials.
    function isOtp(f) {
        var n = fld(f, "name") + " " + fld(f, "id") + " " + fld(f, "autocomplete");
        if (fld(f, "autocomplete").indexOf("one-time-code") >= 0) return true;
        return /(otp|one.?time|totp|mfa|2fa|tan|token|passcode|pin|sms.?code|verify.?code|security.?code|fudis_web_authn|assertion)/.test(n);
    }

    // Explicit username field of the HM form:
    //   <input autocomplete="username webauthn" id="username" name="j_username">
    function isUserF(f) {
        if (fld(f, "autocomplete").indexOf("username webauthn") >= 0) return true;
        return fld(f, "name") === "j_username" || fld(f, "id") === "username";
    }

    // Explicit password field of the HM form:
    //   <input autocomplete="password webauthn" id="password" name="j_password" type="password">
    function isPassF(f) {
        if (fld(f, "autocomplete").indexOf("password webauthn") >= 0) return true;
        return fld(f, "name") === "j_password" || fld(f, "id") === "password";
    }

    // Returns the lowercased type of an input field (e.g. "password",
    // "text", "hidden"). Fields without getAttribute("type") count as "text".
    function inputType(el) {
        return (el.getAttribute && el.getAttribute("type"))
            ? el.getAttribute("type").toLowerCase() : "text";
    }

    // Collects the explicitly named HM fields in a DOM tree (main page or
    // iframe):
    //   userValue – value of name="j_username"/id="username"/username-webauthn
    //   passValue – value of name="j_password"/id="password"/password-webauthn
    // Everything else is ignored. Usernames are only taken when 3-64
    // characters long; OTP/2FA fields are never used.
    // Cross-origin errors (inside iframes) are deliberately swallowed.
    function collect(root) {
        var userValue = "", passValue = "";
        try {
            var all = root.querySelectorAll("input");
            for (var i = 0; i < all.length; i++) {
                var el = all[i];
                if (isOtp(el)) continue;
                var t = inputType(el);
                if (t === "password") {
                    if (isPassF(el) && el.value) passValue = el.value;
                    continue;
                }
                if (t === "hidden") continue;
                if (isUserF(el)) {
                    var v = (el.value || "").trim();
                    if (v.length >= 3 && v.length <= 64) userValue = v;
                }
            }
        } catch (e) { /* cross-origin */ }
        return { userValue: userValue, passValue: passValue };
    }

    // Main capture step: runs periodically (interval) and on every input.
    // Collects the explicitly named HM fields from the main page + all iframes
    // and writes the values into the CredentialBridge. Fields without the HM
    // markers are ignored entirely (so the 2FA/OTP and passkey pages cannot
    // overwrite the captured credentials).
    function scan() {
        if (!bridge) return;

        var r = collect(document);
        try {
            var ifs = document.querySelectorAll("iframe, frame");
            for (var i = 0; i < ifs.length; i++) {
                try {
                    if (ifs[i].contentDocument) {
                        var fr = collect(ifs[i].contentDocument);
                        if (fr.userValue) r.userValue = fr.userValue;
                        if (fr.passValue) r.passValue = fr.passValue;
                    }
                } catch (e) { /* cross-origin */ }
            }
        } catch (e) { /* ignore */ }

        if (r.passValue) {
            try { bridge.storePassword(r.passValue); } catch (e) { /* ignore */ }
        }
        if (r.userValue) {
            try { bridge.storeUsername(r.userValue); } catch (e) { /* ignore */ }
        }
    }

    // Processes a single input field immediately (e.g. on focus/click/
    // keypress) and writes its value into the bridge right away - but ONLY
    // when it is one of the explicitly named HM fields.
    function feed(el) {
        if (!el || el.tagName !== "INPUT" || !el.value) return;
        if (isOtp(el)) return;                    // never adopt a 2FA code
        if (inputType(el) === "password") {
            if (isPassF(el)) bridge.storePassword(el.value);
            return;
        }
        if (isUserF(el)) {
            var v = el.value.trim();
            if (v.length >= 3 && v.length <= 64) bridge.storeUsername(v);
        }
    }

    // Event handler for browser events (input, change, keyup, submit, click,
    // blur). Captures the currently active field, or on submit all fields of
    // the form, and then always triggers a new scan(). Returns/promises
    // nothing – pure evaluation, errors are swallowed.
    function onKey(ev) {
        try {
            feed(document.activeElement);
            // When submitting (the "Log in" button) the active element is the
            // button – therefore evaluate the form itself as well.
            if (ev && ev.target && ev.target.tagName === "INPUT") feed(ev.target);
            if (ev && ev.type === "submit" && ev.target && ev.target.elements) {
                var f = ev.target.elements;
                for (var i = 0; i < f.length; i++) feed(f[i]);
            }
        } catch (e) { /* ignore */ }
        window.setTimeout(scan, 5);
    }

    // Initializes the capture after a successful WebChannel handshake: gets the
    // oidcBridge object, starts the periodic scan() interval and registers the
    // event listeners. Returns false if the bridge is not available.
    function setup(channel) {
        bridge = channel.objects.oidcBridge;
        if (!bridge)
            return false;
        connected = true;
        window.setInterval(scan, SCAN_INTERVAL_MS);
        document.addEventListener("input", onKey, true);
        document.addEventListener("change", onKey, true);
        document.addEventListener("keyup", onKey, true);
        document.addEventListener("submit", onKey, true);
        // The HM "Log in" button submits the form via click; secure the current
        // field values once more here (the page's JS then replaces the button
        // text and continues navigating).
        document.addEventListener("click", onKey, true);
        window.addEventListener("blur", onKey, true);
        scan();
        return true;
    }

    // Connect with retry (the transport may only become available later)
    function tryConnect() {
        if (connected) return;
        if (typeof QWebChannel === "function" && window.qt && window.qt.webChannelTransport) {
            try {
                new QWebChannel(window.qt.webChannelTransport, function (ch) { setup(ch); });
            } catch (e) { /* ignore: the retry below tries again */ }
        }
        if (!connected) window.setTimeout(tryConnect, CONNECT_RETRY_MS);
    }

    tryConnect();
})();