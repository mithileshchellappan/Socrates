#include "COnnxRuntime.h"

#include <pthread.h>
#include <stdlib.h>
#include <string.h>

// Framework-style include, as the official binding does under SPM_BUILD.
#if __has_include(<onnxruntime/onnxruntime_c_api.h>)
#include <onnxruntime/onnxruntime_c_api.h>
#else
#include <onnxruntime_c_api.h>
#endif

struct lt_session {
    OrtSession *session;
    char **input_names;
    size_t input_count;
    char **output_names;
    size_t output_count;
};

struct lt_tensor {
    OrtValue *value;
    ONNXTensorElementDataType type;
    size_t rank;
    int64_t *dims;
};

static const OrtApi *lt_api = NULL;
static OrtEnv *lt_env = NULL;
static char *lt_init_error = NULL;
static pthread_once_t lt_once = PTHREAD_ONCE_INIT;

static char *lt_message(const char *message) {
    return strdup(message != NULL ? message : "ONNX Runtime error");
}

/// The status's message (malloc'd), releasing the status; NULL for a NULL status (success).
static char *lt_status_error(OrtStatus *status) {
    if (status == NULL) return NULL;
    char *message = lt_message(lt_api->GetErrorMessage(status));
    lt_api->ReleaseStatus(status);
    return message;
}

static void lt_ignore(OrtStatus *status) {
    if (status != NULL) lt_api->ReleaseStatus(status);
}

static void lt_init(void) {
    const OrtApiBase *base = OrtGetApiBase();
    if (base == NULL) {
        lt_init_error = lt_message("ONNX Runtime is unavailable");
        return;
    }
    lt_api = base->GetApi(ORT_API_VERSION);
    if (lt_api == NULL) {
        lt_init_error = lt_message("ONNX Runtime API version mismatch");
        return;
    }
    OrtEnv *env = NULL;
    char *error = lt_status_error(lt_api->CreateEnv(ORT_LOGGING_LEVEL_WARNING, "StudyPortal", &env));
    if (error != NULL) {
        lt_init_error = error;
        return;
    }
    lt_env = env;
}

/// NULL once the API and the one environment exist, else a malloc'd error.
static char *lt_ready(void) {
    pthread_once(&lt_once, lt_init);
    if (lt_api == NULL || lt_env == NULL) {
        return lt_message(lt_init_error != NULL ? lt_init_error : "ONNX Runtime is unavailable");
    }
    return NULL;
}

void lt_free_error(char *message) {
    free(message);
}

// MARK: Sessions

static char *lt_copy_names(lt_session *session, bool inputs) {
    OrtAllocator *allocator = NULL;
    char *error = lt_status_error(lt_api->GetAllocatorWithDefaultOptions(&allocator));
    if (error != NULL) return error;
    size_t count = 0;
    if (inputs) {
        error = lt_status_error(lt_api->SessionGetInputCount(session->session, &count));
    } else {
        error = lt_status_error(lt_api->SessionGetOutputCount(session->session, &count));
    }
    if (error != NULL) return error;
    char **names = calloc(count > 0 ? count : 1, sizeof(char *));
    if (names == NULL) return lt_message("Out of memory");
    if (inputs) {
        session->input_names = names;
        session->input_count = count;
    } else {
        session->output_names = names;
        session->output_count = count;
    }
    for (size_t index = 0; index < count; index++) {
        char *name = NULL;
        if (inputs) {
            error = lt_status_error(lt_api->SessionGetInputName(session->session, index, allocator, &name));
        } else {
            error = lt_status_error(lt_api->SessionGetOutputName(session->session, index, allocator, &name));
        }
        if (error != NULL) return error;
        if (name == NULL) return lt_message("A model input or output has no name");
        names[index] = strdup(name);
        lt_ignore(lt_api->AllocatorFree(allocator, name));
        if (names[index] == NULL) return lt_message("Out of memory");
    }
    return NULL;
}

char *lt_session_create(const char *model_path, int intra_op_threads, lt_session **out) {
    *out = NULL;
    char *error = lt_ready();
    if (error != NULL) return error;

    OrtSessionOptions *options = NULL;
    error = lt_status_error(lt_api->CreateSessionOptions(&options));
    if (error != NULL) return error;
    error = lt_status_error(lt_api->SetIntraOpNumThreads(options, intra_op_threads));
    if (error == NULL) error = lt_status_error(lt_api->SetInterOpNumThreads(options, 1));
    if (error == NULL) error = lt_status_error(lt_api->SetSessionGraphOptimizationLevel(options, ORT_ENABLE_ALL));
    if (error == NULL) error = lt_status_error(lt_api->SetSessionExecutionMode(options, ORT_SEQUENTIAL));
    OrtSession *ort_session = NULL;
    if (error == NULL) error = lt_status_error(lt_api->CreateSession(lt_env, model_path, options, &ort_session));
    lt_api->ReleaseSessionOptions(options);
    if (error != NULL) return error;
    if (ort_session == NULL) return lt_message("ONNX Runtime returned no session");

    lt_session *session = calloc(1, sizeof(lt_session));
    if (session == NULL) {
        lt_api->ReleaseSession(ort_session);
        return lt_message("Out of memory");
    }
    session->session = ort_session;
    error = lt_copy_names(session, true);
    if (error == NULL) error = lt_copy_names(session, false);
    if (error != NULL) {
        lt_session_release(session);
        return error;
    }
    *out = session;
    return NULL;
}

void lt_session_release(lt_session *session) {
    if (session == NULL) return;
    if (session->session != NULL && lt_api != NULL) lt_api->ReleaseSession(session->session);
    if (session->input_names != NULL) {
        for (size_t index = 0; index < session->input_count; index++) free(session->input_names[index]);
        free(session->input_names);
    }
    if (session->output_names != NULL) {
        for (size_t index = 0; index < session->output_count; index++) free(session->output_names[index]);
        free(session->output_names);
    }
    free(session);
}

size_t lt_session_input_count(const lt_session *session) {
    return session->input_count;
}

const char *lt_session_input_name(const lt_session *session, size_t index) {
    if (index >= session->input_count) return NULL;
    return session->input_names[index];
}

size_t lt_session_output_count(const lt_session *session) {
    return session->output_count;
}

const char *lt_session_output_name(const lt_session *session, size_t index) {
    if (index >= session->output_count) return NULL;
    return session->output_names[index];
}

// MARK: Tensors

/// Wraps `value` with its type and shape. On success the tensor owns `value`; on failure the
/// caller still does.
static char *lt_tensor_wrap(OrtValue *value, lt_tensor **out) {
    *out = NULL;
    OrtTensorTypeAndShapeInfo *info = NULL;
    char *error = lt_status_error(lt_api->GetTensorTypeAndShape(value, &info));
    if (error != NULL) return error;
    ONNXTensorElementDataType type = ONNX_TENSOR_ELEMENT_DATA_TYPE_UNDEFINED;
    size_t rank = 0;
    error = lt_status_error(lt_api->GetTensorElementType(info, &type));
    if (error == NULL) error = lt_status_error(lt_api->GetDimensionsCount(info, &rank));
    int64_t *dims = NULL;
    if (error == NULL) {
        dims = calloc(rank > 0 ? rank : 1, sizeof(int64_t));
        if (dims == NULL) error = lt_message("Out of memory");
    }
    if (error == NULL && rank > 0) error = lt_status_error(lt_api->GetDimensions(info, dims, rank));
    lt_api->ReleaseTensorTypeAndShapeInfo(info);
    if (error != NULL) {
        free(dims);
        return error;
    }
    lt_tensor *tensor = malloc(sizeof(lt_tensor));
    if (tensor == NULL) {
        free(dims);
        return lt_message("Out of memory");
    }
    tensor->value = value;
    tensor->type = type;
    tensor->rank = rank;
    tensor->dims = dims;
    *out = tensor;
    return NULL;
}

static char *lt_tensor_create(const void *data, size_t element_size, const int64_t *shape, size_t rank,
                              ONNXTensorElementDataType type, lt_tensor **out) {
    *out = NULL;
    char *error = lt_ready();
    if (error != NULL) return error;
    size_t count = 1;
    for (size_t index = 0; index < rank; index++) {
        if (shape[index] < 0) return lt_message("A tensor dimension is negative");
        count *= (size_t)shape[index];
    }
    OrtAllocator *allocator = NULL;
    error = lt_status_error(lt_api->GetAllocatorWithDefaultOptions(&allocator));
    if (error != NULL) return error;
    OrtValue *value = NULL;
    error = lt_status_error(lt_api->CreateTensorAsOrtValue(allocator, shape, rank, type, &value));
    if (error != NULL) return error;
    if (value == NULL) return lt_message("ONNX Runtime returned no tensor");
    if (count > 0) {
        void *storage = NULL;
        if (data == NULL) error = lt_message("A tensor has elements but no data");
        if (error == NULL) error = lt_status_error(lt_api->GetTensorMutableData(value, &storage));
        if (error == NULL && storage == NULL) error = lt_message("A tensor has no storage");
        if (error != NULL) {
            lt_api->ReleaseValue(value);
            return error;
        }
        memcpy(storage, data, count * element_size);
    }
    error = lt_tensor_wrap(value, out);
    if (error != NULL) lt_api->ReleaseValue(value);
    return error;
}

char *lt_tensor_create_float(const float *data, const int64_t *shape, size_t rank, lt_tensor **out) {
    return lt_tensor_create(data, sizeof(float), shape, rank, ONNX_TENSOR_ELEMENT_DATA_TYPE_FLOAT, out);
}

char *lt_tensor_create_int64(const int64_t *data, const int64_t *shape, size_t rank, lt_tensor **out) {
    return lt_tensor_create(data, sizeof(int64_t), shape, rank, ONNX_TENSOR_ELEMENT_DATA_TYPE_INT64, out);
}

char *lt_tensor_create_bool(const bool *data, const int64_t *shape, size_t rank, lt_tensor **out) {
    return lt_tensor_create(data, sizeof(bool), shape, rank, ONNX_TENSOR_ELEMENT_DATA_TYPE_BOOL, out);
}

void lt_tensor_release(lt_tensor *tensor) {
    if (tensor == NULL) return;
    if (tensor->value != NULL && lt_api != NULL) lt_api->ReleaseValue(tensor->value);
    free(tensor->dims);
    free(tensor);
}

size_t lt_tensor_rank(const lt_tensor *tensor) {
    return tensor->rank;
}

int64_t lt_tensor_dim(const lt_tensor *tensor, size_t index) {
    if (index >= tensor->rank) return 0;
    return tensor->dims[index];
}

const float *lt_tensor_float_data(const lt_tensor *tensor) {
    if (tensor->type != ONNX_TENSOR_ELEMENT_DATA_TYPE_FLOAT) return NULL;
    void *storage = NULL;
    OrtStatus *status = lt_api->GetTensorMutableData(tensor->value, &storage);
    if (status != NULL) {
        lt_api->ReleaseStatus(status);
        return NULL;
    }
    return (const float *)storage;
}

// MARK: Running

char *lt_session_run(lt_session *session, const size_t *input_indices, const lt_tensor *const *inputs, size_t input_count,
                     const size_t *output_indices, size_t output_count, lt_tensor **outputs) {
    for (size_t index = 0; index < output_count; index++) outputs[index] = NULL;
    char *error = lt_ready();
    if (error != NULL) return error;

    const char **input_names = calloc(input_count > 0 ? input_count : 1, sizeof(char *));
    const OrtValue **input_values = calloc(input_count > 0 ? input_count : 1, sizeof(OrtValue *));
    const char **output_names = calloc(output_count > 0 ? output_count : 1, sizeof(char *));
    OrtValue **output_values = calloc(output_count > 0 ? output_count : 1, sizeof(OrtValue *));
    if (input_names == NULL || input_values == NULL || output_names == NULL || output_values == NULL) {
        error = lt_message("Out of memory");
    }
    for (size_t index = 0; error == NULL && index < input_count; index++) {
        size_t position = input_indices[index];
        if (position >= session->input_count) {
            error = lt_message("An input index is out of range");
        } else if (inputs[index] == NULL) {
            error = lt_message("An input tensor is missing");
        } else {
            input_names[index] = session->input_names[position];
            input_values[index] = inputs[index]->value;
        }
    }
    for (size_t index = 0; error == NULL && index < output_count; index++) {
        size_t position = output_indices[index];
        if (position >= session->output_count) {
            error = lt_message("An output index is out of range");
        } else {
            output_names[index] = session->output_names[position];
        }
    }
    if (error == NULL) {
        error = lt_status_error(lt_api->Run(session->session, NULL, input_names, input_values, input_count,
                                             output_names, output_count, output_values));
    }
    for (size_t index = 0; error == NULL && index < output_count; index++) {
        if (output_values[index] == NULL) {
            error = lt_message("ONNX Runtime returned no output");
            break;
        }
        error = lt_tensor_wrap(output_values[index], &outputs[index]);
        if (error == NULL) output_values[index] = NULL;
    }
    if (error != NULL) {
        for (size_t index = 0; index < output_count; index++) {
            lt_tensor_release(outputs[index]);
            outputs[index] = NULL;
            if (output_values != NULL && output_values[index] != NULL) lt_api->ReleaseValue(output_values[index]);
        }
    }
    free(input_names);
    free(input_values);
    free(output_names);
    free(output_values);
    return error;
}
