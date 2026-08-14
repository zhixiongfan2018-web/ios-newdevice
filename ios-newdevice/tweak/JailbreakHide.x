#import <Foundation/Foundation.h>
#import <dlfcn.h>
#import <sys/stat.h>
#import <unistd.h>
#import <errno.h>
#import <stdlib.h>
#import <string.h>
#import <mach-o/dyld.h>
#import <substrate.h>
#import "NDTweakState.h"
#import "NDSafeLoad.h"

static NSArray<NSString *> *NDJBPaths(void) {
    return @[
        @"/Applications/Cydia.app",
        @"/Applications/Sileo.app",
        @"/Applications/Zebra.app",
        @"/Applications/Dopamine.app",
        @"/Library/MobileSubstrate/MobileSubstrate.dylib",
        @"/usr/sbin/sshd",
        @"/usr/bin/ssh",
        @"/bin/bash",
        @"/etc/apt",
        @"/var/jb",
        @"/var/lib/dpkg",
        @"/private/var/lib/cydia",
        @"/private/preboot",
        @"/usr/lib/libsubstrate.dylib",
        @"/usr/lib/libellekit.dylib",
        @"/var/jb/usr/lib/libellekit.dylib",
        @"/var/jb/Library/Frameworks",
        @"/Library/Frameworks/CydiaSubstrate.framework",
    ];
}

static BOOL NDIsJBPath(const char *path) {
    if (!path) return NO;
    NSString *p = [NSString stringWithUTF8String:path];
    for (NSString *jb in NDJBPaths()) {
        if ([p isEqualToString:jb] || [p hasPrefix:[jb stringByAppendingString:@"/"]]) return YES;
    }
    if ([p containsString:@"MobileSubstrate"] || [p containsString:@"/ellekit"] || [p containsString:@"libsubstrate"]) return YES;
    if ([p containsString:@"TweakInject"] || [p containsString:@"NewDevice.dylib"]) return YES;
    if ([p containsString:@"substitute"] || [p containsString:@"libhooker"]) return YES;
    return NO;
}

static BOOL NDDeepHideActive(void) {
    NDTweakState *st = [NDTweakState shared];
    return [st shouldSpoof] && st.config.jailbreakHideDeep;
}

static BOOL NDBasicHideActive(void) {
    NDTweakState *st = [NDTweakState shared];
    return [st shouldSpoof] && st.config.jailbreakHideBasic;
}

static int (*orig_stat)(const char *, struct stat *);
static int hooked_stat(const char *path, struct stat *buf) {
    if (NDBasicHideActive() && NDIsJBPath(path)) {
        errno = ENOENT;
        return -1;
    }
    return orig_stat(path, buf);
}

static int (*orig_lstat)(const char *, struct stat *);
static int hooked_lstat(const char *path, struct stat *buf) {
    if (NDBasicHideActive() && NDIsJBPath(path)) {
        errno = ENOENT;
        return -1;
    }
    return orig_lstat(path, buf);
}

static int (*orig_access)(const char *, int);
static int hooked_access(const char *path, int mode) {
    if (NDBasicHideActive() && NDIsJBPath(path)) {
        errno = ENOENT;
        return -1;
    }
    return orig_access(path, mode);
}

static FILE *(*orig_fopen)(const char *, const char *);
static FILE *hooked_fopen(const char *path, const char *mode) {
    if (NDBasicHideActive() && NDIsJBPath(path)) {
        errno = ENOENT;
        return NULL;
    }
    return orig_fopen(path, mode);
}

%group NDJailbreakHide
%hook NSFileManager
- (BOOL)fileExistsAtPath:(NSString *)path {
    if (NDBasicHideActive() && path.length && NDIsJBPath(path.fileSystemRepresentation)) {
        return NO;
    }
    return %orig;
}
- (BOOL)fileExistsAtPath:(NSString *)path isDirectory:(BOOL *)isDirectory {
    if (NDBasicHideActive() && path.length && NDIsJBPath(path.fileSystemRepresentation)) {
        if (isDirectory) *isDirectory = NO;
        return NO;
    }
    return %orig;
}
%end
%end // NDJailbreakHide

static const char *(*orig_dyld_get_image_name)(uint32_t);
static uint32_t (*orig_dyld_image_count)(void);

static uint32_t NDRealIndexForVisible(uint32_t visible) {
    uint32_t realCount = orig_dyld_image_count ? orig_dyld_image_count() : 0;
    uint32_t seen = 0;
    for (uint32_t i = 0; i < realCount; i++) {
        const char *n = orig_dyld_get_image_name ? orig_dyld_get_image_name(i) : NULL;
        if (n && NDIsJBPath(n)) continue;
        if (seen == visible) return i;
        seen++;
    }
    return 0;
}

static uint32_t hooked_dyld_image_count(void) {
    uint32_t real = orig_dyld_image_count ? orig_dyld_image_count() : 0;
    if (!NDDeepHideActive()) return real;
    uint32_t hide = 0;
    for (uint32_t i = 0; i < real; i++) {
        const char *n = orig_dyld_get_image_name ? orig_dyld_get_image_name(i) : NULL;
        if (n && NDIsJBPath(n)) hide++;
    }
    return (real > hide) ? (real - hide) : 0;
}

static const char *hooked_dyld_get_image_name(uint32_t image_index) {
    if (NDDeepHideActive()) {
        uint32_t realIdx = NDRealIndexForVisible(image_index);
        return orig_dyld_get_image_name ? orig_dyld_get_image_name(realIdx) : NULL;
    }
    const char *name = orig_dyld_get_image_name ? orig_dyld_get_image_name(image_index) : NULL;
    // Basic mode: rename instead of removing (safer)
    NDTweakState *st = [NDTweakState shared];
    if ([st shouldSpoof] && st.config.jailbreakHideBasic && name && NDIsJBPath(name)) {
        return "/usr/lib/system/libsystem_c.dylib";
    }
    return name;
}

static char *(*orig_getenv)(const char *);
static char *hooked_getenv(const char *name) {
    if (NDDeepHideActive() && name) {
        if (strcmp(name, "DYLD_INSERT_LIBRARIES") == 0 ||
            strcmp(name, "DYLD_LIBRARY_PATH") == 0 ||
            strcmp(name, "DYLD_FORCE_FLAT_NAMESPACE") == 0 ||
            strcmp(name, "_MSSafeMode") == 0) {
            return NULL;
        }
    }
    return orig_getenv ? orig_getenv(name) : NULL;
}

static pid_t (*orig_fork)(void);
static pid_t hooked_fork(void) {
    if (NDDeepHideActive()) {
        errno = ENOSYS;
        return -1;
    }
    return orig_fork();
}
%ctor {
    NDRunAfterUIKitReady(^{
        %init(NDJailbreakHide);
        MSHookFunction((void *)stat, (void *)hooked_stat, (void **)&orig_stat);
        MSHookFunction((void *)lstat, (void *)hooked_lstat, (void **)&orig_lstat);
        MSHookFunction((void *)access, (void *)hooked_access, (void **)&orig_access);
        MSHookFunction((void *)fopen, (void *)hooked_fopen, (void **)&orig_fopen);
        MSHookFunction((void *)_dyld_get_image_name, (void *)hooked_dyld_get_image_name, (void **)&orig_dyld_get_image_name);
        MSHookFunction((void *)_dyld_image_count, (void *)hooked_dyld_image_count, (void **)&orig_dyld_image_count);
        MSHookFunction((void *)getenv, (void *)hooked_getenv, (void **)&orig_getenv);
        MSHookFunction((void *)fork, (void *)hooked_fork, (void **)&orig_fork);
    });
}
