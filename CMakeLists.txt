cmake_minimum_required(VERSION 3.20)
project(OpenClawMobile VERSION 0.8.0 LANGUAGES CXX)
set(CMAKE_CXX_STANDARD 20)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

find_package(OpenSSL REQUIRED)
find_package(Threads REQUIRED)

add_library(openclaw_core
  core/src/core.cpp
  core/src/gateway_protocol.cpp
  core/src/device_identity.cpp
  core/src/gateway_client.cpp
  core/src/recovery.cpp)
target_include_directories(openclaw_core PUBLIC core/include)
target_compile_definitions(openclaw_core PUBLIC BOOST_ERROR_CODE_HEADER_ONLY)
target_link_libraries(openclaw_core PUBLIC OpenSSL::Crypto OpenSSL::SSL Threads::Threads)

add_executable(openclaw-mobile cli/main.cpp)
target_link_libraries(openclaw-mobile PRIVATE openclaw_core)

option(OPENCLAW_BUILD_GUI "Build the lightweight FLTK desktop GUI" ON)
if(OPENCLAW_BUILD_GUI)
  find_package(FLTK QUIET)
  if(FLTK_FOUND)
    add_executable(openclaw-gui gui/main.cpp)
    target_include_directories(openclaw-gui PRIVATE ${FLTK_INCLUDE_DIR})
    target_link_libraries(openclaw-gui PRIVATE openclaw_core ${FLTK_LIBRARIES})
    if(WIN32)
      set_target_properties(openclaw-gui PROPERTIES WIN32_EXECUTABLE TRUE)
    elseif(APPLE)
      set_target_properties(openclaw-gui PROPERTIES MACOSX_BUNDLE TRUE)
    endif()
  else()
    message(STATUS "FLTK not found: desktop GUI target skipped. Install FLTK or configure -DOPENCLAW_BUILD_GUI=OFF.")
  endif()
endif()

enable_testing()
add_executable(core_test tests/core_test.cpp)
target_link_libraries(core_test PRIVATE openclaw_core)
add_test(NAME core_test COMMAND core_test)
