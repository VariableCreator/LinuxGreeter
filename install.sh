#!/usr/bin/env bash
# ----------------------------------------------------------------------------
# Installs the SDDM theme "maya-hm" together with the GreeterProcess QML plugin
# and activates the theme. Additionally installs the session-account helpers,
# the Firefox SSO helper, the sudoers rules,
# the PAM logout hook and the Xsetup greeter-start cleanup.
# Builds and installs the oidc-login browser to /usr/bin/oidc-login.
#
# Usage:
#   sudo ./install.sh                # build + install + activate
#   sudo ./install.sh --qt 5|6       # force a specific Qt variant of the plugin
#   sudo ./install.sh --uninstall    # remove theme, plugin, helpers and config
#
# The GreeterProcess QML plugin must be compiled against exactly the Qt major
# version of the SDDM greeter (Qt5 e.g. on Ubuntu <= 24.04, Qt6 with SDDM 0.21:
# Debian 13 trixie, Ubuntu >= 25.10). install.sh auto-detects the
# matching plugin variant; use --qt to force it.
#
# SDDM 0.21 (Debian 13 trixie, Ubuntu 26.04+) ships a Qt6-only greeter
# whose sddm.service misses the systemd-udev-settle
# ordering that Ubuntu 24.04 distributed (LP #2063143, #2152106; upstream
# sddm#1917). Without it the greeter crashes with HELPER_TTY_ERROR during boot
# (GPU/DRM driver not ready yet) and the login display stays black. install.sh
# installs a systemd drop-in that restores this ordering and pins the theme to
# the DisplayServer/ Qt version that is actually installed.
#
# Prerequisites (build host) – see README.md "Installation"
# ----------------------------------------------------------------------------
set -euo pipefail

# --- Global error trap: dont abort silently ---------------------------
# Prints line number, failed command and exit code to stderr on every abort
_install_err_trap() {
    local rc=$?
    # Normal/intended exits are not reported.
    if [[ $rc -eq 0 ]]; then
        return 0
    fi
    printf 'ERROR: abort in %s, line %s: `%s` (exit code %s).\n' \
        "${BASH_SOURCE[1]:-$0}" "${BASH_LINENO[0]:-?}" \
        "${BASH_COMMAND:-?}" "$rc" >&2
}
trap _install_err_trap ERR

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}" )" && pwd)"
THEME_NAME="maya-hm"
THEME_SRC="$SCRIPT_DIR/sddm-theme"
THEME_DEST="/usr/share/sddm/themes/$THEME_NAME"

PLUGIN_SRC="$SCRIPT_DIR/greeter-process"
PLUGIN_BUILD="$PLUGIN_SRC/build"
MODULE_NAME="GreeterProcess"

SESSION_SRC="$SCRIPT_DIR/session-account"
SESSION_ACCOUNT="/usr/local/sbin/oidc-session-account"
SESSION_CLEANUP="/usr/local/sbin/oidc-session-cleanup"
CONFIG_SRC="$SCRIPT_DIR/config"
CONFIG_FILE="/etc/oidc-login/oidc-login.conf"
CONFIG_LOADER_SH="/etc/oidc-login/oidc-config.sh"
CONFIG_LOADER_PY="/etc/oidc-login/oidc_config.py"
ACCOUNTS_FILE="/etc/oidc-login/session-accounts"
SUDOERS_FILE="/etc/sudoers.d/oidc-login"
SSO_SRC="$SCRIPT_DIR/sso-cookie"
SSO_HELPER="/usr/local/bin/oidc-sso-cookie"
SSO_AUTOSTART="/etc/xdg/autostart/oidc-sso-cookie.desktop"
CLOUD_SRC="$SCRIPT_DIR/cloud-mount"
CLOUD_HELPER="/usr/local/bin/oidc-cloud-mount"
CLOUD_AUTOSTART="/etc/xdg/autostart/oidc-cloud-mount.desktop"

OIDC_LOGIN_SRC="$SCRIPT_DIR/oidc-login/src"
OIDC_LOGIN_BUILD="$SCRIPT_DIR/oidc-login/build"
OIDC_LOGIN_BUILT="$OIDC_LOGIN_BUILD/oidc-login"

SDDM_CONF_DIR="/etc/sddm.conf.d"
# 99-: SDDM merges the files in /etc/sddm.conf.d lexicographically,
# later files override earlier ones. This way our [Theme] Current=maya-hm
# also applies when another file (e.g. 50-ubuntu-budgie.conf) sets a different theme.
SDDM_CONF="$SDDM_CONF_DIR/99-maya-hm.conf"

# Display manager activation
DM_DEFAULT_FILE="/etc/X11/default-display-manager"
DM_SERVICE_LINK="/etc/systemd/system/display-manager.service"
DM_BACKUP_DIR="/etc/sddm"
DM_DEFAULT_BACKUP="$DM_BACKUP_DIR/oidc-login.default-display-manager.orig"
DM_LINK_BACKUP="$DM_BACKUP_DIR/oidc-login.display-manager.orig"
XSETUP="/usr/share/sddm/scripts/Xsetup"

die() { trap - ERR; echo "ERROR: $*" >&2; exit 1; }

# --- Distro detection ---------
# Determines the base distro family from /etc/os-release. Later decisions are
# derived from it. Unknown distros fall back to the Debian path (default).
DISTRO_ID=""
DISTRO_LIKE=""
if [[ -r /etc/os-release ]]; then
    DISTRO_ID="$(. /etc/os-release; echo "${ID:-}")"
    DISTRO_LIKE="$(. /etc/os-release; echo "${ID_LIKE:-}")"
fi
DISTRO_ID="${DISTRO_ID,,}"
DISTRO_LIKE="${DISTRO_LIKE,,}"

DISTRO_DPKG=0   # apt-get / dpkg
DISTRO_DNF=0    # dnf
case ",$DISTRO_ID," in
    *,ubuntu,*|*,debian,*|*,linuxmint,*|*,kali,*) DISTRO_DPKG=1 ;;
    *,fedora,*|*,rhel,*|*,centos,*|*,rocky,*|*,almalinux,*|*,ol,*) DISTRO_DNF=1 ;;
esac
# ID_LIKE as an additional source (e.g. "ID=linuxmint ID_LIKE=ubuntu" or
# an unknown derivative that only sets ID_LIKE=rhel)
if [[ "$DISTRO_DPKG" -eq 0 && "$DISTRO_DNF" -eq 0 ]]; then
    case ",$DISTRO_LIKE," in
        *,debian,*|*,ubuntu,*) DISTRO_DPKG=1 ;;
        *,fedora,*|*,rhel,*|*,centos,*) DISTRO_DNF=1 ;;
    esac
fi
# DEFAULT-DISPLAY-MANAGER mechanics is Debian/Ubuntu-specific.
# Fedora/RHEL enable SDDM directly via systemctl enable sddm.service.
DISTRO_HAS_DM_DEFAULT_FILE=$DISTRO_DPKG

# Ubuntu family: all official
# Ubuntu variants set ID=ubuntu (Xubuntu, Kubuntu, ...),
# Ubuntu derivatives such as Linux Mint or Pop!_OS set ID_LIKE=ubuntu. On these
# systems the mounted network drive is already listed in the file
# manager, so NO ~/Cloud-Storage folder is created in the home directory.
DISTRO_IS_UBUNTU=0
if [[ "$DISTRO_ID" == "ubuntu" ]]; then
    DISTRO_IS_UBUNTU=1
fi
case " ${DISTRO_LIKE//,/ } " in
    *" ubuntu "*) DISTRO_IS_UBUNTU=1 ;;
esac

os_release_id() { printf '%s' "$DISTRO_ID"; }

# Installs a package with the matching package manager.
# Usage: pkg_install <package...>.
# On failure the last log lines are shown on stderr.
pkg_install() {
    local _pkg_log="/tmp/oidc-pkg-install.log"
    if [[ "$DISTRO_DNF" -eq 1 ]]; then
        dnf install -y "$@" >"$_pkg_log" 2>&1 \
            || { tail -n 20 "$_pkg_log" >&2 || true; return 1; }
    else
        DEBIAN_FRONTEND=noninteractive apt-get install -y "$@" >"$_pkg_log" 2>&1 \
            || { tail -n 20 "$_pkg_log" >&2 || true; return 1; }
    fi
}

# --- Detect the Qt major version of the SDDM greeter (5 or 6) -----------------
# Older SDDM releases (e.g. Ubuntu <= 24.04, SDDM 0.20): greeter is Qt5.
# SDDM 0.21 (Debian 13 trixie, Ubuntu >= 25.10/26): greeter is Qt6.
# Default: 5. Can be forced explicitly via --qt 5|6.
detect_qt() {
    local chosen="" greeter="" v=""
    # 1) explicit setting
    if [[ -n "${QT_VERSION_MAJOR:-}" ]]; then
        chosen="$QT_VERSION_MAJOR"
    else
        # 2) derive from the installed greeter binary (ldd)
        #    Qt5 greeter: /usr/bin/sddm-greeter (Qt5).
        #    SDDM 0.21: only /usr/bin/sddm-greeter-qt6 (Qt6).
        greeter="$(command -v sddm-greeter 2>/dev/null || true)"
        [[ -z "$greeter" ]] && greeter="$(command -v sddm-greeter-qt6 2>/dev/null || true)" || true
        [[ -z "$greeter" ]] && greeter="$(command -v sddm-greeter-qt5 2>/dev/null || true)" || true
        if [[ -n "$greeter" ]] && command -v ldd >/dev/null 2>&1; then
            if ldd "$greeter" 2>/dev/null | grep -qi 'libqt5core'; then chosen="5"; fi
            if ldd "$greeter" 2>/dev/null | grep -qi 'libqt6core'; then chosen="6"; fi
        fi
        # 3) Fallback: available qmake versions
        if [[ -z "$chosen" ]]; then
            if command -v qmake6 >/dev/null 2>&1; then
                chosen="6"
            elif command -v qmake-qt5 >/dev/null 2>&1; then
                chosen="5"
            elif command -v qmake >/dev/null 2>&1; then
                v="$(command qmake -query QT_VERSION 2>/dev/null || true)"
                case "$v" in 5.*) chosen="5";; 6.*) chosen="6";; esac
            fi
        fi
    fi
    [[ "$chosen" == "5" || "$chosen" == "6" ]] || chosen="5"
    echo "$chosen"
}

# --- Detect the QML import dir for the given Qt major version -----------------
find_qml_dir() {
    local qt="$1" qmake_cmd="" qml_dir="" qt_version=""
    if [[ "$qt" == "6" ]]; then
        for cmd in qmake6 qmake; do
            if command -v "$cmd" >/dev/null 2>&1; then qmake_cmd="$cmd"; break; fi
        done
    else
        for cmd in qmake-qt5 qmake; do
            if command -v "$cmd" >/dev/null 2>&1; then qmake_cmd="$cmd"; break; fi
        done
    fi
    if [[ -n "$qmake_cmd" ]]; then
        qt_version="$("$qmake_cmd" -query QT_VERSION 2>/dev/null || true)"
        qml_dir="$("$qmake_cmd" -query QT_INSTALL_QML 2>/dev/null || true)"
        if [[ "${qt_version%%.*}" != "$qt" || -z "$qml_dir" ]]; then
            qml_dir=""
        fi
    fi
    # Fallback per distro: Fedora/RHEL place Qt under /usr/lib64/qtN,
    # Debian/Ubuntu under /usr/lib/x86_64-linux-gnu/qtN.
    if [[ -z "$qml_dir" ]] && [[ "$DISTRO_DNF" -eq 1 ]]; then
        qml_dir="/usr/lib64/qt${qt}/qml"
    fi
    echo "${qml_dir:-/usr/lib/x86_64-linux-gnu/qt${qt}/qml}"
}

# --- Argument parsing ----------------------------------------------------------
QT_MAJOR=""            # set below via detect_qt unless specified
while [[ $# -gt 0 ]]; do
    case "$1" in
        --qt)
            [[ $# -ge 2 ]] || die "--qt needs an argument (5 or 6)"
            QT_MAJOR="$2"; shift ;;
        --qt=*) QT_MAJOR="${1#--qt=}" ;;
        --uninstall)
            [[ $EUID -eq 0 ]] || die "Please run as root (sudo $0 --uninstall)"
            rm -rf "$THEME_DEST"
            # Remove QML module from both Qt import paths (depending on greeter install)
            for q in 5 6; do rm -rf "$(find_qml_dir "$q")/$MODULE_NAME"; done
            rm -f "$SDDM_CONF"
            rm -f /etc/systemd/system/sddm.service.d/udev-settle.conf
            rmdir --ignore-fail-on-non-empty /etc/systemd/system/sddm.service.d 2>/dev/null || true

            # Disable SDDM as display manager and restore previous state
            systemctl disable --quiet sddm.service 2>/dev/null || true
            # The /etc/X11/default-display-manager safety check + display-manager.service
            # symlink are Debian/Ubuntu-specific. On Fedora/RHEL these files do not
            # exist and only a systemctl entry has to be removed (done above).
            if [[ -f "$DM_DEFAULT_BACKUP" ]]; then
                cp -a "$DM_DEFAULT_BACKUP" "$DM_DEFAULT_FILE" 2>/dev/null || true
                rm -f "$DM_DEFAULT_BACKUP"
            fi
            if [[ -f "$DM_LINK_BACKUP" ]]; then
                prev_dm="$(cat "$DM_LINK_BACKUP")"
                if [[ -n "$prev_dm" ]]; then
                    rm -f "$DM_SERVICE_LINK"
                    ln -sfn "$prev_dm" "$DM_SERVICE_LINK"
                fi
                rm -f "$DM_LINK_BACKUP"
            fi
            systemctl daemon-reload 2>/dev/null || true
            # Remove orphaned HM login session accounts before script
            # and tracking file are deleted: otherwise local accounts
            # remain without tracking, and the next install reports
            # "username already exists" at login.
            if [[ -x "$SESSION_ACCOUNT" ]]; then
                "$SESSION_ACCOUNT" cleanup-all --force || true
            fi
            rm -f "$SESSION_ACCOUNT" "$SESSION_CLEANUP"
            # Remove SSO helpers + autostart entries. The spools themselves live in the
            # session-account homes and vanish along with the accounts
            # via 'cleanup-all' (above).
            rm -f "$SSO_HELPER" "$SSO_AUTOSTART"
            rm -f "$CLOUD_HELPER" "$CLOUD_AUTOSTART"
            # Suspend block (step 10) FIRST: it reads the marker file
            # /etc/oidc-login/suspend-masked, which is removed just below
            # together with /etc/oidc-login. Undo the mask we set, then drop the
            # logind drop-in and the XFCE idle defaults.
            for _mk in /etc/oidc-login/suspend-masked /etc/oidc-login/suspend-disabled; do
                [[ -f "$_mk" ]] || continue
                while read -r _t; do
                    [[ -n "$_t" ]] || continue
                    rm -f "/etc/systemd/system/$_t"
                    systemctl unmask --quiet "$_t" 2>/dev/null || true
                done < "$_mk"
            done
            # Marker lost but our logind drop-in still present -> the mask is
            # ours, so undo it as well.
            if [[ ! -f /etc/oidc-login/suspend-masked ]] \
               && [[ ! -f /etc/oidc-login/suspend-disabled ]] \
               && [[ -f /etc/systemd/logind.conf.d/60-oidc-no-suspend.conf ]]; then
                for _t in sleep.target suspend.target hibernate.target hybrid-sleep.target; do
                    rm -f "/etc/systemd/system/$_t"
                    systemctl unmask --quiet "$_t" 2>/dev/null || true
                done
            fi
            systemctl daemon-reload 2>/dev/null || true
            rm -f /etc/systemd/logind.conf.d/60-oidc-no-suspend.conf
            rmdir --ignore-fail-on-non-empty /etc/systemd/logind.conf.d 2>/dev/null || true
            if [[ -f /etc/xdg/xfce4/xfconf/xfce-perchannel-xml/xfce4-power-manager.xml ]]; then
                sed -i '/name="inactivity-on-ac"/d;/name="inactivity-on-battery"/d' \
                    /etc/xdg/xfce4/xfconf/xfce-perchannel-xml/xfce4-power-manager.xml 2>/dev/null || true
            fi
            # NOTE: systemd-logind is deliberately NOT restarted here: that
            # kills live greeter/session PAM sessions, and SDDM then creates a
            # new display (X server + VT) for every killed greeter.
            unset _t 2>/dev/null || true
            rm -rf /etc/oidc-login
            rm -f "$SUDOERS_FILE"
            for _pam in /etc/pam.d/sddm /etc/pam.d/sddm-autologin /etc/pam.d/sddm-greeter; do
                sed -i '\#oidc-session-cleanup#d' "$_pam" 2>/dev/null || true
            done
            sed -i '\#oidc-session-account cleanup-all#d' "$XSETUP" 2>/dev/null || true
            # Greeter display awake block in Xsetup + resume hook (steps 9b/9c):
            # leave the system without our xset tweaks.
            if [[ -f "$XSETUP" ]]; then
                sed -i '/greeter display stays awake/,/^fi$/d' "$XSETUP" 2>/dev/null || true
            fi
            rm -f /usr/lib/systemd/system-sleep/oidc-greeter-resume
            # (suspend block cleanup already happened above, before
            # /etc/oidc-login was removed)
            # Fedora/RHEL: remove SELinux policy module again (installed in step 0b)
            semodule -r oidc_session 2>/dev/null || true
            echo "Theme '$THEME_NAME', QML module '$MODULE_NAME', session-account helpers, sudoers and PAM hook removed."
            echo "SDDM disabled as display manager; previous display manager restored."
            echo "Check active theme: sddm.conf or /etc/alternatives/sddm-ubuntu-theme"
            exit 0 ;;
        *) die "Unknown argument: $1" ;;
    esac
    shift
done

# Package manager name for hints/error messages (apt-get vs. dnf).
if [[ "$DISTRO_DNF" -eq 1 ]]; then PKG_MGR="dnf install"; else PKG_MGR="apt-get install"; fi

[[ $EUID -eq 0 ]] || die "Please run as root (sudo $0)"

command -v cmake >/dev/null 2>&1 || die "cmake is missing. Please install: $PKG_MGR ... (see README.md 'Installation')"
command -v g++   >/dev/null 2>&1 || die "g++ is missing. Please install: $PKG_MGR ... (see README.md 'Installation')"

# --- 0. SDDM must be installed (provides /etc/pam.d/sddm, Xsetup, sddm.service) ---
# Fedora KDE spin may still use GDM.
if ! command -v sddm >/dev/null 2>&1 \
   && ! command -v sddm-greeter >/dev/null 2>&1 \
   && ! command -v sddm-greeter-qt6 >/dev/null 2>&1 \
   && [[ ! -f /usr/lib/systemd/system/sddm.service && ! -f /lib/systemd/system/sddm.service ]]; then
    echo "==> SDDM not found - installing sddm package ..."
    pkg_install sddm \
        || die "could not install sddm package ($PKG_MGR sddm)."
fi

# --- 0b. Fedora/RHEL: SELinux tools + policy module for session accounts ----------
# The greeter (user sddm, domain xdm_t) creates session accounts via useradd /
# chpasswd / userdel. sudo grants uid 0 but keeps the xdm_t domain, which is why
# account creation fails on Fedora without the module
# ("useradd: cannot lock /etc/passwd" + silent chpasswd RC=1).
if [[ "$DISTRO_DNF" -eq 1 ]]; then
    echo "==> SELinux policy module 'oidc_session' (Fedora/RHEL) ..."
    command -v getenforce >/dev/null 2>&1 && [[ "$(getenforce 2>/dev/null)" != "Disabled" ]] && {
        pkg_install policycoreutils-devel setools-console \
            || die "could not install SELinux tools ($PKG_MGR policycoreutils-devel setools-console)."
        if command -v checkmodule >/dev/null 2>&1 && [[ -f "$SCRIPT_DIR/selinux/oidc_session.te" ]]; then
            SELINUX_TMP="$(mktemp -d)"
            if checkmodule -M -m -o "$SELINUX_TMP/oidc_session.mod" "$SCRIPT_DIR/selinux/oidc_session.te" >/dev/null 2>&1 \
               && semodule_package -o "$SELINUX_TMP/oidc_session.pp" -m "$SELINUX_TMP/oidc_session.mod" >/dev/null 2>&1 \
               && semodule -i "$SELINUX_TMP/oidc_session.pp" >/dev/null 2>&1; then
                echo "   SELinux module 'oidc_session' loaded (semodule -l | grep oidc_session)."
            else
                rm -rf "$SELINUX_TMP"
                die "could not build/load SELinux policy module."
            fi
            rm -rf "$SELINUX_TMP"
        else
            echo "!! checkmodule missing or selinux/oidc_session.te not found - account creation stays blocked."
        fi
    }
fi

# --- Determine the greeter Qt version -------------------------------------------
if [[ -n "$QT_MAJOR" ]]; then
    QT_VERSION_MAJOR="$QT_MAJOR"
fi
QT_VERSION_MAJOR="$(detect_qt)"
QML_INSTALL_DIR="$(find_qml_dir "$QT_VERSION_MAJOR")"
echo "SDDM greeter/Qt major: $QT_VERSION_MAJOR"
echo "QML import directory: $QML_INSTALL_DIR"

# --- 1. Build the GreeterProcess QML plugin ---------------------------------------
echo "==> Building QML plugin $MODULE_NAME (Qt$QT_VERSION_MAJOR) ..."
# Remove old build directory
rm -rf "$PLUGIN_BUILD"
if ! cmake -S "$PLUGIN_SRC" -B "$PLUGIN_BUILD" -DQT_VERSION_MAJOR="$QT_VERSION_MAJOR" >/tmp/oidc-plugin-cmake.log 2>&1; then
    tail -n 30 /tmp/oidc-plugin-cmake.log >&2 || true
    die "plugin cmake failed (log above, full: /tmp/oidc-plugin-cmake.log)"
fi
if ! cmake --build "$PLUGIN_BUILD" >/tmp/oidc-plugin-build.log 2>&1; then
    tail -n 30 /tmp/oidc-plugin-build.log >&2 || true
    die "plugin build failed (log above, full: /tmp/oidc-plugin-build.log)"
fi
[[ -f "$PLUGIN_BUILD/$MODULE_NAME/libgreeterprocess.so" ]] || die "plugin was not built"
[[ -f "$PLUGIN_BUILD/$MODULE_NAME/qmldir" ]] || die "qmldir missing in plugin module"

# --- 2. Install the QML module into the matching Qt import path --------------------
echo "==> QML module to $QML_INSTALL_DIR/$MODULE_NAME ..."
install -d "$QML_INSTALL_DIR/$MODULE_NAME"
install -m 755 "$PLUGIN_BUILD/$MODULE_NAME/libgreeterprocess.so" "$QML_INSTALL_DIR/$MODULE_NAME/"
install -m 644 "$PLUGIN_BUILD/$MODULE_NAME/qmldir"             "$QML_INSTALL_DIR/$MODULE_NAME/"

# --- 3. Install the theme ------------------------------------------------------
echo "==> Theme to $THEME_DEST ..."
rm -rf "$THEME_DEST"
mkdir -p "$THEME_DEST"
cp -r "$THEME_SRC"/. "$THEME_DEST"/
chmod -R a+rX "$THEME_DEST"
# A theme without theme.conf would fail later with a bare sed error; fail here with a clear message instead.
[[ -f "$THEME_DEST/theme.conf" ]] \
    || die "theme.conf missing in $THEME_DEST after copying $THEME_SRC (incomplete copy?)."

# --- 3b. Theme metadata: record the greeter Qt version ----------------------
# SDDM >= 0.21 starts the greeter matching 'QtVersion' (5 -> sddm-greeter,
# 6 -> sddm-greeter-qt6). Without the line SDDM assumes Qt5 as default - on
# SDDM 0.21 (Debian 13 trixie, Ubuntu 26; only qt6 greeter installed) sddm-greeter is then missing and SDDM falls
# back to the default theme.
echo "==> Setting QtVersion=$QT_VERSION_MAJOR in metadata.desktop ..."
if grep -qi '^QtVersion=' "$THEME_DEST/metadata.desktop"; then
    sed -i "s/^QtVersion=.*/QtVersion=$QT_VERSION_MAJOR/I" "$THEME_DEST/metadata.desktop"
else
    printf 'QtVersion=%s\n' "$QT_VERSION_MAJOR" >> "$THEME_DEST/metadata.desktop"
fi

# Write the central config to /etc now: section 3c
# below and the InputMethod block read it as source - so the current
# template always applies.
install -d /etc/oidc-login
install -m 644 "$CONFIG_SRC/oidc-login.conf" "$CONFIG_FILE"
echo "    central config: $CONFIG_FILE (overwritten from template)"

# --- 3d. Network drive: symlink only where the file manager can use it ------
# The symlink ~/Cloud-Storage -> /run/user/$UID/gvfs/... works in file
# managers that treat the gvfs FUSE path as a remote location.
_cloud_dir_handler=""
if command -v xdg-mime >/dev/null 2>&1; then
    _cloud_dir_handler="$(xdg-mime query default inode/directory 2>/dev/null || true)"
fi
if [[ -z "$_cloud_dir_handler" ]] && command -v gio >/dev/null 2>&1; then
    _cloud_dir_handler="$(gio mime inode/directory 2>/dev/null \
        | sed -n '1s/^[^:]*: //p' || true)"
fi
if [[ -z "$_cloud_dir_handler" ]]; then
    # No xdg-mime/gio yet: read the mime defaults directly (first entry wins).
    for _cloud_mime_file in "${HOME:-/root}/.config/mimeapps.list" \
                            /etc/xdg/mimeapps.list \
                            /usr/share/applications/mimeinfo.cache \
                            /usr/share/applications/defaults.list; do
        [[ -r "$_cloud_mime_file" ]] || continue
        _cloud_dir_handler="$(sed -n 's/^[[:space:]]*inode\/directory=//p' \
            "$_cloud_mime_file" 2>/dev/null | tail -1 | cut -d';' -f1)"
        [[ -n "$_cloud_dir_handler" ]] && break
    done
fi
_cloud_dir_handler="${_cloud_dir_handler,,}"

CLOUD_FM_HANGS=0
case "$_cloud_dir_handler" in
    *thunar*) CLOUD_FM_HANGS=1 ;;  # Thunar opens the folder -> it would hang
esac
if [[ -z "$_cloud_dir_handler" ]]; then
    # Handler unknown: fall back to the conservative check (Thunar installed
    # AND an XFCE/Xubuntu session on the box).
    if command -v thunar >/dev/null 2>&1 \
       && { [[ -f /usr/share/xsessions/xfce.desktop ]] \
            || [[ -f /usr/share/xsessions/xubuntu.desktop ]] \
            || command -v xfce4-session >/dev/null 2>&1; }; then
        CLOUD_FM_HANGS=1
    fi
fi
CLOUD_SYMLINK_OFF=0
CLOUD_SYMLINK_WHY=""
if [[ "$DISTRO_IS_UBUNTU" -eq 1 ]]; then
    CLOUD_SYMLINK_OFF=1
    CLOUD_SYMLINK_WHY="Ubuntu: the mounted network drive is already listed in the file manager (Networks / Other Locations)"
elif [[ "$CLOUD_FM_HANGS" -eq 1 ]]; then
    CLOUD_SYMLINK_OFF=1
    CLOUD_SYMLINK_WHY="Thunar opens folders here (dir handler: $_cloud_dir_handler), the folder would stay in 'Loading folder contents...'"
fi
if [[ "$CLOUD_SYMLINK_OFF" -eq 1 ]]; then
    if grep -q '^[[:space:]]*OIDC_CLOUD_SYMLINK=' "$CONFIG_FILE" 2>/dev/null; then
        sed -i 's/^[[:space:]]*OIDC_CLOUD_SYMLINK=.*/OIDC_CLOUD_SYMLINK=false/' "$CONFIG_FILE"
    else
        printf 'OIDC_CLOUD_SYMLINK=false\n' >> "$CONFIG_FILE"
    fi
    echo "    ~/Cloud-Storage symlink disabled - $CLOUD_SYMLINK_WHY"
    echo "      the network drive itself is still mounted; a leftover symlink is removed by this installer"
    echo "      re-enable with OIDC_CLOUD_SYMLINK=true in $CONFIG_FILE"
else
    echo "    Directory handler: ${_cloud_dir_handler:-unknown} - ~/Cloud-Storage symlink stays enabled."
fi

# --- 3c. Fill the theme config from the central config ---------------------
# theme.conf gets the UI values from the central
# config /etc/oidc-login/oidc-login.conf. That file was freshly written from the template.
# The central config always wins: a value set there overwrites the
# same-named key in theme.conf. Key missing
# or empty in the central config = theme.conf default.
_oidc_theme_conf="$CONFIG_FILE"
_oidc_theme_val() {
    local _key="$1" _v=""
    if [[ -n "$_oidc_theme_conf" ]]; then
        _v="$(sed -n -e "s/^[[:space:]]*${_key}[[:space:]]*=[[:space:]]*//p" "$_oidc_theme_conf" 2>/dev/null | tail -n 1)"
    fi
    _v="${_v%$'\r'}"
    # strip matching quotes (values with spaces)
    if [[ ${#_v} -ge 2 && "${_v:0:1}" == '"' && "${_v: -1}" == '"' ]]; then _v="${_v:1:-1}";
    elif [[ ${#_v} -ge 2 && "${_v:0:1}" == "'" && "${_v: -1}" == "'" ]]; then _v="${_v:1:-1}"; fi
    # Key missing/empty -> print empty; _theme_set then leaves theme.conf untouched.
    printf '%s' "$_v"
}
if [[ -n "$_oidc_theme_conf" ]]; then
    echo "==> Filling theme.conf from $_oidc_theme_conf ..."
    _theme_set() {
        local _k="$1" _v="$2" _esc
        # Key missing or empty in the central config: theme.conf default stays.
        [[ -n "$_v" ]] || return 0
        # Value present: always wins - the previous value in theme.conf is replaced.
        # Escaping for the replacement (&), backslash and delimiter (|) in sed.
        _esc="$(printf '%s' "$_v" | sed -e 's/[\\&|]/\\&/g')"
        if grep -q "^${_k}=" "$THEME_DEST/theme.conf" 2>/dev/null; then
            sed -i "s|^${_k}=.*|${_k}=${_esc}|" "$THEME_DEST/theme.conf"
        else
            printf '%s=%s\n' "$_k" "$_v" >> "$THEME_DEST/theme.conf"
        fi
    }
    _theme_set "oidcLoginCommand"   "$(_oidc_theme_val OIDC_LOGIN_COMMAND)"
    _theme_set "hmLoginLabel"       "$(_oidc_theme_val HM_LOGIN_LABEL)"
    _theme_set "hmLoginAutostart"   "$(_oidc_theme_val HM_LOGIN_AUTOSTART)"
    _theme_set "autoLoginAfterHm"   "$(_oidc_theme_val AUTO_LOGIN_AFTER_HM)"
    _theme_set "accentColor"        "$(_oidc_theme_val THEME_ACCENT_COLOR)"
    _theme_set "backgroundColor"    "$(_oidc_theme_val THEME_BACKGROUND_COLOR)"
    _theme_set "textColor"          "$(_oidc_theme_val THEME_TEXT_COLOR)"
    _theme_set "fontFamily"         "$(_oidc_theme_val THEME_FONT_FAMILY)"
    _theme_set "use24HourClock"     "$(_oidc_theme_val THEME_USE_24H_CLOCK)"
    _theme_set "showLockScreen"     "$(_oidc_theme_val THEME_SHOW_LOCK_SCREEN)"
    _theme_set "lockAfterSeconds"   "$(_oidc_theme_val THEME_LOCK_AFTER_SECONDS)"
    _theme_set "onBackgroundText"   "$(_oidc_theme_val THEME_ON_BACKGROUND_TEXT)"
fi
unset _oidc_theme_conf _oidc_theme_val _theme_set 2>/dev/null || true

# --- 4. Build and install the oidc-login browser -------------------------------
echo "==> Building oidc-login ..."
rm -rf "$OIDC_LOGIN_BUILD"
if ! cmake -S "$OIDC_LOGIN_SRC" -B "$OIDC_LOGIN_BUILD" \
    >/tmp/oidc-login-cmake.log 2>&1; then
    tail -n 40 /tmp/oidc-login-cmake.log >&2 || true
    die "oidc-login cmake failed. Please install the browser dependencies from README.md."
fi
if ! cmake --build "$OIDC_LOGIN_BUILD" \
    >/tmp/oidc-login-build.log 2>&1; then
    tail -n 40 /tmp/oidc-login-build.log >&2 || true
    die "oidc-login build failed (full: /tmp/oidc-login-build.log)."
fi
[[ -x "$OIDC_LOGIN_BUILT" ]] \
    || die "oidc-login binary missing after build: $OIDC_LOGIN_BUILT"
echo "==> oidc-login -> /usr/bin/oidc-login"
install -m 755 "$OIDC_LOGIN_BUILT" /usr/bin/oidc-login

# --- 4b. Ensure X server + input/video drivers (greeter needs X11) ---
# SDDM starts the X11 greeter via [X11] ServerPath (default /usr/bin/Xorg).
# On GNOME/Wayland systems (gdm) often no Xorg is installed at all (only
# Xwayland) -> without Xorg there is no /usr/bin/Xorg -> black screen.
# NOTE: Xorg alone contains NO input drivers. Without libinput/evdev Xorg
# starts but accepts no mouse/keyboard input -> dead greeter.
if [[ "$DISTRO_DNF" -eq 1 ]]; then
    XORG_PKGS=(xorg-x11-server-Xorg xorg-x11-drv-libinput xorg-x11-server-utils)
else
    # x11-xserver-utils provides 'xset' - needed to keep the greeter display
    # awake (Xsetup) and to switch the panel back on after resume.
    XORG_PKGS=(xserver-xorg-core xserver-xorg-input-all xserver-xorg-video-all x11-xserver-utils)
fi
xorg_input_ok=0
for f in /usr/lib/xorg/modules/input/libinput_drv.so /usr/lib/xorg/modules/input/evdev_drv.so /usr/lib64/xorg/modules/input/libinput_drv.so /usr/lib64/xorg/modules/input/evdev_drv.so; do
    [[ -f "$f" ]] && xorg_input_ok=1
done
if ! [[ -x /usr/bin/Xorg || -x /usr/lib/xorg/Xorg || -x /usr/libexec/Xorg ]] || [[ "$xorg_input_ok" -eq 0 ]]; then
    echo "==> Xorg server/input drivers incomplete - installing Xorg packages ..."
    pkg_install "${XORG_PKGS[@]}" \
        || die "could not install Xorg packages (${DISTRO_DNF}->dnf / else apt-get)."
    [[ -x /usr/bin/Xorg || -x /usr/lib/xorg/Xorg || -x /usr/libexec/Xorg ]] \
        || die "Xorg binary not found after installation."
    ls /usr/lib/xorg/modules/input/libinput_drv.so /usr/lib64/xorg/modules/input/libinput_drv.so >/dev/null 2>&1 \
        || die "Xorg input drivers still missing."
    echo "   Xorg server and input/video drivers installed."
fi
# 'xset' is needed on an otherwise complete X installation too: Xsetup keeps
# the greeter display awake with it and the resume hook switches the panel
# back on. Missing xset = the theme fix alone would not stop X from blanking.
if ! command -v xset >/dev/null 2>&1; then
    echo "==> 'xset' missing (x11-xserver-utils / xorg-x11-server-utils) - installing ..."
    if [[ "$DISTRO_DNF" -eq 1 ]]; then
        pkg_install xorg-x11-server-utils || echo "!! xset still missing - greeter blanking cannot be switched off."
    else
        pkg_install x11-xserver-utils || echo "!! xset still missing - greeter blanking cannot be switched off."
    fi
fi

# --- 5. Activate the theme -------------------------------------------------------
echo "==> Enabling theme '$THEME_NAME' ($SDDM_CONF) ..."
install -d "$SDDM_CONF_DIR"
# NOTE: [General] lives COMPLETELY in THIS file:
# SDDM merges /etc/sddm.conf.d lexicographically, later files override
# earlier ones PER KEY. Still, ALL [General] keys we want
# to control (DisplayServer, InputMethod AND GreeterEnvironment) belong here:
# e.g. 50-ubuntu-budgie.conf sets
#   GreeterEnvironment=...,QT_IM_MODULE=qtvirtualkeyboard
# which would enable the keyboard via env var even with empty InputMethod.
# Hence explicitly clear GreeterEnvironment= in the OFF case.
# On-screen keyboard (SDDM_INPUT_METHOD from oidc-login.conf):
#   empty/disabled (default) -> InputMethod=  (explicitly empty = OFF,
#     important for SDDM 0.21/Qt6 greeter on Debian 13/Ubuntu 26: missing
#     line != disabled, empty line is; additionally QT_IM_MODULE empty)
#   qtvirtualkeyboard            -> Qt Virtual Keyboard
#   ibus / maliit / ...          -> other input methods
_oidc_input_method=""
if [[ -f "$CONFIG_FILE" ]]; then
    _oidc_input_method="$(sed -n -e 's/^[[:space:]]*SDDM_INPUT_METHOD[[:space:]]*=[[:space:]]*//p' "$CONFIG_FILE" 2>/dev/null | tail -n 1)"
fi
_oidc_input_method="${_oidc_input_method%$'\r'}"
if [[ ${_oidc_input_method:0:1} == '"' && ${_oidc_input_method: -1} == '"' && ${#_oidc_input_method} -ge 2 ]]; then
    _oidc_input_method="${_oidc_input_method:1:-1}"
elif [[ ${_oidc_input_method:0:1} == "'" && ${_oidc_input_method: -1} == "'" && ${#_oidc_input_method} -ge 2 ]]; then
    _oidc_input_method="${_oidc_input_method:1:-1}"
fi
# "disabled"/"none"/"-"/"0"/"false" count as empty (= off).
case "${_oidc_input_method,,}" in
    ""|"0"|"false"|"no"|"none"|"disabled"|"-") _oidc_input_method="" ;;
esac
if [[ -n "$_oidc_input_method" ]]; then
    echo "==> Greeter on-screen keyboard: ON ($_oidc_input_method)"
    cat > "$SDDM_CONF" <<EOF
[General]
# Explicitly use X11 to avoid black screen issues with SDDM 0.21+ (Debian 13 trixie, Ubuntu 26+).
# The Wayland display server can cause the greeter to show a black screen.
DisplayServer=x11
# On-screen keyboard in the greeter (SDDM_INPUT_METHOD=$_oidc_input_method in oidc-login.conf).
InputMethod=$_oidc_input_method
# Own greeter environment (overrides e.g. 50-ubuntu-budgie.conf, which
# sets QT_IM_MODULE=qtvirtualkeyboard via GreeterEnvironment).
GreeterEnvironment=QT_IM_MODULE=$_oidc_input_method

[X11]
# Greeter X server: no screen blanking, no DPMS power-off.
# Without this X blanks the monitor after ~10 minutes on its own; the first
# wake-up key/click is eaten by the X screen saver, so the login looks like a
# black screen without a password prompt. The theme's own lock screen
# does the "dim after idle" job instead.
# '-s 0' disables X's screen saver. DPMS is switched off by 'xset -dpms' in
# Xsetup (step 9b) and NOT by '-dpms' here: '-dpms' removes the DPMS extension
# from the whole X server, and that server is reused by the user session - the
# session's own monitor-standby settings would stop working.
# NOTE: ServerArguments REPLACES SDDM's default -> -nolisten tcp must stay.
ServerArguments=-nolisten tcp -s 0

[Theme]
Current=$THEME_NAME
EOF
else
    echo "==> Greeter on-screen keyboard: OFF (InputMethod= empty in $SDDM_CONF)"
    cat > "$SDDM_CONF" <<EOF
[General]
# Explicitly use X11 to avoid black screen issues with SDDM 0.21+ (Debian 13 trixie, Ubuntu 26+).
# The Wayland display server can cause the greeter to show a black screen.
DisplayServer=x11
# On-screen keyboard in the greeter is DISABLED (SDDM_INPUT_METHOD empty in
# oidc-login.conf): explicitly empty line = physical keyboard only.
# (Note: a MISSING line is not enough on SDDM 0.21/Qt6, the empty one is.)
# To enable: set SDDM_INPUT_METHOD=qtvirtualkeyboard in
# /etc/oidc-login/oidc-login.conf and re-run install.sh.
InputMethod=
# NOTE: explicitly clear GreeterEnvironment= – otherwise the greeter inherits
# QT_IM_MODULE=qtvirtualkeyboard from 50-ubuntu-budgie.conf
# (SDDM merges per key, GreeterEnvironment would otherwise persist
# and enable the keyboard despite empty InputMethod).
GreeterEnvironment=

[X11]
# Greeter X server: no screen blanking, no DPMS power-off.
# Without this X blanks the monitor after ~10 minutes on its own; the first
# wake-up key/click is eaten by the X screen saver, so the login looks like a
# black screen without a password prompt. The theme's own lock screen
# (lockAfterSeconds) does the "dim after idle" job instead - with the sign-in
# card and password field still behind it.
# '-s 0' disables X's screen saver. DPMS is switched off by 'xset -dpms' in
# Xsetup (step 9b) and NOT by '-dpms' here: '-dpms' removes the DPMS extension
# from the whole X server, and that server is reused by the user session - the
# session's own monitor-standby settings would stop working.
# NOTE: ServerArguments REPLACES SDDM's default -> -nolisten tcp must stay.
ServerArguments=-nolisten tcp -s 0

[Theme]
Current=$THEME_NAME
EOF
fi
unset _oidc_input_method

# --- 5b. SDDM 0.21 (Debian 13 trixie / Ubuntu 25.10+/26.04+): fix boot ordering ---
# Regression since SDDM 0.21: sddm.service starts before
# GPU/DRM init completes. The greeter crashes with HELPER_TTY_ERROR
# in a restart loop, the login display stays black (LP #2152106,
# upstream sddm/sddm#1917). Ubuntu 24.04 fixed this via a systemd-udev-settle
# dependency in sddm.service (LP #2063143); the 26.04 packages lack
# this fix (SDDM 0.21 packages without udev-settle ordering). A drop-in restores the order.
# This fix applies to the Debian/Ubuntu sddm.service packages (SDDM 0.21);
# on Fedora/RHEL it is not needed (their sddm.service already contains the
# desired ordered-from-udev dependency or uses other units).
SDDM_SERVICE_UNIT=""
for _u in /usr/lib/systemd/system/sddm.service /lib/systemd/system/sddm.service; do
    if [[ -f "$_u" ]]; then SDDM_SERVICE_UNIT="$_u"; break; fi
done
unset _u
SDDM_DROPIN_DIR="/etc/systemd/system/sddm.service.d"
SDDM_DROPIN="$SDDM_DROPIN_DIR/udev-settle.conf"
if [[ "$DISTRO_DPKG" -eq 1 && -n "$SDDM_SERVICE_UNIT" ]]; then
    echo "==> systemd drop-in $SDDM_DROPIN ..."
    install -d "$SDDM_DROPIN_DIR"
    cat > "$SDDM_DROPIN" <<'EOF'
# Generated by install.sh (maya-hm / HM login).
# SDDM 0.21 (Debian 13 trixie, Ubuntu 26.04+): sddm.service starts before DRM/GPU init,
# the greeter crashes and the login display stays black (LP #2152106, sddm#1917).
# Wait for udev, as officially fixed in Ubuntu 24.04 (LP #2063143).
[Unit]
After=systemd-udev-settle.service
Wants=systemd-udev-settle.service
EOF
    systemctl daemon-reload 2>/dev/null || true
elif [[ "$DISTRO_DPKG" -eq 1 ]]; then
    echo "!! sddm.service not found - systemd drop-in skipped."
else
    echo "   (no systemd drop-in needed/expected on Fedora/RHEL.)"
fi

# --- 5c. Register SDDM as the active display manager ---------------------------
# Otherwise the previous DM (GDM/lightdm) keeps appearing after reboot, because
# graphical.target starts the service linked via
# /etc/systemd/system/display-manager.service. Additionally the SDDM 0.21
# sddm.service (Debian 13, Ubuntu 26) blocks its own
# start unless /etc/X11/default-display-manager is exactly "/usr/bin/sddm"
# (ExecStartPre safety check) -> "systemctl restart sddm" fails
# and the login display stays black.
echo "==> Enabling SDDM as the active display manager ..."
install -d "$DM_BACKUP_DIR"

# --- Debian/Ubuntu-specific: default-display-manager mechanics ---------------
# The Debian/Ubuntu sddm.service gates its start via an ExecStartPre safety check against
# /etc/X11/default-display-manager (must be exactly "/usr/bin/sddm"), otherwise
# "systemctl restart sddm" fails and the login display stays black.
# The systemd symlink /etc/systemd/system/display-manager.service also controls
# which DM graphical.target starts. Fedora/RHEL do not use this
# mechanism - there SDDM is enabled directly via systemctl enable.
if [[ "$DISTRO_HAS_DM_DEFAULT_FILE" -eq 1 ]]; then
    # back up previous state (for --uninstall)
    if [[ -e "$DM_DEFAULT_FILE" ]]; then
        cp -a "$DM_DEFAULT_FILE" "$DM_DEFAULT_BACKUP" 2>/dev/null || true
    fi
    if [[ -L "$DM_SERVICE_LINK" || -e "$DM_SERVICE_LINK" ]]; then
        prev_dm="$(readlink "$DM_SERVICE_LINK" 2>/dev/null || true)"
        if [[ -n "$prev_dm" && "$prev_dm" != */sddm.service ]]; then
            printf '%s\n' "$prev_dm" > "$DM_LINK_BACKUP"
        fi
    fi

    # important safety check of the Debian/Ubuntu sddm.service (must be exactly "/usr/bin/sddm"):
    printf '/usr/bin/sddm\n' > "$DM_DEFAULT_FILE"
fi

# disable other display managers so no DM conflict can black out
# the sddm greeter on the console
for dm in gdm gdm3 lightdm lxdm nodm xdm; do
    systemctl disable --quiet "$dm.service" 2>/dev/null || true
done

# display-manager.service -> sddm.service (Debian/Ubuntu only; systemctl enable
# creates the alias there; remove any existing one first or set it directly)
if [[ "$DISTRO_HAS_DM_DEFAULT_FILE" -eq 1 ]]; then
    rm -f "$DM_SERVICE_LINK"
    if ! systemctl enable --quiet sddm.service 2>/dev/null; then
        ln -sfn "${SDDM_SERVICE_UNIT:-/usr/lib/systemd/system/sddm.service}" "$DM_SERVICE_LINK"
    fi
else
    # Fedora/RHEL: enable SDDM directly as the graphical session
    systemctl enable --quiet sddm.service 2>/dev/null || true
fi
systemctl daemon-reload 2>/dev/null || true
if [[ "$DISTRO_HAS_DM_DEFAULT_FILE" -eq 1 ]]; then
    echo "==> SDDM is now the active display manager (default-display-manager=/usr/bin/sddm)."
else
    echo "==> SDDM is now enabled as display manager (systemctl enable sddm.service)."
fi

# --- 6. Session-account helpers (root scripts) --------------------------------------
echo "==> Installing session-account helpers ..."
install -d /usr/local/sbin
install -m 755 "$SESSION_SRC/oidc-session-account" "$SESSION_ACCOUNT"
install -m 755 "$SESSION_SRC/oidc-session-cleanup" "$SESSION_CLEANUP"
install -d /etc/oidc-login
# Central config was already freshly written from the template to
# /etc/oidc-login/oidc-login.conf before section 3c (overwritten).
install -m 644 "$CONFIG_SRC/oidc-config.sh" "$CONFIG_LOADER_SH"
install -m 644 "$CONFIG_SRC/oidc_config.py" "$CONFIG_LOADER_PY"
touch "$ACCOUNTS_FILE"
chmod 0600 "$ACCOUNTS_FILE"
# Print the version: on the target machine it is immediately verifiable which
# state is installed.
echo "    installed: $("$SESSION_ACCOUNT" version 2>/dev/null || echo 'unknown')"

# --- 6b. Firefox SSO helper ---------------
# Takes the SSO cookie spooled during the HM login into the user Firefox
# at session start, so HM pages are reachable on the desktop
# without another 2FA.
# The helper is a Python 3 script; without python3 autostart would
# silently do nothing - hence warn clearly here.
if ! command -v python3 >/dev/null 2>&1; then
    echo "WARNING: python3 missing - the Firefox SSO helper cannot run." >&2
    echo "         Please install python3; the HM login itself is unaffected" >&2
    echo "         (only the cookie handover to Firefox)." >&2
fi
# The spool lives in the session-account home (.cache/oidc-login/sso-cookies/):
# 'oidc-session-account create' writes it, this helper takes it over at
# session start into the user Firefox.
echo "==> Installing Firefox SSO helper ..."
install -m 755 "$SSO_SRC/oidc-sso-cookie" "$SSO_HELPER"
cat > "$SSO_AUTOSTART" <<EOF
[Desktop Entry]
Type=Application
Name=HM SSO cookie for Firefox
Comment=Takes the HM login SSO cookie into Firefox (no repeated 2FA)
Exec=$SSO_HELPER
Terminal=false
NoDisplay=true
X-GNOME-Autostart-enabled=true
EOF
chmod 644 "$SSO_AUTOSTART"
echo "    installed: $SSO_HELPER + $SSO_AUTOSTART"

# --- 6e. LRZ network drive (session helper, runs as user) ----------------
# Mounts the LRZ cloud storage (WebDAV https://webdisk.ads.mwn.de/hcwebdav
# as ADS\hm-<id>) at session start via Gio/GVFS (cloud-mount/).
# Fail-soft: offline/wrong password/no server -> no mount, but the session
# keeps running unchanged.
#
# The prerequisites are:
#   * gio             (libglib2.0-bin)               - Gio/GVFS client
#   * gvfs            (gvfs)                          - GVFS daemon
#   * DAV backend     (gvfs-backends / gvfs-client)   - WebDAV slave
#   * gvfsd-fuse      (gvfs-fuse)                     - provides the local path
#     /run/user/$UID/gvfs and only then the folder/symlink ~/Cloud-Storage
#   * Gio bindings    (python3-gi / python3-gobject)
# So 'sudo ./install.sh' suffices. If something is missing it gets installed here.
if [[ "$DISTRO_DNF" -eq 1 ]]; then
    CLOUD_PKGS=(gvfs gvfs-client gvfs-fuse python3-gobject)
else
    CLOUD_PKGS=(gvfs gvfs-backends gvfs-fuse python3-gi libglib2.0-bin)
fi

# Individual capability checks, so that we can install only the packages that are missing.
_cloud_has_gio()   { command -v gio >/dev/null 2>&1; }
_cloud_has_gi()    { python3 -c 'import gi' >/dev/null 2>&1; }
_cloud_has_dav()   { [[ -f /usr/share/gvfs/mounts/dav.mount ]]; }
_cloud_has_gvfsd_fuse() {
    command -v gvfsd-fuse >/dev/null 2>&1 && return 0
    # gvfsd-fuse is NOT in PATH - check paths individually. NO
    local _fuse
    for _fuse in /usr/libexec/gvfsd-fuse /usr/lib/gvfs/gvfsd-fuse \
                 /usr/lib/x86_64-linux-gnu/gvfs/gvfsd-fuse \
                 /usr/lib/x86_64-linux-gnu/libexec/gvfsd-fuse \
                 /usr/lib/aarch64-linux-gnu/gvfs/gvfsd-fuse; do
        [[ -x "$_fuse" ]] && return 0
    done
    # Fallback: somewhere under /usr/lib*.
    [[ -n "$(find /usr/libexec /usr/lib -maxdepth 4 -name gvfsd-fuse -type f 2>/dev/null | head -1)" ]] && return 0
    return 1
}
cloud_deps_ok() {
    _cloud_has_gio        || return 1
    _cloud_has_gi         || return 1
    _cloud_has_dav        || return 1
    _cloud_has_gvfsd_fuse || return 1
    return 0
}
# Prints the subset of CLOUD_PKGS that is missing
cloud_missing_pkgs() {
    local _p _miss=()
    for _p in "${CLOUD_PKGS[@]}"; do
        case "$_p" in
            gvfs)                        _cloud_has_gio        || _miss+=("$_p") ;;
            gvfs-client|gvfs-backends)   _cloud_has_dav        || _miss+=("$_p") ;;
            gvfs-fuse)                   _cloud_has_gvfsd_fuse || _miss+=("$_p") ;;
            python3-gobject|python3-gi)  _cloud_has_gi         || _miss+=("$_p") ;;
            libglib2.0-bin)              _cloud_has_gio        || _miss+=("$_p") ;;
            *)                           _miss+=("$_p") ;;
        esac
    done
    printf '%s\n' "${_miss[@]}"
}
if cloud_deps_ok; then
    echo "==> GVFS/FUSE for the LRZ network drive is present."
else
    # Install what the checks report as missing
    CLOUD_MISSING=()
    while IFS= read -r _p; do
        [[ -n "$_p" ]] && CLOUD_MISSING+=("$_p")
    done < <(cloud_missing_pkgs)
    # if the mapping fails to name the missing package,
    # fall back to the full list.
    [[ ${#CLOUD_MISSING[@]} -gt 0 ]] || CLOUD_MISSING=("${CLOUD_PKGS[@]}")
    echo "==> GVFS/FUSE for the LRZ network drive is missing - installing ${CLOUD_MISSING[*]} ..."
    pkg_install "${CLOUD_MISSING[@]}" \
        || die "could not install GVFS packages (${CLOUD_MISSING[*]})."
    if cloud_deps_ok; then
        echo "   GVFS/FUSE installed (local path /run/user/<uid>/gvfs via gvfsd-fuse)."
        echo "   Note: gvfsd-fuse starts with the session - log in again once before the first mount."
    else
        echo "WARNING: GVFS/FUSE still incomplete after installation." >&2
        echo "         The helper reports this again at login; check python3-gi/gvfs-fuse if needed." >&2
    fi
fi
unset CLOUD_MISSING _p 2>/dev/null || true
echo "==> Installing LRZ network-drive helper ..."
CLOUD_LINK_NAME="$(sed -n 's/^[[:space:]]*OIDC_CLOUD_LINK=//p' \
    "$CONFIG_FILE" 2>/dev/null | tail -1)"
CLOUD_LINK_NAME="${CLOUD_LINK_NAME:-Cloud-Storage}"
CLOUD_SYMLINK_ENABLED="$(sed -n 's/^[[:space:]]*OIDC_CLOUD_SYMLINK=//p' \
    "$CONFIG_FILE" 2>/dev/null | tail -1)"
CLOUD_SYMLINK_ENABLED="${CLOUD_SYMLINK_ENABLED,,}"
CLOUD_SYMLINK_ENABLED="${CLOUD_SYMLINK_ENABLED:-true}"
# Migration: remove the old ~/Cloud-Storage symlink into /run/user/$UID/gvfs when
# the symlink is switched off.
# A real file/dir of that name is never touched, and install.sh --uninstall
# does not touch user homes.
if [[ -n "$CLOUD_LINK_NAME" && "$CLOUD_SYMLINK_ENABLED" != "true" ]]; then
    _cloud_link_gone=0
    while IFS=: read -r _uname _x _uid _x2; do
        [[ -n "${_uid:-}" && "$_uid" -ge 1000 && "$_uid" -lt 60000 ]] || continue
        _home="$(getent passwd "$_uname" 2>/dev/null | cut -d: -f6)"
        [[ -n "${_home:-}" && -d "$_home" ]] || continue
        _link="$_home/$CLOUD_LINK_NAME"
        [[ -L "$_link" ]] || continue
        _target="$(readlink "$_link" 2>/dev/null || true)"
        case "$_target" in
            */.gvfs/*|*/run/user/*/gvfs/*)
                rm -f -- "$_link" && _cloud_link_gone=$((_cloud_link_gone + 1)) ;;
        esac
    done < <(getent passwd 2>/dev/null)
    [[ "$_cloud_link_gone" -gt 0 ]] \
        && echo "    removed $_cloud_link_gone old ~/$CLOUD_LINK_NAME symlink(s) (no home folder on this system)"
fi
install -m 755 "$CLOUD_SRC/oidc-cloud-mount" "$CLOUD_HELPER"
cat > "$CLOUD_AUTOSTART" <<EOF
[Desktop Entry]
Type=Application
Name=Connect LRZ network drive
Comment=Mounts the LRZ cloud storage (WebDAV) as a network drive (session keeps running without mount)
Exec=$CLOUD_HELPER
Terminal=false
NoDisplay=true
X-GNOME-Autostart-enabled=true
EOF
chmod 644 "$CLOUD_AUTOSTART"
echo "    installed: $CLOUD_HELPER + $CLOUD_AUTOSTART"

# --- 7. sudoers rules for greeter user 'sddm' ------------------------------------
echo "==> sudoers rules ($SUDOERS_FILE) ..."
cat > "$SUDOERS_FILE" <<EOF
# oidc-login / HM login – generated by install.sh
# Allows the greeter user sddm exclusively these two commands without password.
sddm ALL=(ALL) NOPASSWD: $SESSION_ACCOUNT
sddm ALL=(ALL) NOPASSWD: /opt/oidc-login/check-and-grant.py
EOF
chmod 440 "$SUDOERS_FILE"
visudo -c -f "$SUDOERS_FILE" >/dev/null 2>&1 || die "sudoers file invalid: $SUDOERS_FILE"

# --- 8. PAM hook for logout (deletion of the session account) --------------------------
# SDDM reports user sessions via different PAM services depending on the login
# path: normal password login ('sddm'), automatic login after the HM login
# ('sddm-autologin') and possibly the greeter service
# ('sddm-greeter').
# The structure is distro-dependent:
#   - Debian/Ubuntu: contains the marker "@include common-session".
#   - Fedora/RHEL: different structure (system-auth/systemd) without this marker.
pam_hook_line="session optional pam_exec.so $SESSION_CLEANUP"
for PAM_SDDM in /etc/pam.d/sddm /etc/pam.d/sddm-autologin /etc/pam.d/sddm-greeter; do
    if [[ ! -f "$PAM_SDDM" ]]; then
        continue
    fi
    if grep -q oidc-session-cleanup "$PAM_SDDM" 2>/dev/null; then
        echo "    PAM hook in $PAM_SDDM already present."
        continue
    fi
    echo "==> Adding PAM hook to $PAM_SDDM ..."
    if grep -q "@include common-session" "$PAM_SDDM" 2>/dev/null; then
        # Debian/Ubuntu PAM layout: insert new rule directly after the marker.
        sed -i "/@include common-session/a $pam_hook_line" "$PAM_SDDM"
    else
        printf "%s\n" "$pam_hook_line" >> "$PAM_SDDM"
    fi
done
if [[ ! -f /etc/pam.d/sddm ]]; then
    echo "!! /etc/pam.d/sddm missing (sddm package incomplete?) - PAM hook skipped."
fi

# --- 9. Account cleanup at greeter start (Xsetup) -----------------------------------
# Xsetup runs every time SDDM starts a display server for the greeter, i.e. at
# boot AND after every logout. Persistent accounts
# (OIDC_SESSION_TEMPORARY=false) survive it, because cleanup-all defaults to
# mode 'auto'; install.sh --uninstall uses 'cleanup-all --force' instead.
if [[ ! -f "$XSETUP" ]]; then
    echo "!! $XSETUP missing - creating it (sddm package without script directory)."
    install -d "$(dirname "$XSETUP")"
    printf '#!/bin/sh\n' > "$XSETUP"
    chmod +x "$XSETUP"
fi
if ! grep -q 'oidc-session-account cleanup-all' "$XSETUP" 2>/dev/null; then
    echo "==> Adding Xsetup cleanup ..."
    cat >> "$XSETUP" <<'EOF'

# --- HM login (oidc-login): clean up session accounts at greeter start ---
/usr/local/sbin/oidc-session-account cleanup-all || true
EOF
fi

# --- 9b. Keep the greeter display awake (Xsetup) -----------------------------------
# X's own screen saver blanks the greeter after ~10 minutes and DPM offs the
# monitor. The wake-up key/click is consumed by X, so the login appears as a
# black screen with no password prompt. Two layers fix this:
#   a) [X11] ServerArguments in $SDDM_CONF: -s 0 (no screen saver/blanking),
#      DPMS is switched off per greeter start by (b) below
#   b) this Xsetup block: belt and braces, also re-applied on every greeter
#      start (e.g. after a session changed the values).
# Xsetup runs as root with DISPLAY and XAUTHORITY already set by SDDM,
# so xset talks to the greeter's X server.
if ! grep -q 'greeter display stays awake' "$XSETUP" 2>/dev/null; then
    echo "==> Adding Xsetup 'keep greeter display awake' ..."
    cat >> "$XSETUP" <<'EOF'

# --- HM login (oidc-login): greeter display stays awake (no blanking/DPMS) ---
# Otherwise the login screen goes black after ~10 min without a reachable
# password prompt. The theme's lock screen (lockAfterSeconds) dims instead.
if command -v xset >/dev/null 2>&1; then
    xset s off     2>/dev/null || true
    xset s noblank 2>/dev/null || true
    xset -dpms     2>/dev/null || true
fi
EOF
else
    echo "    Xsetup 'keep greeter display awake' already present."
fi

# --- 9c. Wake the greeter display after resume/suspend -----------------------------
# On resume from suspend the panel often stays off (DPM off) while the greeter
# is the only thing on screen -> black login screen that looks frozen. This
# system-sleep hook forces the output back on. It is
#   - silent,
#   - fail-soft,
#   - only active on 'post' (resume), never on 'pre'.
SLEEP_HOOK_DIR="/usr/lib/systemd/system-sleep"
SLEEP_HOOK="$SLEEP_HOOK_DIR/oidc-greeter-resume"
echo "==> Installing resume hook $SLEEP_HOOK ..."
install -d "$SLEEP_HOOK_DIR"
cat > "$SLEEP_HOOK" <<'EOF'
#!/bin/sh
# Generated by install.sh (maya-hm / HM login): switch the greeter display back
# on after resume. Without this the login screen stays black after suspend.
# Silent by design, always exits 0.
[ "$1" = "post" ] || exit 0
command -v xset >/dev/null 2>&1 || exit 0
for _auth in /run/sddm/xauth_*; do
    [ -f "$_auth" ] || continue
    DISPLAY=:0 XAUTHORITY="$_auth" xset dpms force on >/dev/null 2>&1 || true
    DISPLAY=:0 XAUTHORITY="$_auth" xset s reset      >/dev/null 2>&1 || true
    DISPLAY=:0 XAUTHORITY="$_auth" xset s off        >/dev/null 2>&1 || true
    DISPLAY=:0 XAUTHORITY="$_auth" xset -dpms        >/dev/null 2>&1 || true
done
exit 0
EOF
chmod 755 "$SLEEP_HOOK"

# --- 10. Suspend (sleep) must not kill the machine --------------------------------
# The session power manager suspends the machine after idle minutes. On a VM that is fatal.
# Blocking happens in two independent layers:
#   a) mask sleep.target/suspend.target/hibernate.target/hybrid-sleep.target
#      -> any suspend request (logind, power manager, user) fails cleanly
#   b) /etc/systemd/logind.conf.d/60-oidc-no-suspend.conf: IdleAction=ignore
#      + HandleLidSwitch*/HandleSuspendKey/HandleHibernateKey=ignore
#      -> logind never suspends on its own
#   c) system-wide XFCE default inactivity-on-ac/battery=0 (new sessions)
#   d) the same value rewritten in EVERY existing user's XFCE profile: a
#      user's own profile wins over the system default, and 'inactivity=16'
#      there is what made the power manager call logind after 16 minutes -
#      logind's reply "GDBus.Error:...AccessDenied: Permission denied" is then
#      shown by the desktop as an error window. (c)+(d) remove that trigger.
SUSPEND_MARKER="/etc/oidc-login/suspend-masked"
SUSPEND_UNIT_DIR="/etc/systemd/system"
LOGIND_DROPIN_DIR="/etc/systemd/logind.conf.d"
LOGIND_DROPIN="$LOGIND_DROPIN_DIR/60-oidc-no-suspend.conf"
XFCE_PM_DIR="/etc/xdg/xfce4/xfconf/xfce-perchannel-xml"
XFCE_PM_FILE="$XFCE_PM_DIR/xfce4-power-manager.xml"
SLEEP_TARGETS=(sleep.target suspend.target hibernate.target hybrid-sleep.target)

# Writes/replaces one uint property inside a power-manager channel file.
#   _xfce_pm_set_in <file> <property> <value>
_xfce_pm_set_in() {
    local _name="$2" _val="$3" _line _tmp
    local _file="${1:-$XFCE_PM_FILE}"
    _line="    <property name=\"$_name\" type=\"uint\" value=\"$_val\"/>"
    if [[ ! -f "$_file" ]]; then
        install -d "$(dirname "$_file")"
        cat > "$_file" <<'XML'
<?xml version="1.0" encoding="UTF-8"?>

<channel name="xfce4-power-manager" version="1.0">
  <property name="xfce4-power-manager" type="empty">
  </property>
</channel>
XML
    fi
    # copy + modify + replace: sed -i keeps the file usable if we bail out
    _tmp="$(mktemp)"
    cp -a "$_file" "$_tmp"
    if grep -q "name=\"$_name\"" "$_tmp"; then
        sed -i "s#<property name=\"$_name\"[^/]*/>#${_line//#/\\#}#" "$_tmp"
    elif grep -q '<property name="xfce4-power-manager" type="empty">' "$_tmp"; then
        sed -i "/<property name=\"xfce4-power-manager\" type=\"empty\">/a\\
${_line//#/\\#}" "$_tmp"
    else
        sed -i "/<\/channel>/i\\
$(_printf '%s' "$_line" | sed 's/[#&]/\\&/g')" "$_tmp"
    fi
    install -m 644 "$_tmp" "$_file"
    rm -f "$_tmp"
}
# System-wide default (new sessions).
_xfce_pm_set() { _xfce_pm_set_in "$XFCE_PM_FILE" "$1" "$2"; }

_oidc_suspend_mode="$(sed -n -e 's/^[[:space:]]*OIDC_DISABLE_SUSPEND[[:space:]]*=[[:space:]]*//p' "$CONFIG_FILE" 2>/dev/null | tail -n 1)"
_oidc_suspend_mode="${_oidc_suspend_mode%$'\r'}"
_oidc_suspend_mode="${_oidc_suspend_mode,,}"
case "$_oidc_suspend_mode" in
    "true"|"1"|"yes") _oidc_block_suspend=1 ;;
    "false"|"0"|"no") _oidc_block_suspend=0 ;;
    *)  # auto (default): only inside a VM - a VM suspend cannot be resumed
        _oidc_block_suspend=0
        if command -v systemd-detect-virt >/dev/null 2>&1; then
            if [[ "$(systemd-detect-virt 2>/dev/null)" != "none" ]]; then
                _oidc_block_suspend=1
            fi
        fi ;;
esac

if [[ "$_oidc_block_suspend" -eq 1 ]]; then
    _virt="unknown"
    command -v systemd-detect-virt >/dev/null 2>&1 && _virt="$(systemd-detect-virt 2>/dev/null)"
    echo "==> Blocking system suspend (mode=${_oidc_suspend_mode:-auto}, virt=$_virt) ..."
    # (a) Mask the sleep targets: every suspend/hibernate request then fails
    #     immediately with "AccessDenied" instead of freezing the guest.
    #     (An empty no-op target was tried as well, but logind then stays in a
    #     fake "sleeping" state and refuses further requests with "There's
    #     already a shutdown or sleep operation in progress" - worse.)
    #     Migration: an intermediate version wrote no-op unit files here.
    install -d "$SUSPEND_UNIT_DIR"
    for _t in "${SLEEP_TARGETS[@]}"; do
        _f="$SUSPEND_UNIT_DIR/$_t"
        if [[ -f "$_f" ]] && grep -q 'oidc-login' "$_f" 2>/dev/null; then
            rm -f "$_f"
        fi
    done
    : > "$SUSPEND_MARKER"
    for _t in "${SLEEP_TARGETS[@]}"; do
        # NOTE: static targets also succeed with 'is-enabled --quiet', so the
        # state STRING is compared - otherwise nothing is recorded and
        # --uninstall could not restore the original state.
        _state="$(systemctl is-enabled "$_t" 2>/dev/null || true)"
        [[ "$_state" == "masked" ]] || printf '%s\n' "$_t" >> "$SUSPEND_MARKER"
    done
    systemctl mask --quiet "${SLEEP_TARGETS[@]}" 2>/dev/null \
        || echo "!! could not mask the sleep targets."
    # (b) logind: never suspend because of idleness, lid or a special key
    install -d "$LOGIND_DROPIN_DIR"
    cat > "$LOGIND_DROPIN" <<'EOF'
# Generated by install.sh (maya-hm / HM login).
# A suspended VM cannot be woken from inside the guest: black screen and no
# input at all (not even Ctrl+Alt+F3). Therefore logind never suspends by
# itself. Remove this file (or run install.sh --uninstall) to restore.
# (Unknown keys are ignored with a warning by older systemd versions.)
[Login]
IdleAction=ignore
HandleLidSwitch=ignore
HandleLidSwitchDocked=ignore
HandleLidSwitchExternalPower=ignore
HandleSuspendKey=ignore
HandleHibernateKey=ignore
EOF
    # NOTE: logind is NOT restarted - that would kill live greeter/session PAM
    # sessions (SDDM then stacks up a new display + VT for each of them).
    # IdleAction defaults to 'ignore' anyway; the drop-in applies from the next
    # start, and the masked sleep targets already make suspend harmless now.
    # (c) system-wide XFCE default: no suspend on idle for new sessions
    if command -v xfconf-query >/dev/null 2>&1 || [[ -d /etc/xdg/xfce4 ]]; then
        _xfce_pm_set "inactivity-on-ac"      "0"
        _xfce_pm_set "inactivity-on-battery" "0"
        echo "    XFCE default: inactivity-on-ac/battery=0 ($XFCE_PM_FILE)"
    fi
    echo "    sleep targets masked (a suspend request is refused, not hung);"
    echo "    idle suspend is switched off for all users below."
    # (d) Persistent per-user profiles: a user's OWN XFCE profile wins over the
    #     system default, so 'inactivity-on-ac=16' has to be rewritten in every
    #     home - otherwise the power manager asks logind to suspend after 16
    #     minutes again (this is what produced the "GDBusError ...
    #     AccessDenied: Permission denied" window on the desktop).
    while IFS=: read -r _uname _x _uid _x; do
        [[ -n "${_uid:-}" && "$_uid" -ge 1000 && "$_uid" -lt 60000 ]] || continue
        _home="$(getent passwd "$_uname" 2>/dev/null | cut -d: -f6)"
        [[ -n "$_home" && -d "$_home" ]] || continue
        _pm="$_home/.config/xfce4/xfconf/xfce-perchannel-xml/xfce4-power-manager.xml"
        [[ -f "$_pm" ]] || continue
        _xfce_pm_set_in "$_pm" "inactivity-on-ac"      "0"
        _xfce_pm_set_in "$_pm" "inactivity-on-battery" "0"
        chown "$_uid:$(id -gn "$_uname" 2>/dev/null || echo "$_uid")" "$_pm" 2>/dev/null || true
        echo "    $_uname: inactivity-on-ac/battery=0 ($_pm)"
    done < <(getent passwd 2>/dev/null)
    # (e) Neutralise the value in RUNNING sessions as well (xfconfd caches the
    #     old value in memory and would write it back to disk otherwise).
    if command -v xfconf-query >/dev/null 2>&1 && command -v loginctl >/dev/null 2>&1; then
        while read -r _sid _uid _user _rest; do
            [[ -n "${_sid:-}" && -n "${_uid:-}" ]] || continue
            _stype="$(loginctl show-session "$_sid" -p Type --value 2>/dev/null || true)"
            case "$_stype" in x11|wayland) ;; *) continue ;; esac
            _bus="/run/user/$_uid/bus"
            [[ -S "$_bus" ]] || continue
            _disp="$(loginctl show-session "$_sid" -p Display --value 2>/dev/null || true)"
            [[ -n "$_disp" ]] || _disp=":0"
            _changed=0
            for _prop in inactivity-on-ac inactivity-on-battery; do
                # --create: a profile may not carry the key yet (xfconf-query
                # refuses to set a non-existing property without it).
                runuser -u "$_user" -- env "DISPLAY=$_disp" \
                    "DBUS_SESSION_BUS_ADDRESS=unix:path=$_bus" \
                    xfconf-query -c xfce4-power-manager \
                    -p "/xfce4-power-manager/$_prop" --create -t uint -s 0 \
                    >/dev/null 2>&1 || true
                # verify instead of trusting the exit code (xfconfd may run in
                # another session/bus and silently keep the old value)
                _pval="$(runuser -u "$_user" -- env "DISPLAY=$_disp" \
                    "DBUS_SESSION_BUS_ADDRESS=unix:path=$_bus" \
                    xfconf-query -c xfce4-power-manager \
                    -p "/xfce4-power-manager/$_prop" 2>/dev/null || true)"
                [[ "$_pval" == "0" ]] && _changed=1
            done
            [[ "$_changed" -eq 1 ]] && echo "    running session $_sid ($_user): idle suspend off"
        done < <(loginctl list-sessions --no-legend 2>/dev/null || true)
    fi
else
    echo "==> Suspend left untouched (mode=${_oidc_suspend_mode:-auto}) ..."
    # undo a previous run so a changed setting really takes effect: undoes the
    # mask we set (and removes a no-op unit file from an intermediate version)
    if [[ -f "$SUSPEND_MARKER" ]]; then
        _restore_list=()
        while read -r _t; do
            [[ -n "$_t" ]] && _restore_list+=("$_t")
        done < "$SUSPEND_MARKER"
        rm -f "$SUSPEND_MARKER"
    elif [[ -f "$LOGIND_DROPIN" ]]; then
        # marker lost, but our logind drop-in is still there -> the mask is
        # ours; the targets are 'static' by default, so unmasking is safe.
        _restore_list=("${SLEEP_TARGETS[@]}")
    else
        _restore_list=()
    fi
    for _t in ${_restore_list[@]+"${_restore_list[@]}"}; do
        rm -f "/etc/systemd/system/$_t"
        systemctl unmask --quiet "$_t" 2>/dev/null || true
    done
    [[ ${#_restore_list[@]} -eq 0 ]] || systemctl daemon-reload 2>/dev/null || true
    unset _restore_list
    rm -f "$LOGIND_DROPIN"
    if [[ -f "$XFCE_PM_FILE" ]] && grep -q 'name="inactivity-on-ac"' "$XFCE_PM_FILE"; then
        sed -i '/name="inactivity-on-ac"/d;/name="inactivity-on-battery"/d' "$XFCE_PM_FILE" 2>/dev/null || true
    fi
    # no logind restart here either (see above): the unit change is immediate.
fi
unset _oidc_suspend_mode _oidc_block_suspend _virt _t _f _state _name _val \
      _sid _uid _user _rest _stype _bus _disp _changed _prop _pval \
      _uname _x _home _pm 2>/dev/null || true

echo
echo "Done. The '$THEME_NAME' theme appears on the next SDDM start."
echo
echo "Notes:"
echo "  - Configuration: $THEME_DEST/theme.conf"
echo "  - Uninstall: sudo $0 --uninstall"
if [[ -f "$SUSPEND_MARKER" ]]; then
    echo "  - System suspend is BLOCKED (VM): a suspended guest cannot be woken,"
    echo "    the screen would stay black with no input at all. Change with"
    echo "    OIDC_DISABLE_SUSPEND in $CONFIG_FILE (auto/true/false)."
fi
if [[ "$DISTRO_DPKG" -eq 1 ]]; then
    echo "  - Debian 13 / Ubuntu 25.10+/26.04, black login display (SDDM 0.21): the systemd drop-in"
    echo "    '$SDDM_DROPIN' waits for GPU/DRM init (LP #2152106)."
fi
echo "    Further diagnosis: journalctl -u sddm -b | grep -i -E 'greeter|tty|error'"
echo "  - SDDM is now the active display manager; after the next reboot the"
echo "    '$THEME_NAME' login appears."
echo "  - If Xorg was missing, it was installed incl. input/video drivers"