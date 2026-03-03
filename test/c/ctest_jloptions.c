/*
 * C test driver for jl_options library verification.
 *
 * Loads a JuliaC-compiled library and calls the exported jc_get_handle_signals,
 * jc_get_nthreads, and jc_get_nthreadpools functions, printing the results.
 *
 * Cross-platform: uses LoadLibrary/GetProcAddress on Windows, dlopen/dlsym on Unix.
 */
#include <stdio.h>
#include <stdint.h>

#ifdef _WIN32
#include <windows.h>
typedef HMODULE lib_handle_t;
#else
#include <dlfcn.h>
typedef void* lib_handle_t;
#endif

static lib_handle_t load_library(const char* path) {
#ifdef _WIN32
    return LoadLibraryA(path);
#else
    return dlopen(path, RTLD_NOW | RTLD_GLOBAL);
#endif
}

static void* get_symbol(lib_handle_t handle, const char* name) {
#ifdef _WIN32
    return (void*)GetProcAddress(handle, name);
#else
    return dlsym(handle, name);
#endif
}

static void print_load_error(const char* context) {
#ifdef _WIN32
    fprintf(stderr, "%s failed: error code %lu\n", context, GetLastError());
#else
    fprintf(stderr, "%s failed: %s\n", context, dlerror());
#endif
}

typedef int32_t (*getter_t)(void);

int main(int argc, char** argv) {
    if (argc < 2) {
        fprintf(stderr, "usage: %s <libpath>\n", argv[0]);
        return 2;
    }

    lib_handle_t h = load_library(argv[1]);
    if (!h) {
        print_load_error("LoadLibrary/dlopen");
        return 3;
    }

    getter_t get_hs = (getter_t)get_symbol(h, "jc_get_handle_signals");
    if (!get_hs) {
        print_load_error("jc_get_handle_signals");
        return 4;
    }

    getter_t get_nt = (getter_t)get_symbol(h, "jc_get_nthreads");
    if (!get_nt) {
        print_load_error("jc_get_nthreads");
        return 5;
    }

    getter_t get_np = (getter_t)get_symbol(h, "jc_get_nthreadpools");
    if (!get_np) {
        print_load_error("jc_get_nthreadpools");
        return 6;
    }

    printf("handle_signals=%d\n", get_hs());
    printf("nthreads=%d\n", get_nt());
    printf("nthreadpools=%d\n", get_np());

    return 0;
}
