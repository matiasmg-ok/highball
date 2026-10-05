/* Minimal ntdll entry point: exercise the loader without a Wine engine or entitlement. */
#include <dlfcn.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

struct wine_preload_info { void *addr; size_t size; };

void __wine_main(int argc, char **argv)
{
    const struct wine_preload_info **exported = dlsym(RTLD_DEFAULT, "wine_main_preload_info");
    if (argc != 2 || strcmp(argv[1], "--highball-loader-smoke") || !exported || !*exported)
        exit(2);
    const struct wine_preload_info *reserved = *exported;
    if ((uintptr_t)reserved[0].addr != 0x10000 ||
        reserved[0].size != UINT64_C(0x170000000) - 0x10000 || reserved[1].size != 0)
        exit(3);
    puts("wine-loader-smoke-ok");
    exit(0);
}
