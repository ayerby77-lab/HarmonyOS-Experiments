/**
 * onnx_native — Ort C API 推理。
 *
 * 绕过 @ohos/onnxruntime NAPI OnnxTensor SIGSEGV bug。
 *
 * 自动探测两种可能的 OrtApi struct 布局：
 *   方案 A：CreateEnv=[3]（有 CreateStatus 等前缀）
 *   方案 B：CreateEnv=[0]（无前缀）
 * 偏移量相对于 CreateEnv 固定，一次确定全局确定。
 */
#include <string>
#include <vector>
#include <cstring>
#include <cstdio>
#include <cstdint>
#include <dlfcn.h>

typedef int64_t int64_ort;

typedef struct OrtApiBase {
  const void* (*GetApi)(uint32_t version);
} OrtApiBase;

// ===== 全局状态 =====
static const void** g_api = nullptr;
static void* g_env = nullptr;
static void* g_session = nullptr;
static int g_ce = -1;  // 探测到的 CreateEnv 索引
static bool g_initialized = false;

#define REL_CreateSessionOptions   7
#define REL_CreateSessionFromArray 5
#define REL_Run                    6
#define REL_SetGraphOptLevel      20
#define REL_SetIntraOpNumThreads  21
#define REL_CreateTensorWithData  46
#define REL_GetTensorMutableData  48
#define REL_CreateCpuMemoryInfo   66
#define REL_ReleaseEnv            89
#define REL_ReleaseSession         92
#define REL_ReleaseValue           93
#define REL_ReleaseMemoryInfo      91
#define REL_ReleaseSessionOptions 97

#include <napi/native_api.h>

static napi_value ThrowError(napi_env env, const char* msg) {
  napi_throw_error(env, nullptr, msg);
  return nullptr;
}

// ===== 函数指针类型 =====
typedef void* (*FnCreateEnv)(int, const char*, void**);
typedef void* (*FnCreateSessionOptions)(void**);
typedef void* (*FnSetIntraOpNumThreads)(void*, int);
typedef void* (*FnSetGraphOptLevel)(void*, int);
typedef void* (*FnCreateSessionFromArray)(const void*, const void*, size_t, const void*, void**);
typedef void* (*FnCreateTensorWithData)(const void*, void*, size_t, const int64_ort*, size_t, int, void**);
typedef void* (*FnGetTensorMutableData)(void*, void**);
typedef void* (*FnCreateCpuMemInfo)(int, int, void**);
typedef void* (*FnOrtRun)(void*, const void*, const char* const*, const void* const*, size_t, const char* const*, size_t, void**);
typedef void  (*FnRelease)(void*);

// ===== 尝试用 CE=ceIdx 初始化 =====
// 返回：正整数 ceIdx 表示成功，-1 表示失败
static int tryInitCE(const void** api, int ceIdx,
                     const void* modelData, size_t modelLen,
                     void** outEnv, void** outSession) {
  auto createEnv = (FnCreateEnv)api[ceIdx];
  if (!createEnv) return -1;
  void* env = nullptr;
  void* st = createEnv(1, "SmartItem", &env);
  if (st != nullptr || env == nullptr) return -1;

  auto createOpts = (FnCreateSessionOptions)api[ceIdx + REL_CreateSessionOptions];
  if (!createOpts) {
    // 释放 env
    auto rlEnv = (FnRelease)api[ceIdx + REL_ReleaseEnv];
    if (rlEnv) rlEnv(env);
    return -1;
  }
  void* opts = nullptr;
  st = createOpts(&opts);
  if (st != nullptr || opts == nullptr) {
    auto rlEnv = (FnRelease)api[ceIdx + REL_ReleaseEnv];
    if (rlEnv) rlEnv(env);
    return -1;
  }

  auto setThreads = (FnSetIntraOpNumThreads)api[ceIdx + REL_SetIntraOpNumThreads];
  if (setThreads) setThreads(opts, 4);
  auto setOpt = (FnSetGraphOptLevel)api[ceIdx + REL_SetGraphOptLevel];
  if (setOpt) setOpt(opts, 99);

  auto createSess = (FnCreateSessionFromArray)api[ceIdx + REL_CreateSessionFromArray];
  if (!createSess) {
    auto rl = (FnRelease)api[ceIdx + REL_ReleaseEnv];
    if (rl) rl(env);
    return -1;
  }
  void* session = nullptr;
  st = createSess(env, modelData, modelLen, opts, &session);

  // 释放 opts
  auto rlOpts = (FnRelease)api[ceIdx + REL_ReleaseSessionOptions];
  if (rlOpts && opts) rlOpts(opts);

  if (st != nullptr || session == nullptr) {
    auto rlEnv = (FnRelease)api[ceIdx + REL_ReleaseEnv];
    if (rlEnv) rlEnv(env);
    return -1;
  }

  *outEnv = env;
  *outSession = session;
  return ceIdx;
}

// ===== nativeInit =====

static napi_value NativeInit(napi_env env, napi_callback_info info) {
  // ===== 进程级幂等检查：已初始化直接返回，ArkTS 各 worker 独立初始化时也不会重复创建 session =====
  if (g_initialized && g_session) {
    napi_value result;
    napi_create_string_utf8(env, "OK:already_init", strlen("OK:already_init"), &result);
    return result;
  }

  size_t argc = 1;
  napi_value args[1];
  napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
  size_t strLen = 0;
  napi_get_value_string_utf8(env, args[0], nullptr, 0, &strLen);
  std::string modelPath(strLen + 1, '\0');
  napi_get_value_string_utf8(env, args[0], &modelPath[0], strLen + 1, &strLen);

  // 找 OrtGetApiBase
  auto fnOrtGetApiBase =
    reinterpret_cast<const OrtApiBase* (*)()>(dlsym(RTLD_DEFAULT, "OrtGetApiBase"));
  if (!fnOrtGetApiBase) {
    void* handle = dlopen("liblibrary.so", RTLD_NOW | RTLD_GLOBAL);
    if (!handle) return ThrowError(env, "dlopen liblibrary.so");
    fnOrtGetApiBase =
      reinterpret_cast<const OrtApiBase* (*)()>(dlsym(handle, "OrtGetApiBase"));
  }
  if (!fnOrtGetApiBase) return ThrowError(env, "OrtGetApiBase not found");

  const OrtApiBase* base = fnOrtGetApiBase();
  if (!base) return ThrowError(env, "OrtApiBase null");

  g_api = (const void**)base->GetApi(23);
  if (!g_api) return ThrowError(env, "GetApi null");

  // 读取模型
  FILE* f = fopen(modelPath.c_str(), "rb");
  if (!f) return ThrowError(env, "open model");
  fseek(f, 0, SEEK_END);
  long fsize = ftell(f);
  fseek(f, 0, SEEK_SET);
  std::vector<uint8_t> modelBuf(fsize);
  fread(modelBuf.data(), 1, fsize, f);
  fclose(f);

  // 先试方案 A (CE=3)，再试 B (CE=0)
  void* tryEnv = nullptr;
  void* trySess = nullptr;
  int ce = tryInitCE(g_api, 3, modelBuf.data(), fsize, &tryEnv, &trySess);
  if (ce < 0) {
    ce = tryInitCE(g_api, 0, modelBuf.data(), fsize, &tryEnv, &trySess);
  }
  if (ce < 0) {
    return ThrowError(env, "FAIL: both CE=3 and CE=0 failed");
  }

  g_ce = ce;
  g_env = tryEnv;
  g_session = trySess;
  g_initialized = true;

  char debug[128];
  snprintf(debug, sizeof(debug), "OK:CE=%d sessIdx=%d", ce, ce + REL_CreateSessionFromArray);
  napi_value result;
  napi_create_string_utf8(env, debug, strlen(debug), &result);
  return result;
}

// ===== nativeRun =====

static napi_value NativeRun(napi_env env, napi_callback_info info) {
  if (!g_initialized || !g_api || !g_session) {
    return ThrowError(env, "not initialized");
  }

  size_t argc = 5;
  napi_value args[5];
  napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);

  void* inputData = nullptr;
  size_t inputDataLen = 0;
  napi_get_arraybuffer_info(env, args[0], &inputData, &inputDataLen);

  uint32_t shapeLen = 0;
  napi_get_array_length(env, args[1], &shapeLen);
  std::vector<int64_ort> inputShape(shapeLen);
  for (uint32_t i = 0; i < shapeLen; i++) {
    napi_value elem;
    napi_get_element(env, args[1], i, &elem);
    double val = 0;
    napi_get_value_double(env, elem, &val);
    inputShape[i] = (int64_ort)val;
  }

  size_t inLen = 0;
  napi_get_value_string_utf8(env, args[2], nullptr, 0, &inLen);
  std::string inName(inLen + 1, '\0');
  napi_get_value_string_utf8(env, args[2], &inName[0], inLen + 1, &inLen);

  size_t outLen = 0;
  napi_get_value_string_utf8(env, args[3], nullptr, 0, &outLen);
  std::string outName(outLen + 1, '\0');
  napi_get_value_string_utf8(env, args[3], &outName[0], outLen + 1, &outLen);

  double os = 0;
  napi_get_value_double(env, args[4], &os);
  size_t outputBytes = (size_t)os;
  if (outputBytes == 0) outputBytes = 17 * 8400 * sizeof(float);

  // === 1. CreateCpuMemoryInfo (idx = CE + 66) ===
  auto createCpuMemInfo = (FnCreateCpuMemInfo)g_api[g_ce + REL_CreateCpuMemoryInfo];
  if (!createCpuMemInfo) return ThrowError(env, "no CreateCpuMemInfo");
  void* memInfo = nullptr;
  void* st = createCpuMemInfo(1, 0, &memInfo);
  if (st != nullptr || memInfo == nullptr) return ThrowError(env, "CreateCpuMemInfo failed");

  // === 2. CreateTensorWithDataAsOrtValue (idx = CE + 46) ===
  auto createTensor = (FnCreateTensorWithData)g_api[g_ce + REL_CreateTensorWithData];
  if (!createTensor) return ThrowError(env, "no CreateTensorWithData");
  void* inputTensor = nullptr;
  st = createTensor(memInfo, inputData, inputDataLen,
                    inputShape.data(), inputShape.size(),
                    1 /* ONNX_TENSOR_ELEMENT_DATA_TYPE_FLOAT */, &inputTensor);
  if (st != nullptr || inputTensor == nullptr) return ThrowError(env, "CreateTensorWithData failed");

  // === 3. Run (idx = CE + 6) ===
  auto ortRun = (FnOrtRun)g_api[g_ce + REL_Run];
  if (!ortRun) return ThrowError(env, "no Run");
  const char* inNames[] = { inName.c_str() };
  const char* outNames[] = { outName.c_str() };
  void* inputPtrs[] = { inputTensor };
  void* outputTensor = nullptr;
  st = ortRun(g_session, nullptr,
              inNames, (const void* const*)inputPtrs, 1,
              outNames, 1, &outputTensor);
  if (st != nullptr) return ThrowError(env, "Run failed");

  // === 4. GetTensorMutableData (idx = CE + 48) ===
  auto getMutableData = (FnGetTensorMutableData)g_api[g_ce + REL_GetTensorMutableData];
  if (!getMutableData) return ThrowError(env, "no GetTensorMutableData");
  void* outputDataPtr = nullptr;
  st = getMutableData(outputTensor, &outputDataPtr);
  if (st != nullptr || outputDataPtr == nullptr) return ThrowError(env, "GetTensorMutableData failed");

  // === 5. 返回 ArrayBuffer ===
  void* resultData = nullptr;
  napi_value resultAb;
  napi_create_arraybuffer(env, outputBytes, &resultData, &resultAb);
  std::memcpy(resultData, outputDataPtr, outputBytes);

  // === 6. 清理 ===
  auto rlVal = (FnRelease)g_api[g_ce + REL_ReleaseValue];
  if (rlVal) { rlVal(inputTensor); rlVal(outputTensor); }
  auto rlMem = (FnRelease)g_api[g_ce + REL_ReleaseMemoryInfo];
  if (rlMem) rlMem(memInfo);

  return resultAb;
}

// ===== nativeDispose =====

static napi_value NativeDispose(napi_env env, napi_callback_info info) {
  if (g_api && g_ce >= 0) {
    if (g_session) {
      auto fn = (FnRelease)g_api[g_ce + REL_ReleaseSession];
      if (fn) fn(g_session);
      g_session = nullptr;
    }
    if (g_env) {
      auto fn = (FnRelease)g_api[g_ce + REL_ReleaseEnv];
      if (fn) fn(g_env);
      g_env = nullptr;
    }
  }
  g_initialized = false;
  return nullptr;
}

// ===== NAPI 注册 =====

static napi_value Init(napi_env env, napi_value exports) {
  napi_property_descriptor props[] = {
    { "nativeInit",     nullptr, NativeInit,     nullptr, nullptr, nullptr, napi_default, nullptr },
    { "nativeRun",      nullptr, NativeRun,      nullptr, nullptr, nullptr, napi_default, nullptr },
    { "nativeDispose",  nullptr, NativeDispose,  nullptr, nullptr, nullptr, napi_default, nullptr },
  };
  napi_define_properties(env, exports, sizeof(props) / sizeof(props[0]), props);
  return exports;
}

static napi_module g_module = {
  .nm_version = 1,
  .nm_flags = 0,
  .nm_filename = nullptr,
  .nm_register_func = Init,
  .nm_modname = "onnx_native",
  .reserved = { 0 },
};

extern "C" __attribute__((constructor))
void RegisterModule() {
  napi_module_register(&g_module);
}
