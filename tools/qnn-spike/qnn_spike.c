/* qnn_spike — CPU-EP vs QNN-EP latency driver for the QCS6490 spike.
 *
 * Runs one ONNX model N times on a single execution provider and prints
 * latency percentiles as a single JSON line. The D-P5 criterion (QNN p50
 * must beat CPU p50 by >= 3x) is applied by the caller, not here.
 *
 * Usage:
 *   qnn_spike <model.onnx> cpu <iters>
 *   qnn_spike <model.onnx> qnn <iters> <libonnxruntime_providers_qnn.so> \
 *             [key=value ...]        # extra QNN EP options, e.g. soc_model=35
 *
 * QNN mode uses the ORT 1.22+ plugin-EP API: RegisterExecutionProviderLibrary
 * then SessionOptionsAppendExecutionProvider_V2 on the QNNExecutionProvider
 * device, backend_type=htp. If the QNN EP fails to initialize the session
 * the process exits nonzero — but note a *silent* whole-graph-on-CPU
 * partition is still possible, which is exactly why the latency delta is
 * the success criterion.
 */
#define _POSIX_C_SOURCE 199309L /* clock_gettime under -std=c11 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

#include "onnxruntime_c_api.h"

static const OrtApi* g_ort;

#define ORT_CHECK(expr)                                             \
  do {                                                              \
    OrtStatus* status_ = (expr);                                    \
    if (status_ != NULL) {                                          \
      fprintf(stderr, "ORT error at line %d: %s\n", __LINE__,       \
              g_ort->GetErrorMessage(status_));                     \
      g_ort->ReleaseStatus(status_);                                \
      exit(1);                                                      \
    }                                                               \
  } while (0)

static double now_ms(void) {
  struct timespec ts;
  clock_gettime(CLOCK_MONOTONIC, &ts);
  return (double)ts.tv_sec * 1000.0 + (double)ts.tv_nsec / 1e6;
}

static int cmp_double(const void* a, const void* b) {
  double d = *(const double*)a - *(const double*)b;
  return (d > 0) - (d < 0);
}

/* Nearest-rank percentile: ceil(p*n)th order statistic (1-based). */
static double percentile(double* sorted, int n, double p) {
  int rank = (int)(p * (double)n);
  if ((double)rank < p * (double)n) rank++; /* ceil without libm */
  if (rank < 1) rank = 1;
  if (rank > n) rank = n;
  return sorted[rank - 1];
}

int main(int argc, char** argv) {
  if (argc < 4) {
    fprintf(stderr,
            "usage: %s <model.onnx> cpu|qnn <iters> [qnn_plugin_lib]\n",
            argv[0]);
    return 2;
  }
  const char* model_path = argv[1];
  const char* ep_mode = argv[2];
  int iters = atoi(argv[3]);
  int use_qnn = strcmp(ep_mode, "qnn") == 0;
  if (!use_qnn && strcmp(ep_mode, "cpu") != 0) {
    /* Anything unrecognized would silently benchmark CPU under a
     * mislabeled JSON tag — fatal in a delta-based spike. */
    fprintf(stderr, "unknown EP mode '%s' (want cpu or qnn)\n", ep_mode);
    return 2;
  }
  if (use_qnn && argc < 5) {
    fprintf(stderr, "qnn mode needs the plugin library path\n");
    return 2;
  }
  if (iters < 1) {
    fprintf(stderr, "iters must be >= 1\n");
    return 2;
  }

  g_ort = OrtGetApiBase()->GetApi(ORT_API_VERSION);
  if (g_ort == NULL) {
    fprintf(stderr, "ORT API version %d unavailable in this runtime\n",
            ORT_API_VERSION);
    return 1;
  }

  OrtEnv* env;
  ORT_CHECK(g_ort->CreateEnv(ORT_LOGGING_LEVEL_WARNING, "qnn_spike", &env));

  OrtSessionOptions* so;
  ORT_CHECK(g_ort->CreateSessionOptions(&so));

  if (use_qnn) {
    ORT_CHECK(g_ort->RegisterExecutionProviderLibrary(
        env, "QNNExecutionProvider", argv[4]));

    const OrtEpDevice* const* devices;
    size_t num_devices = 0;
    ORT_CHECK(g_ort->GetEpDevices(env, &devices, &num_devices));

    const OrtEpDevice* qnn_dev = NULL;
    for (size_t i = 0; i < num_devices; i++) {
      const char* name = g_ort->EpDevice_EpName(devices[i]);
      fprintf(stderr, "ep_device[%zu]: %s\n", i, name);
      if (qnn_dev == NULL && strcmp(name, "QNNExecutionProvider") == 0) {
        qnn_dev = devices[i];
      }
    }
    if (qnn_dev == NULL) {
      fprintf(stderr, "no QNNExecutionProvider device found\n");
      return 1;
    }

    const char* keys[16] = {"backend_type", "htp_performance_mode"};
    const char* vals[16] = {"htp", "burst"};
    size_t n_opts = 2;
    for (int a = 5; a < argc; a++) {
      if (n_opts >= 16) {
        fprintf(stderr, "too many EP options (max 14 extra)\n");
        return 2;
      }
      char* eq = strchr(argv[a], '=');
      if (eq == NULL) {
        fprintf(stderr, "bad EP option (want key=value): %s\n", argv[a]);
        return 2;
      }
      *eq = '\0';
      keys[n_opts] = argv[a];
      vals[n_opts] = eq + 1;
      n_opts++;
    }
    ORT_CHECK(g_ort->SessionOptionsAppendExecutionProvider_V2(
        so, env, &qnn_dev, 1, keys, vals, n_opts));
  }

  OrtSession* session;
  double t_load0 = now_ms();
  ORT_CHECK(g_ort->CreateSession(env, model_path, so, &session));
  double load_ms = now_ms() - t_load0;

  OrtAllocator* allocator;
  ORT_CHECK(g_ort->GetAllocatorWithDefaultOptions(&allocator));

  size_t n_inputs = 0;
  ORT_CHECK(g_ort->SessionGetInputCount(session, &n_inputs));
  if (n_inputs != 1) {
    fprintf(stderr, "expected exactly 1 model input, got %zu\n", n_inputs);
    return 1;
  }
  char* input_name;
  ORT_CHECK(g_ort->SessionGetInputName(session, 0, allocator, &input_name));

  OrtTypeInfo* type_info;
  ORT_CHECK(g_ort->SessionGetInputTypeInfo(session, 0, &type_info));
  const OrtTensorTypeAndShapeInfo* tensor_info;
  ORT_CHECK(g_ort->CastTypeInfoToTensorInfo(type_info, &tensor_info));
  ONNXTensorElementDataType elem_type;
  ORT_CHECK(g_ort->GetTensorElementType(tensor_info, &elem_type));
  size_t n_dims = 0;
  ORT_CHECK(g_ort->GetDimensionsCount(tensor_info, &n_dims));
  int64_t dims[8];
  if (n_dims > 8) {
    fprintf(stderr, "too many input dims: %zu\n", n_dims);
    return 1;
  }
  ORT_CHECK(g_ort->GetDimensions(tensor_info, dims, n_dims));

  size_t n_elems = 1;
  for (size_t i = 0; i < n_dims; i++) {
    if (dims[i] <= 0) {
      if (i != 0) {
        /* A dynamic non-batch dim silently defaulted to 1 would
         * benchmark a 1x1 input — wrong numbers, no error. */
        fprintf(stderr,
                "input dim %zu is dynamic; use a static-shape model "
                "(only the batch dim may be dynamic)\n",
                i);
        return 1;
      }
      dims[i] = 1; /* dynamic batch -> 1 */
    }
    n_elems *= (size_t)dims[i];
  }

  size_t elem_size;
  switch (elem_type) {
    case ONNX_TENSOR_ELEMENT_DATA_TYPE_FLOAT: elem_size = 4; break;
    case ONNX_TENSOR_ELEMENT_DATA_TYPE_UINT8:
    case ONNX_TENSOR_ELEMENT_DATA_TYPE_INT8: elem_size = 1; break;
    default:
      fprintf(stderr, "unsupported input element type %d\n", (int)elem_type);
      return 1;
  }

  void* input_data = malloc(n_elems * elem_size);
  if (input_data == NULL) return 1;
  srand(42); /* deterministic input across runs and EPs */
  if (elem_type == ONNX_TENSOR_ELEMENT_DATA_TYPE_FLOAT) {
    float* f = (float*)input_data;
    for (size_t i = 0; i < n_elems; i++) f[i] = (float)rand() / (float)RAND_MAX;
  } else {
    unsigned char* b = (unsigned char*)input_data;
    for (size_t i = 0; i < n_elems; i++) b[i] = (unsigned char)(rand() & 0xff);
  }

  OrtMemoryInfo* mem_info;
  ORT_CHECK(g_ort->CreateCpuMemoryInfo(OrtArenaAllocator, OrtMemTypeDefault,
                                       &mem_info));
  OrtValue* input_tensor = NULL;
  ORT_CHECK(g_ort->CreateTensorWithDataAsOrtValue(
      mem_info, input_data, n_elems * elem_size, dims, n_dims, elem_type,
      &input_tensor));

  size_t n_outputs = 0;
  ORT_CHECK(g_ort->SessionGetOutputCount(session, &n_outputs));
  if (n_outputs > 16) {
    fprintf(stderr, "too many outputs: %zu\n", n_outputs);
    return 1;
  }
  char* output_names[16];
  OrtValue* outputs[16];
  for (size_t i = 0; i < n_outputs; i++) {
    ORT_CHECK(g_ort->SessionGetOutputName(session, i, allocator,
                                          &output_names[i]));
    outputs[i] = NULL;
  }

  const char* input_names[] = {input_name};
  const OrtValue* inputs[] = {input_tensor};

  /* First run timed separately to VERIFY there is no hidden first-run
   * cost: on QNN, graph prepare/finalization happens inside
   * CreateSession (session_load_ms ~1.1 s on-board), and the measured
   * first run already matches steady state (~7 ms vs p50 6.66 ms). */
  double t0 = now_ms();
  ORT_CHECK(g_ort->Run(session, NULL, input_names, inputs, 1,
                       (const char* const*)output_names, n_outputs, outputs));
  double first_run_ms = now_ms() - t0;
  for (size_t i = 0; i < n_outputs; i++) {
    g_ort->ReleaseValue(outputs[i]);
    outputs[i] = NULL;
  }

  for (int w = 0; w < 4; w++) {
    ORT_CHECK(g_ort->Run(session, NULL, input_names, inputs, 1,
                         (const char* const*)output_names, n_outputs,
                         outputs));
    for (size_t i = 0; i < n_outputs; i++) {
      g_ort->ReleaseValue(outputs[i]);
      outputs[i] = NULL;
    }
  }

  double* lat = malloc(sizeof(double) * (size_t)iters);
  if (lat == NULL) return 1;
  for (int it = 0; it < iters; it++) {
    double t = now_ms();
    ORT_CHECK(g_ort->Run(session, NULL, input_names, inputs, 1,
                         (const char* const*)output_names, n_outputs,
                         outputs));
    lat[it] = now_ms() - t;
    for (size_t i = 0; i < n_outputs; i++) {
      g_ort->ReleaseValue(outputs[i]);
      outputs[i] = NULL;
    }
  }

  qsort(lat, (size_t)iters, sizeof(double), cmp_double);
  double sum = 0;
  for (int i = 0; i < iters; i++) sum += lat[i];

  printf(
      "{\"ep\":\"%s\",\"model\":\"%s\",\"iters\":%d,"
      "\"session_load_ms\":%.2f,\"first_run_ms\":%.2f,"
      "\"p50_ms\":%.3f,\"p95_ms\":%.3f,\"mean_ms\":%.3f,"
      "\"min_ms\":%.3f,\"max_ms\":%.3f}\n",
      ep_mode, model_path, iters, load_ms, first_run_ms,
      percentile(lat, iters, 0.50), percentile(lat, iters, 0.95),
      sum / (double)iters, lat[0], lat[iters - 1]);

  return 0;
}
