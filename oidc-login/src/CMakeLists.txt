cmake_minimum_required(VERSION 3.18)

project(oidc-login VERSION 0.1 LANGUAGES CXX)

set(CMAKE_AUTOUIC ON)
set(CMAKE_AUTOMOC ON)
set(CMAKE_AUTORCC ON)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

find_package(QT NAMES Qt6 REQUIRED COMPONENTS Widgets LinguistTools)
find_package(Qt${QT_VERSION_MAJOR} REQUIRED COMPONENTS Widgets LinguistTools WebChannel)
find_package(Qt${QT_VERSION_MAJOR} REQUIRED COMPONENTS WebEngineWidgets)

set(PROJECT_SOURCES
        main.cpp
        mainwindow.cpp
        mainwindow.h
        oidc_config.h
        mainwindow.ui
        credentialbridge.cpp
        credentialbridge.h
        res.qrc
        ${TS_FILES}
)

qt_standard_project_setup(I18N_TRANSLATED_LANGUAGES de_DE)  # added 2025-03-22

if(${QT_VERSION_MAJOR} GREATER_EQUAL 6)
    qt_add_executable(oidc-login
        MANUAL_FINALIZATION
        ${PROJECT_SOURCES}
    )
# Define target properties for Android with Qt 6 as:
#    set_property(TARGET oidc-login APPEND PROPERTY QT_ANDROID_PACKAGE_SOURCE_DIR
#                 ${CMAKE_CURRENT_SOURCE_DIR}/android)
# For more information, see https://doc.qt.io/qt-6/qt-add-executable.html#target-creation

    qt_create_translation(QM_FILES ${CMAKE_SOURCE_DIR} ${TS_FILES})
endif()

qt_add_translations(oidc-login)  # added 2025-03-22

target_link_libraries(oidc-login PRIVATE Qt${QT_VERSION_MAJOR}::Core)  # added 2025-04-10 (no effect)
target_link_libraries(oidc-login PRIVATE Qt${QT_VERSION_MAJOR}::Widgets)
target_link_libraries(oidc-login PRIVATE Qt${QT_VERSION_MAJOR}::WebEngineWidgets)
target_link_libraries(oidc-login PRIVATE Qt${QT_VERSION_MAJOR}::WebChannel)

set_target_properties(oidc-login PROPERTIES
    MACOSX_BUNDLE_GUI_IDENTIFIER my.example.com
    MACOSX_BUNDLE_BUNDLE_VERSION ${PROJECT_VERSION}
    MACOSX_BUNDLE_SHORT_VERSION_STRING ${PROJECT_VERSION_MAJOR}.${PROJECT_VERSION_MINOR}
    MACOSX_BUNDLE TRUE
    WIN32_EXECUTABLE TRUE
)

install(TARGETS oidc-login
    BUNDLE DESTINATION .
    LIBRARY DESTINATION ${CMAKE_INSTALL_LIBDIR}
)

if(QT_VERSION_MAJOR EQUAL 6)
    qt_finalize_executable(oidc-login)
endif()

# The following added 2025-04-06
set(CPACK_PACKAGE_NAME "oidc-login")
set(CPACK_PACKAGE_VERSION "1.0.0")
set(CPACK_PACKAGE_CONTACT "dirk.henrici+oidc-login@hm.edu")
set(CPACK_PACKAGE_DESCRIPTION_SUMMARY "Web browser tailored to digital Moodle exams at Hochschule München.")
set(CPACK_PACKAGE_VENDOR "HM Hochschule München University of Applied Sciences")
set(CPACK_DEBIAN_PACKAGE_MAINTAINER "Dirk Henrici <dirk.henrici+oidc-login@hm.edu>")
set(CPACK_PACKAGE_LICENSE "GPL-3.0-only")
set(CPACK_DEBIAN_PACKAGE_HOMEPAGE "https://gitlab.lrz.de/hm/fk07-technik/oidc-login")
set(CPACK_PACKAGE_FILE_NAME "${CPACK_PACKAGE_NAME}-${CPACK_PACKAGE_VERSION}")
set(CPACK_DEBIAN_PACKAGE_DEPENDS "libqt6webenginecore6, libqt6webenginewidgets6")
install(TARGETS oidc-login RUNTIME DESTINATION bin)
include(CPack)
