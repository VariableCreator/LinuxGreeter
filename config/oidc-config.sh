#!/bin/sh
# oidc-config.sh – shared loader for all bash helpers.
# Sourced (not executed):  . /etc/oidc-login/oidc-config.sh
# Provides: oidc_load_config [explicit-file]
#
# Search order for the config file:
#   1. $OIDC_CONFIG (explicit override, tests)
#   2. /etc/oidc-login/oidc-login.conf (installed system; only production source)
#
# Rules: flat KEY=VALUE, `#` comment, quotes stripped.
# An already-exported/set variable ALWAYS wins (env > config file),
# so OIDC_* overrides for tests keep working.
# No secrets are stored in the config – only paths/URLs/names/timeouts.

oidc_load_config() {
    _oidc_cfg="${1:-${OIDC_CONFIG:-}}"
    if [ -z "$_oidc_cfg" ] && [ -f /etc/oidc-login/oidc-login.conf ]; then
        _oidc_cfg=/etc/oidc-login/oidc-login.conf
    fi
    [ -n "$_oidc_cfg" ] && [ -f "$_oidc_cfg" ] || return 0
    OIDC_LOADED_CONFIG="$_oidc_cfg"
    while IFS= read -r _oidc_line || [ -n "$_oidc_line" ]; do
        # strip leading/trailing whitespace
        _oidc_line="$(printf '%s' "$_oidc_line" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
        case "$_oidc_line" in
            ''|\#*) continue ;;
        esac
        case "$_oidc_line" in
            *=*) ;;
            *) continue ;;
        esac
        _oidc_key="${_oidc_line%%=*}"
        _oidc_val="${_oidc_line#*=}"
        _oidc_key="$(printf '%s' "$_oidc_key" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
        _oidc_val="$(printf '%s' "$_oidc_val" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
        # strip matching single/double quotes
        case "$_oidc_val" in
            \"*\") _oidc_val="$(printf '%s' "$_oidc_val" | sed -e 's/^"//' -e 's/"$//')" ;;
            \'*\') _oidc_val="$(printf '%s' "$_oidc_val" | sed -e "s/^'//" -e "s/'\$//")" ;;
        esac
        case "$_oidc_key" in
            ''|*[!A-Za-z0-9_]*) continue ;;
        esac
        # env wins: only set when the variable is UNSET (even an exported
        # empty value counts as set). Probe via ${var+x} so that an
        # exported-but-empty override is NOT clobbered by the file.
        # shellcheck disable=SC2086
        eval "_oidc_isset=\${$_oidc_key+x}"
        if [ -z "${_oidc_isset:-}" ]; then
            # assign safely (value may contain spaces/backslashes)
            _oidc_esc="$(printf '%s' "$_oidc_val" | sed -e "s/'/'\\\\''/g")"
            eval "$_oidc_key='$_oidc_esc'"
        fi
    done < "$_oidc_cfg"
    unset _oidc_cfg _oidc_line _oidc_key _oidc_val _oidc_isset _oidc_esc
    return 0
}
