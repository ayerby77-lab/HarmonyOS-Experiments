cmake_minimum_required(VERSION 3.5.0)
project(onnx_native)

set(CMAKE_CXX_STANDARD 17)

# NAPI 头文件
if(DEFINED ENV{OHOS_SDK_NATIVE})
  set(NAPI_INCLUDE_DIRS "$ENV{OHOS_SDK_NATIVE}/sysroot/usr/include/napi")
elseif(DEFINED OHOS_SDK_NATIVE)
  set(NAPI_INCLUDE_DIRS "${OHOS_SDK_NATIVE}/sysroot/usr/include/napi")
else()
  message(FATAL_ERROR "OHOS_SDK_NATIVE not set")
endif()

add_library(onnx_native SHARED
  inference_native.cpp
)

target_include_directories(onnx_native PUBLIC
  ${NAPI_INCLUDE_DIRS}
)

target_link_libraries(onnx_native PUBLIC
  libace_napi.z.so
)

# 静态链接 C++ 运行时：避免设备侧因 libc++_shared.so 加载失败导致 NAPI 模块不可用
target_link_options(onnx_native PRIVATE -static-libstdc++)
