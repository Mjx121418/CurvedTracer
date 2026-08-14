cmake_minimum_required(VERSION 3.20)
project(NonEuclideanRayTracer LANGUAGES CXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
if(NOT CMAKE_BUILD_TYPE)
  set(CMAKE_BUILD_TYPE Release)
endif()
add_compile_options(-Wall -Wextra)

add_library(GeometryCore STATIC
  Sources/GeometryCore/src/Mobius.cpp
)
target_include_directories(GeometryCore PUBLIC ${CMAKE_CURRENT_SOURCE_DIR}/Sources/GeometryCore/include)

add_executable(geometry_tests
  Tests/Cpp/test_main.cpp
  Tests/Cpp/test_math.cpp
  Tests/Cpp/test_stereo.cpp
  Tests/Cpp/test_mobius.cpp
  Tests/Cpp/test_intersect.cpp
  Tests/Cpp/test_atlas.cpp
)
target_link_libraries(geometry_tests PRIVATE GeometryCore)

enable_testing()
add_test(NAME geometry_tests COMMAND geometry_tests)
