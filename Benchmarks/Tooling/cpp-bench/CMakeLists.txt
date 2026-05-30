cmake_minimum_required(VERSION 3.16)
project(dx_clickhouse_cpp_bench CXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_EXTENSIONS OFF)

if(NOT CMAKE_BUILD_TYPE)
    set(CMAKE_BUILD_TYPE Release)
endif()

set(CMAKE_CXX_FLAGS_RELEASE "-O3 -DNDEBUG")

set(CLICKHOUSE_CPP_ROOT "${CMAKE_CURRENT_SOURCE_DIR}/../clickhouse-cpp"
    CACHE PATH "Path to the clickhouse-cpp source tree")
set(CLICKHOUSE_CPP_BUILD "${CLICKHOUSE_CPP_ROOT}/build"
    CACHE PATH "Path to the clickhouse-cpp CMake build output")

if(NOT EXISTS "${CLICKHOUSE_CPP_BUILD}/clickhouse/libclickhouse-cpp-lib.a")
    message(FATAL_ERROR
        "clickhouse-cpp static library not found at "
        "${CLICKHOUSE_CPP_BUILD}/clickhouse/libclickhouse-cpp-lib.a. "
        "Build clickhouse-cpp first (see README).")
endif()

find_package(OpenSSL REQUIRED)

add_executable(dx_clickhouse_cpp_bench main.cpp)

target_include_directories(dx_clickhouse_cpp_bench PRIVATE
    "${CLICKHOUSE_CPP_ROOT}"
    "${CLICKHOUSE_CPP_ROOT}/contrib/absl"
)

target_link_libraries(dx_clickhouse_cpp_bench PRIVATE
    "${CLICKHOUSE_CPP_BUILD}/clickhouse/libclickhouse-cpp-lib.a"
    "${CLICKHOUSE_CPP_BUILD}/contrib/cityhash/cityhash/libcityhash.a"
    "${CLICKHOUSE_CPP_BUILD}/contrib/lz4/lz4/liblz4.a"
    "${CLICKHOUSE_CPP_BUILD}/contrib/absl/absl/libabsl_int128.a"
    OpenSSL::SSL
    OpenSSL::Crypto
    pthread
)
