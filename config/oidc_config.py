#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Shared loader for the central oidc-login config.

Usage:
    from oidc_config import load_config
    load_config()  # fills os.environ for unset OIDC_* keys

Search order:
  1. $OIDC_CONFIG (explicit file, mainly for tests)
  2. /etc/oidc-login/oidc-login.conf (installed; only production source)

The config file is the single source of truth: the helpers do not carry
duplicate default values for the keys defined there.

Rules: flat KEY=VALUE, `#` comment, quotes stripped.
An already-set environment variable ALWAYS wins (env > file).
"""
import os

# Installed config path.
# The loader runs from /etc/oidc-login after install.sh deployed it.
CONFIG_PATH = "/etc/oidc-login/oidc-login.conf"

_LOADED = {}


# Parse one flat KEY=VALUE config file into a dict (no env interaction).
# Skips blanks/comments/non-KEY=VALUE lines, strips whitespace and matching
# single/double quotes, last occurrence of a key wins. Missing/unreadable
# file yields {} instead of raising, so callers stay fail-soft.
def _parse_file(path):
    values = {}
    try:
        with open(path, encoding="utf-8") as f:
            for raw in f:
                line = raw.strip()
                if not line or line.startswith("#") or "=" not in line:
                    continue
                key, _, val = line.partition("=")
                key = key.strip()
                val = val.strip()
                if (len(val) >= 2 and val[0] == val[-1]
                        and val[0] in ("'", '"')):
                    val = val[1:-1]
                if not key or not key.replace("_", "").isalnum():
                    continue
                values[key] = val
    except OSError:
        pass
    return values


# Locate the effective config file: explicit arg > $OIDC_CONFIG env >
# installed path (CONFIG_PATH).
# Returns the first existing path, or "" when none exists (callers treat
# "" as "no config", env-only mode).
def find_config(explicit=None):
    cands = []
    if explicit:
        cands.append(explicit)
    env = os.environ.get("OIDC_CONFIG")
    if env:
        cands.append(env)
    cands.append(CONFIG_PATH)
    for path in cands:
        if path and os.path.isfile(path):
            return path
    return ""


# Load the central config once per path (cached in _LOADED) and export it
# as os.environ defaults: only keys NOT already in the environment are set,
# so pre-set (even empty) OIDC_* test overrides always win. Returns the used
# path, or "" when no config file was found.
def load_config(path=None):
    """Read central config; set os.environ defaults for missing keys.

    env wins: a key already present in os.environ (even empty) is left
    untouched so test overrides keep working.
    """
    global _LOADED
    cfg = find_config(path)
    if not cfg:
        return ""
    if cfg in _LOADED:
        values = _LOADED[cfg]
    else:
        values = _parse_file(cfg)
        _LOADED[cfg] = values
    for key, val in values.items():
        if key not in os.environ:
            os.environ[key] = val
    return cfg
