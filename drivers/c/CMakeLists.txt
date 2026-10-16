cmake_minimum_required(VERSION 3.16)
project(maludb
    VERSION 0.2.0
    DESCRIPTION "MaluDB C client library (libmaludb)"
    LANGUAGES C)

set(CMAKE_C_STANDARD 11)
set(CMAKE_C_STANDARD_REQUIRED ON)
set(CMAKE_C_EXTENSIONS OFF)

find_package(PkgConfig REQUIRED)
pkg_check_modules(LIBPQ REQUIRED libpq)

add_library(maludb SHARED src/maludb.c)
set_target_properties(maludb PROPERTIES
    VERSION   ${PROJECT_VERSION}
    SOVERSION 0
    PUBLIC_HEADER include/maludb.h)
target_include_directories(maludb PUBLIC
    $<BUILD_INTERFACE:${CMAKE_CURRENT_SOURCE_DIR}/include>
    $<INSTALL_INTERFACE:include>
    ${LIBPQ_INCLUDE_DIRS})
target_link_libraries(maludb PUBLIC ${LIBPQ_LIBRARIES})
target_compile_options(maludb PRIVATE
    -Wall -Wextra -Wshadow -Wpointer-arith -Wcast-qual
    -Wstrict-prototypes -Wmissing-prototypes
    -Wno-unused-parameter
    -fvisibility=hidden)
target_compile_definitions(maludb PRIVATE MALUDB_BUILDING_LIB=1)

# pkg-config for downstream consumers
configure_file(
    ${CMAKE_CURRENT_SOURCE_DIR}/maludb.pc.in
    ${CMAKE_CURRENT_BINARY_DIR}/maludb.pc
    @ONLY)

include(GNUInstallDirs)
install(TARGETS maludb
    LIBRARY DESTINATION ${CMAKE_INSTALL_LIBDIR}
    PUBLIC_HEADER DESTINATION ${CMAKE_INSTALL_INCLUDEDIR})
install(FILES ${CMAKE_CURRENT_BINARY_DIR}/maludb.pc
    DESTINATION ${CMAKE_INSTALL_LIBDIR}/pkgconfig)

# ---- tests ----------------------------------------------------------
enable_testing()
add_executable(maludb_smoke tests/smoke.c)
target_link_libraries(maludb_smoke PRIVATE maludb)
add_test(NAME smoke COMMAND maludb_smoke)
# ctest passes the parent environment through by default; we don't
# need to capture MALUDB_TEST_DSN at configure time. Runners just do:
#   MALUDB_TEST_DSN=... ctest --test-dir build --output-on-failure
set_tests_properties(smoke PROPERTIES
    SKIP_RETURN_CODE 77)

# V3-SDK-01 (v0.2.0) — pool / skill / node wrappers.
add_executable(maludb_smoke_v02 tests/smoke_v02.c)
target_link_libraries(maludb_smoke_v02 PRIVATE maludb)
add_test(NAME smoke_v02 COMMAND maludb_smoke_v02)
set_tests_properties(smoke_v02 PROPERTIES
    SKIP_RETURN_CODE 77)

# ---- examples -------------------------------------------------------
add_executable(maludb_example_ingest_to_replay
    examples/01-ingest-to-replay.c)
target_link_libraries(maludb_example_ingest_to_replay PRIVATE maludb)
