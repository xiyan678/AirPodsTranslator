#include "SherpaRuntimeCheck.h"
#include <onnxruntime/onnxruntime_c_api.h>

// The paired official Sherpa iOS archive requests API 26. Probe before entering
// its C++ initializer, which dereferences the API table without a null check.
int SherpaRuntimeSupportsRequiredAPI(void) {
  const OrtApiBase *base = OrtGetApiBase();
  return base && base->GetApi && base->GetApi(26) != 0;
}
