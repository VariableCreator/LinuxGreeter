# OIDC-Login

Web browser application that looks for a certain cookie. Once it is found, it calls another application with the cookie value.

This is used to do a login via OIDC against "https://login.cs.hm.edu/labaccess". Once that is successful, a Python script is called with the OIDC session cookie value. That other script (not part of this repository) attempts to access a protected resource with that cookie value to validate the cookie to prove a successful login and then take authorized actions. 

All this is used for Linux network boot in FK07 labs: full network access and root privileges are only granted after successful login. 

## Getting started

Created with Qt Creator in C++.

Configuration lives in the central config file
(`/etc/oidc-login/oidc-login.conf`, template: `config/oidc-login.conf`).
The code itself carries no default values for those keys.

### Compilation

```
  # Debian 13 / Ubuntu (apt)
  apt install build-essential cmake pkg-config qt6-base-dev qt6-webengine-dev qt6-webchannel-dev \
              qt6-tools-dev qt6-l10n-tools libxkbfile-dev libxkbcommon-dev xkb-data

  # Fedora (dnf)
  sudo dnf install gcc-c++ cmake pkgconfig \
                   qt6-qtbase-devel qt6-qtdeclarative-devel \
                   qt6-qtwebengine-devel qt6-qtwebchannel-devel qt6-qttools-devel \
                   libxkbfile-devel libxkbcommon-devel

  su henri -
  cd <projectdir>
  cmake -S src -B build
  cmake --build build
```

Note that the application can only run on another system if the required Qt libraries are installed in the correct version.

## License

GPL 3 licensed.
