/*
 * Emulator initialisation code
 *
 * Copyright 2000 Alexandre Julliard
 * Copyright 2026 Gauthier Piarrette (the parts marked Highball)
 *
 * This library is free software; you can redistribute it and/or
 * modify it under the terms of the GNU Lesser General Public
 * License as published by the Free Software Foundation; either
 * version 2.1 of the License, or (at your option) any later version.
 *
 * This library is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
 * Lesser General Public License for more details.
 *
 * You should have received a copy of the GNU Lesser General Public
 * License along with this library; if not, write to the Free Software
 * Foundation, Inc., 51 Franklin St, Fifth Floor, Boston, MA 02110-1301, USA
 */

/*
 * Highball's Wine loader for arm64 macOS.
 *
 * This is Wine 11.18's loader/main.c, the `wine` program that reserves memory, loads ntdll.so and
 * hands over to __wine_main, with two changes, both marked "Highball" below:
 *
 *  1. On arm64 it hands Wine the __PAGEZERO range as its reserved low memory. Linked with a
 *     PAGEZERO of 0x170000000 and 16 KB segment alignment, and signed with Apple's
 *     cross-architecture entitlement, the kernel lets the process map there, which is where 32-bit
 *     and 64-bit Windows programs expect their memory (highball-engine patch 0018 is the same change
 *     for the engine's own, unsigned loader).
 *
 *  2. It looks for ntdll.so next to the path it was started by, one symlink hop at a time, before
 *     the resolved path. The binary lives sealed and signed inside Highball.app
 *     (Contents/Helpers/WineLoader.app); an arm64 engine points `engine/lib/wine/aarch64-unix/wine`
 *     at it and `engine/bin/wine` at that (EngineStore.linkSignedLoader). Wine's ntdll starts every
 *     child process through the first of those, and the kernel reports the exec path with its
 *     symlinks intact, so the loader finds the engine's ntdll.so without a copy of anything inside
 *     the bundle.
 *
 * Why a copy of the file rather than a patch: Scripts/make-app.sh has to build and sign this binary
 * with the Developer ID and the provisioning profile at app build time, without a Wine tree. The
 * interface it relies on (__wine_main, wine_main_preload_info) has not changed in years. Built by
 * spike/wineloader/build.sh. Measured on an M4, macOS 27.0, 2026-10-04
 * (private/notes/rosetta-transition-plan.md, section 9).
 */

#include <fcntl.h>
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/types.h>
#include <sys/stat.h>
#include <unistd.h>
#include <dlfcn.h>
#include <limits.h>
#ifdef __APPLE__
# include <mach-o/dyld.h>
#endif

struct wine_preload_info
{
    void  *addr;
    size_t size;
};

#if defined(__APPLE__) && defined(__x86_64__)

/* Not using the preloader on x86_64:
 * Reserve the same areas as the preloader does, but using zero-fill sections
 * (the only way to prevent system frameworks from using them, including allocations
 * before main() runs).
 */
__asm__(".zerofill WINE_RESERVE,WINE_RESERVE");
static char __wine_reserve[0x1fffff000] __attribute__((section("WINE_RESERVE, WINE_RESERVE")));

__asm__(".zerofill WINE_TOP_DOWN,WINE_TOP_DOWN");
static char __wine_top_down[0x001ff0000] __attribute__((section("WINE_TOP_DOWN, WINE_TOP_DOWN")));

static const struct wine_preload_info preload_info[] =
{
    { __wine_reserve,  sizeof(__wine_reserve)  }, /*         0x1000 -    0x200000000: low 8GB */
    { __wine_top_down, sizeof(__wine_top_down) }, /* 0x7ff000000000 - 0x7ff001ff0000: top-down allocations + virtual heap */
    { 0, 0 }                                      /* end of list */
};

const __attribute((visibility("default"))) struct wine_preload_info *wine_main_preload_info = preload_info;

static void init_reserved_areas(void)
{
    int i;

    for (i = 0; wine_main_preload_info[i].size != 0; i++)
    {
        /* Match how the preloader maps reserved areas: */
        mmap(wine_main_preload_info[i].addr, wine_main_preload_info[i].size, PROT_NONE,
             MAP_FIXED | MAP_NORESERVE | MAP_PRIVATE | MAP_ANON, -1, 0);
    }
}

#elif defined(__APPLE__) && defined(__aarch64__)

/* Highball: arm64 macOS has no preloader and a PAGEZERO of 4 GB or more. With the
 * cross-architecture entitlement the kernel lets the process map over __PAGEZERO, so hand that
 * range to Wine as its reserved low memory (CrossOver links its loader with a PAGEZERO of about
 * 0x170000000 for the same reason). */
#include <mach-o/loader.h>

static struct wine_preload_info preload_info[2];

const __attribute((visibility("default"))) struct wine_preload_info *wine_main_preload_info = preload_info;

/* the size of this executable's __PAGEZERO segment, from its own load commands */
static uint64_t pagezero_size(void)
{
    const struct mach_header_64 *mh = (const struct mach_header_64 *)_dyld_get_image_header( 0 );
    const struct load_command *lc = (const struct load_command *)(mh + 1);
    uint32_t i;

    for (i = 0; i < mh->ncmds; i++)
    {
        if (lc->cmd == LC_SEGMENT_64)
        {
            const struct segment_command_64 *seg = (const struct segment_command_64 *)lc;
            if (!strcmp( seg->segname, "__PAGEZERO" )) return seg->vmsize;
        }
        lc = (const struct load_command *)((const char *)lc + lc->cmdsize);
    }
    return 0;
}

static void init_reserved_areas(void)
{
    uint64_t size = pagezero_size();

    if (size > 0x10000)
    {
        preload_info[0].addr = (void *)0x10000;  /* host page aligned, Wine allocation granularity */
        preload_info[0].size = size - 0x10000;
        /* no PROT_NONE pre-mapping here: nothing else can allocate inside __PAGEZERO, and Wine
         * maps into the reserved range with MAP_FIXED and the final protection itself */
    }
}

#else

const __attribute((visibility("default"))) struct wine_preload_info *wine_main_preload_info = NULL;

static void init_reserved_areas(void)
{
}

#endif

/* canonicalize path and return its directory name */
static char *realpath_dirname( const char *name )
{
    char *p, *fullpath = realpath( name, NULL );

    if (fullpath)
    {
        p = strrchr( fullpath, '/' );
        if (p == fullpath) p++;
        if (p) *p = 0;
    }
    return fullpath;
}

/* if string ends with tail, remove it */
static char *remove_tail( const char *str, const char *tail )
{
    size_t len = strlen( str );
    size_t tail_len = strlen( tail );
    char *ret;

    if (len < tail_len) return NULL;
    if (strcmp( str + len - tail_len, tail )) return NULL;
    ret = malloc( len - tail_len + 1 );
    memcpy( ret, str, len - tail_len );
    ret[len - tail_len] = 0;
    return ret;
}

/* build a path from the specified dir and name */
static char *build_path( const char *dir, const char *name )
{
    size_t len = strlen( dir );
    char *ret = malloc( len + strlen( name ) + 2 );

    memcpy( ret, dir, len );
    if (len && ret[len - 1] != '/') ret[len++] = '/';
    strcpy( ret + len, name );
    return ret;
}

static const char *get_self_exe(void)
{
#if defined(__linux__) || defined(__FreeBSD_kernel__) || defined(__NetBSD__)
    return "/proc/self/exe";
#elif defined(__APPLE__)
    uint32_t path_size = PATH_MAX;
    char *path = malloc( path_size );
    if (path && !_NSGetExecutablePath( path, &path_size ))
        return path;
    free( path );
#endif
    return NULL;
}

/* Highball: the directory part of a path, symlinks left alone; NULL for a bare name */
static char *plain_dirname( const char *name )
{
    const char *p = strrchr( name, '/' );
    char *ret;

    if (!p) return NULL;
    if (p == name) p++;
    ret = malloc( p - name + 1 );
    memcpy( ret, name, p - name );
    ret[p - name] = 0;
    return ret;
}

/* Highball: ntdll.so beside the path we were started by, then beside each symlink target on the
 * way to the real file. An engine starts us through engine/bin/wine -> ../lib/wine/aarch64-unix/wine
 * -> Highball.app/Contents/Helpers/WineLoader.app/Contents/MacOS/wine, and ntdll.so sits in the
 * middle one; the realpath lookup below would only ever look inside the app bundle. */
static void *try_dlopen_along_links( const char *argv0 )
{
    char *current = strdup( argv0 ), *dir, *path, *target;
    void *handle = NULL;
    ssize_t len;
    int hops;

    for (hops = 0; current && hops < 8 && !handle; hops++)
    {
        if (!(dir = plain_dirname( current ))) break;
        path = build_path( dir, "ntdll.so" );
        if (!access( path, R_OK )) handle = dlopen( path, RTLD_NOW );
        free( path );
        if (handle) { free( dir ); break; }

        target = malloc( PATH_MAX );
        if ((len = readlink( current, target, PATH_MAX - 1 )) <= 0)
        {
            free( target );
            free( dir );
            break;                                      /* a real file: nothing further to follow */
        }
        target[len] = 0;
        if (target[0] == '/') { free( current ); current = target; }
        else { free( current ); current = build_path( dir, target ); free( target ); }
        free( dir );
    }
    free( current );
    return handle;
}

static void *try_dlopen( const char *argv0 )
{
    char *dir, *path, *p;
    void *handle;

    if (!argv0) return NULL;
    if ((handle = try_dlopen_along_links( argv0 ))) return handle;   /* Highball */
    if (!(dir = realpath_dirname( argv0 ))) return NULL;

    if ((p = remove_tail( dir, "/loader" )))
        path = build_path( p, "dlls/ntdll/ntdll.so" );
    else
        path = build_path( dir, "ntdll.so" );

    handle = dlopen( path, RTLD_NOW );
    free( p );
    free( dir );
    free( path );
    return handle;
}


/**********************************************************************
 *           main
 */
int main( int argc, char *argv[] )
{
    void *handle;

    init_reserved_areas();

    if ((handle = try_dlopen( get_self_exe() )) ||
        (handle = try_dlopen( argv[0] )))
    {
        void (*init_func)(int, char **) = dlsym( handle, "__wine_main" );
        if (init_func) init_func( argc, argv );
        fprintf( stderr, "wine: __wine_main function not found in ntdll.so\n" );
        exit(1);
    }

    fprintf( stderr, "wine: could not load ntdll.so: %s\n", dlerror() );
    pthread_detach( pthread_self() );  /* force importing libpthread for OpenGL */
    exit(1);
}
