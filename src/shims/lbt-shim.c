// This file is a part of JuliaC. License is MIT: https://julialang.org/license
//
// libblastrampoline control-API shim for `--link-native-blas`.
//
// When a trimmed executable's BLAS/LAPACK ccalls are bound natively against a
// single BLAS provider, libblastrampoline's forwarding machinery has no job
// left: every computational symbol (dgemm_64_, ...) resolves directly into
// the provider at link time. What remains of LBT's surface is the small
// control API that LinearAlgebra ccalls; this file provides it, backed by
// the statically-known configuration.
//
// Configuration is injected at compile time by the juliac driver, from the
// provider's JLL.toml record:
//   -DLBT_SHIM_LIBNAME="libopenblas64_.so"   the provider's dlname
//   -DLBT_SHIM_SUFFIX="64_"                  the provider's symbol suffix
//   -DLBT_SHIM_ILP64=1                       ILP64 (64) vs LP64 (32) interface
//
// Struct layouts and constants mirror LinearAlgebra/src/lbt.jl (which in turn
// mirrors libblastrampoline's public header); keep them in sync.

#include <stdint.h>
#include <stddef.h>
#include <stdlib.h>
#include <unistd.h>

#ifndef LBT_SHIM_LIBNAME
#error "LBT_SHIM_LIBNAME must be defined"
#endif
#ifndef LBT_SHIM_SUFFIX
#error "LBT_SHIM_SUFFIX must be defined"
#endif
#ifndef LBT_SHIM_ILP64
#error "LBT_SHIM_ILP64 must be defined"
#endif

// The provider's thread-control entry points. Token-pasting builds the
// suffixed names (e.g. openblas_get_num_threads64_) to match the provider's
// symbol suffix.
#define LBT_SHIM_CONCAT_(a, b) a##b
#define LBT_SHIM_CONCAT(a, b) LBT_SHIM_CONCAT_(a, b)
#if LBT_SHIM_ILP64
#define PROVIDER_GET_NUM_THREADS LBT_SHIM_CONCAT(openblas_get_num_threads, 64_)
#define PROVIDER_SET_NUM_THREADS LBT_SHIM_CONCAT(openblas_set_num_threads, 64_)
#else
#define PROVIDER_GET_NUM_THREADS openblas_get_num_threads
#define PROVIDER_SET_NUM_THREADS openblas_set_num_threads
#endif
extern int PROVIDER_GET_NUM_THREADS(void);
extern void PROVIDER_SET_NUM_THREADS(int);

// -- mirrored public structs (see LinearAlgebra/src/lbt.jl) -------------------

typedef struct {
    const char *libname;
    void *handle;
    const char *suffix;
    uint8_t *active_forwards;
    int32_t interface_;        // LBT_INTERFACE_*: 32 = LP64, 64 = ILP64
    int32_t complex_retstyle;  // 0 = normal
    int32_t f2c;               // 0 = plain
    int32_t cblas;             // 0 = conformant
} lbt_library_info_t;

typedef struct {
    lbt_library_info_t **loaded_libs;  // NULL-terminated
    uint32_t build_flags;
    const char **exported_symbols;
    uint32_t num_exported_symbols;
} lbt_config_t;

// The static configuration: one loaded library, everything forwarded.
// `active_forwards` must point at div(num_exported_symbols, 8) + 1 valid
// bytes (LinearAlgebra unsafe_wraps it); with 0 exported symbols that is one
// byte, kept all-ones so any forwarding query reads "forwarded".
static uint8_t lbt_shim_forwards[1] = {0xff};
static lbt_library_info_t lbt_shim_libinfo = {
    .libname = LBT_SHIM_LIBNAME,
    .handle = NULL,
    .suffix = LBT_SHIM_SUFFIX,
    .active_forwards = lbt_shim_forwards,
    .interface_ = LBT_SHIM_ILP64 ? 64 : 32,
    .complex_retstyle = 0,
    .f2c = 0,
    .cblas = 0,
};
static lbt_library_info_t *lbt_shim_loaded_libs[2] = {&lbt_shim_libinfo, NULL};
static lbt_config_t lbt_shim_config = {
    .loaded_libs = lbt_shim_loaded_libs,
    .build_flags = 0,
    .exported_symbols = NULL,
    .num_exported_symbols = 0,
};

// -- the control API ----------------------------------------------------------

const lbt_config_t *lbt_get_config(void)
{
    return &lbt_shim_config;
}

int32_t lbt_get_num_threads(void)
{
    return (int32_t)PROVIDER_GET_NUM_THREADS();
}

void lbt_set_num_threads(int32_t nthreads)
{
    PROVIDER_SET_NUM_THREADS((int)nthreads);
}

// Forwarding is decided at link time; re-forwarding at runtime is a no-op.
// Return a positive count so callers treating 0 as failure see success.
int32_t lbt_forward(const char *path, int32_t clear, int32_t verbose, const char *suffix_hint)
{
    (void)path; (void)clear; (void)verbose; (void)suffix_hint;
    return 1;
}

static void *lbt_shim_default_func = NULL;

void *lbt_get_default_func(void)
{
    return lbt_shim_default_func;
}

void lbt_set_default_func(void *addr)
{
    lbt_shim_default_func = addr;
}

// -- startup thread tuning ----------------------------------------------------
//
// LinearAlgebra normally tunes BLAS threads from its LBT on-load callback
// (effective threads / 2). Under native linking that callback never runs, so
// replicate the default here, deferring to the standard environment
// variables when the user set them.
__attribute__((constructor)) static void lbt_shim_init_threads(void)
{
    if (getenv("OPENBLAS_NUM_THREADS") || getenv("GOTO_NUM_THREADS") ||
            getenv("OMP_NUM_THREADS"))
        return;
    long ncpu = sysconf(_SC_NPROCESSORS_ONLN);
    int nthreads = (int)(ncpu / 2);
    if (nthreads < 1)
        nthreads = 1;
    PROVIDER_SET_NUM_THREADS(nthreads);
}
