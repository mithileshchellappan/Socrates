// The part of ONNX Runtime's C API that LocalTranslation uses, behind opaque handles.
//
// The ORT framework has no module map, so Swift cannot import its C API directly; this target is
// the module. All pointer work stays in C: Swift sees `lt_session` / `lt_tensor` handles and
// `char *` errors. Functions that can fail return NULL on success, else a malloc'd message that
// the caller frees with `lt_free_error`.

#ifndef CONNXRUNTIME_H
#define CONNXRUNTIME_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

#pragma clang assume_nonnull begin

/// An OrtSession plus copies of its input and output names.
typedef struct lt_session lt_session;
/// An OrtValue (a tensor) with its shape.
typedef struct lt_tensor lt_tensor;

/// Opens a model on the CPU execution provider: `intra_op_threads` intra-op threads, one
/// inter-op thread, sequential execution, every graph optimization.
char *_Nullable lt_session_create(const char *model_path, int intra_op_threads, lt_session *_Nullable *_Nonnull out);
void lt_session_release(lt_session *_Nullable session);

size_t lt_session_input_count(const lt_session *session);
/// NULL when `index` is out of range.
const char *_Nullable lt_session_input_name(const lt_session *session, size_t index);
size_t lt_session_output_count(const lt_session *session);
/// NULL when `index` is out of range.
const char *_Nullable lt_session_output_name(const lt_session *session, size_t index);

/// Copies `data` (the product of `shape` elements) into a new tensor. `data` may be NULL when the
/// shape has no elements (a dimension of 0).
char *_Nullable lt_tensor_create_float(const float *_Nullable data, const int64_t *shape, size_t rank, lt_tensor *_Nullable *_Nonnull out);
char *_Nullable lt_tensor_create_int64(const int64_t *_Nullable data, const int64_t *shape, size_t rank, lt_tensor *_Nullable *_Nonnull out);
char *_Nullable lt_tensor_create_bool(const bool *_Nullable data, const int64_t *shape, size_t rank, lt_tensor *_Nullable *_Nonnull out);
void lt_tensor_release(lt_tensor *_Nullable tensor);

size_t lt_tensor_rank(const lt_tensor *tensor);
/// 0 when `index` is out of range.
int64_t lt_tensor_dim(const lt_tensor *tensor, size_t index);
/// The tensor's elements; NULL unless it is a float tensor with elements.
const float *_Nullable lt_tensor_float_data(const lt_tensor *tensor);

/// Runs the session. Inputs and outputs are named by their index in the session's input and
/// output lists. On success `outputs[0..<output_count]` hold new tensors the caller releases; on
/// failure they are all NULL.
char *_Nullable lt_session_run(
    lt_session *session,
    const size_t *input_indices,
    const lt_tensor *_Nullable const *_Nonnull inputs,
    size_t input_count,
    const size_t *output_indices,
    size_t output_count,
    lt_tensor *_Nullable *_Nonnull outputs
);

void lt_free_error(char *_Nullable message);

#pragma clang assume_nonnull end

#ifdef __cplusplus
}
#endif

#endif
