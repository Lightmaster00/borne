cmake_minimum_required(VERSION 3.16)
project(borne_ui LANGUAGES CXX)
set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_AUTOMOC ON)
find_package(Qt6 REQUIRED COMPONENTS Gui Qml Quick)

if(APPLE)
  # macOS: Borne.app application. The main executable is then replaced by the core
  # (scripts/package-macos.sh), which launches borne-ui from Contents/MacOS.
  set(MACOSX_BUNDLE_BUNDLE_NAME "Borne")
  set(MACOSX_BUNDLE_GUI_IDENTIFIER "io.github.lightmaster00.borne")
  set(MACOSX_BUNDLE_BUNDLE_VERSION "0.2.0")
  set(MACOSX_BUNDLE_SHORT_VERSION_STRING "0.2.0")
  add_executable(borne-ui MACOSX_BUNDLE main.cpp)
  set_target_properties(borne-ui PROPERTIES OUTPUT_NAME "Borne")
elseif(WIN32)
  # Windows: a windowed executable (the core has no console either); there is no rpath on
  # Windows, windeployqt places the Qt libraries next to the executable
  # (scripts/package-windows.sh) and the icon is embedded.
  add_executable(borne-ui WIN32 main.cpp)
  set_target_properties(borne-ui PROPERTIES WIN32_ICON "${CMAKE_SOURCE_DIR}/../resources/borne.ico")
else()
  add_executable(borne-ui main.cpp)
  # Bundled Qt libraries live in <package>/lib
  set_target_properties(borne-ui PROPERTIES
    BUILD_RPATH "\$ORIGIN/../lib"
    INSTALL_RPATH "\$ORIGIN/../lib"
    SKIP_BUILD_RPATH OFF
    BUILD_WITH_INSTALL_RPATH ON)
endif()
target_link_libraries(borne-ui PRIVATE Qt6::Gui Qt6::Qml Qt6::Quick)
if(APPLE)
  # Escape caught while a game runs (main.cpp, QuitKey).
  target_link_libraries(borne-ui PRIVATE "-framework Carbon")
endif()
