cmake_minimum_required(VERSION 3.10.2)

file(GLOB LIBSMB2_SRCS
    "${CMAKE_CURRENT_SOURCE_DIR}/../../../../../ios/Runner/libsmb2/lib/*.c"
)

set(DCERPC_SRCS
    "${CMAKE_CURRENT_SOURCE_DIR}/../../../../../ios/Runner/libsmb2/libdcerpc/dcerpc.c"
    "${CMAKE_CURRENT_SOURCE_DIR}/../../../../../ios/Runner/libsmb2/libdcerpc/dcerpc-srvsvc.c"
)

add_library(smb2jni SHARED
    smb2_jni.c
    ${LIBSMB2_SRCS}
    ${DCERPC_SRCS}
)

target_include_directories(smb2jni PRIVATE
    ${CMAKE_CURRENT_SOURCE_DIR}/../../../../../ios/Runner/libsmb2/include
    ${CMAKE_CURRENT_SOURCE_DIR}/../../../../../ios/Runner/libsmb2/include/smb2
    ${CMAKE_CURRENT_SOURCE_DIR}/../../../../../ios/Runner/libsmb2/include/dcerpc
    ${CMAKE_CURRENT_SOURCE_DIR}/../../../../../ios/Runner/libsmb2/lib
    ${CMAKE_CURRENT_SOURCE_DIR}/../../../../../ios/Runner/libsmb2/libdcerpc
)

target_compile_definitions(smb2jni PRIVATE
    HAVE_CONFIG_H
    _U_=
    ANDROID
)

target_compile_options(smb2jni PRIVATE
    -std=gnu11
    -w
)

# Only the two dcerpc units need the prefix rename header.
set_source_files_properties(${DCERPC_SRCS} PROPERTIES
    COMPILE_OPTIONS "-include;${CMAKE_CURRENT_SOURCE_DIR}/../../../../../ios/Runner/libsmb2/lib/libsmb2-dcerpc-prefix.h"
)

find_library(log-lib log)
target_link_libraries(smb2jni ${log-lib})

# AC3-transcode encoder (issue #70): static minimal FFmpeg (AC3 encoder only,
# built by tool/build_ffmpeg_ac3.sh into ac3enc/prebuilt/<abi>/).
if(EXISTS "${CMAKE_CURRENT_SOURCE_DIR}/ac3enc/prebuilt/${ANDROID_ABI}/lib/libavcodec.a")
    add_library(ac3enc SHARED ac3enc_jni.c)
    set(AC3_PREBUILT "${CMAKE_CURRENT_SOURCE_DIR}/ac3enc/prebuilt/${ANDROID_ABI}")
    target_include_directories(ac3enc PRIVATE "${AC3_PREBUILT}/include")
    target_link_directories(ac3enc PRIVATE "${AC3_PREBUILT}/lib")
    target_link_libraries(ac3enc avcodec avutil ${log-lib})
else()
    message(WARNING "ac3enc prebuilt libs missing for ${ANDROID_ABI} - run tool/build_ffmpeg_ac3.sh; AC3 transcoding will be unavailable on this ABI")
endif()
