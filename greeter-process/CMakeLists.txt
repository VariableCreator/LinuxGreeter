cmake_minimum_required(VERSION 3.16)

project(greeter-process VERSION 1.0 LANGUAGES CXX)

include(GNUInstallDirs)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

# Needed so that "moc" can find the class headers for AUTOMOC
set(CMAKE_AUTOMOC ON)
set(CMAKE_INCLUDE_CURRENT_DIR ON)

# --- Qt major version selection (5 or 6) --------------------------------------
# The greeter process of the SDDM used by Ubuntu 24.04 and older is built against
# Qt5, while newer releases (>= 25.10 / Ubuntu 26) use a Qt6 greeter. A QML
# extension plugin must be compiled against exactly the Qt major version of the
# greeter that loads it. Default to Qt5 to keep the previous behaviour when the
# variable is not passed; install.sh auto-detects and passes -DQT_VERSION_MAJOR.
set(QT_VERSION_MAJOR "5" CACHE STRING "Qt major version to build the greeter plugin against (5 or 6)")
if(NOT QT_VERSION_MAJOR MATCHES "^[56]$")
    message(FATAL_ERROR "QT_VERSION_MAJOR must be 5 or 6, got '${QT_VERSION_MAJOR}'")
endif()

# The plugin is installed into the matching Qt QML import path where
# the greeter automatically looks for QML modules.
find_package(QT NAMES Qt${QT_VERSION_MAJOR} REQUIRED COMPONENTS Core Qml)
find_package(Qt${QT_VERSION_MAJOR} 5.12 REQUIRED COMPONENTS Core Qml)

set(QML_MODULE_NAME GreeterProcess)
set(QML_MODULE_BUILD_DIR "${CMAKE_BINARY_DIR}/${QML_MODULE_NAME}")
# Debian/Ubuntu layout (from qmake -query QT_INSTALL_QML)
set(QML_MODULE_INSTALL_DIR "${CMAKE_INSTALL_LIBDIR}/qt${QT_VERSION_MAJOR}/qml/${QML_MODULE_NAME}")

add_library(greeterprocess MODULE
    plugin.cpp
    plugin.h
    process.cpp
    process.h
)

target_link_libraries(greeterprocess PRIVATE
    Qt${QT_VERSION_MAJOR}::Core
    Qt${QT_VERSION_MAJOR}::Qml
)

set_target_properties(greeterprocess PROPERTIES
    LIBRARY_OUTPUT_DIRECTORY "${QML_MODULE_BUILD_DIR}"
    PREFIX "lib"
)

# qmldir next to the shared library so the module is self contained and can be
# tested directly from the build tree (QML2_IMPORT_PATH=.../build).
configure_file(qmldir.in "${QML_MODULE_BUILD_DIR}/qmldir" COPYONLY)

install(TARGETS greeterprocess
    LIBRARY DESTINATION "${QML_MODULE_INSTALL_DIR}"
)
install(FILES "${QML_MODULE_BUILD_DIR}/qmldir"
    DESTINATION "${QML_MODULE_INSTALL_DIR}"
)