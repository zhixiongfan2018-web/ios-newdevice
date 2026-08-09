#import <Foundation/Foundation.h>
#import <dlfcn.h>
#import <sys/stat.h>
#import <unistd.h>
#import <errno.h>
#import <mach-o/dyld.h>
#import <substrate.h>
#import "NDTweakState.h"

static NSArray<NSString *> *NDJBPaths(void) {
    return @[
        @"/Applications/Cydia.app",
        @"/Applications/Sileo.app",
        @"/Applications/Zebra.app",
        @"/Library/MobileSubstrate/MobileSubstrate.dylib",
        @"/usr/sbin/sshd",
        @"/usr/bin/ssh",
        @"/bin/bash",
        @"/etc/apt",
        @"/var/jb",
        @"/var/lib/dpkg",
        @"/private/var/lib/cydia",
        @"/usr/lib/libsubstrate.dylib",
        @"/usr/lib/libellekit.dylib",
        @"/var/jb/usr/lib/libellekit.dylib",
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
    return NO;
}

static int (*orig_stat)(const char *, struct stat *);
static int hooked_stat(const char *path, struct stat *buf) {
    NDTweakState *st = [NDTweakState shared];
    if ([st shouldSpoof] && st.config.jailbreakHideBasic && NDIsJBPath(path)) {
        errno = ENOENT;
        return -1;
    }
    return orig_stat(path, buf);
}

static int (*orig_access)(const char *, int);
static int hooked_access(const char *path, int mode) {
    NDTweakState *st = [NDTweakState shared];
    if ([st shouldSpoof] && st.config.jailbreakHideBasic && NDIsJBPath(path)) {
        errno = ENOENT;
        return -1;
    }
    return orig_access(path, mode);
}

static FILE *(*orig_fopen)(const char *, const char *);
static FILE *hooked_fopen(const char *path, const char *mode) {
    NDTweakState *st = [NDTweakState shared];
    if ([st shouldSpoof] && st.config.jailbreakHideBasic && NDIsJBPath(path)) {
        errno = ENOENT;
        return NULL;
    }
    return orig_fopen(path, mode);
}

%hook NSFileManager
- (BOOL)fileExistsAtPath:(NSString *)path {
    NDTweakState *st = [NDTweakState shared];
    if ([st shouldSpoof] && st.config.jailbreakHideBasic && path.length && NDIsJBPath(path.fileSystemRepresentation)) {
        return NO;
    }
    return %orig;
}
- (BOOL)fileExistsAtPath:(NSString *)path isDirectory:(BOOL *)isDirectory {
    NDTweakState *st = [NDTweakState shared];
    if ([st shouldSpoof] && st.config.jailbreakHideBasic && path.length && NDIsJBPath(path.fileSystemRepresentation)) {
        if (isDirectory) *isDirectory = NO;
        return NO;
    }
    return %orig;
}
%end

static const char *(*orig_dyld_get_image_name)(uint32_t);
static const char *hooked_dyld_get_image_name(uint32_t image_index) {
    const char *name = orig_dyld_get_image_name(image_index);
    NDTweakState *st = [NDTweakState shared];
    if ([st shouldSpoof] && st.config.jailbreakHideDeep && name && NDIsJBPath(name)) {
        return "/usr/lib/system/libsystem_c.dylib";
    }
    return name;
}

static pid_t (*orig_fork)(void);
static pid_t hooked_fork(void) {
    NDTweakState *st = [NDTweakState shared];
    if ([st shouldSpoof] && st.config.jailbreakHideDeep) {
        errno = ENOSYS;
        return -1;
    }
    return orig_fork();
}

%ctor {
    MSHookFunction((void *)stat, (void *)hooked_stat, (void **)&orig_stat);
    MSHookFunction((void *)access, (void *)hooked_access, (void **)&orig_access);
    MSHookFunction((void *)fopen, (void *)hooked_fopen, (void **)&orig_fopen);
    MSHookFunction((void *)_dyld_get_image_name, (void *)hooked_dyld_get_image_name, (void **)&orig_dyld_get_image_name);
    MSHookFunction((void *)fork, (void *)hooked_fork, (void **)&orig_fork);
}
