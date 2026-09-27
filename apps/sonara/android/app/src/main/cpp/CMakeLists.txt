cmake_minimum_required(VERSION 3.22.1)
project(sonara_audio)

add_library(sonara_audio SHARED sonara_audio.cpp)
find_package(oboe REQUIRED CONFIG)
target_compile_features(sonara_audio PRIVATE cxx_std_20)
target_compile_options(sonara_audio PRIVATE -Wall -Wextra -Werror)
target_link_libraries(sonara_audio PRIVATE oboe::oboe log android)
