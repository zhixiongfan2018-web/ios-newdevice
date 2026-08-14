#import <Foundation/Foundation.h>
#import "NDTweakState.h"
#import "NDSafeLoad.h"

/// ObjC-only jailbreak path hide.
/// C hooks on stat/lstat/access/fopen/dyld were removed: on iOS 18 + ElleKit they
/// SIGILL inside Venmo (sqlite/CFNetwork call lstat during launch).

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

static BOOL NDBasicHideActive(void) {
    NDTweakState *st = [NDTweakState shared];
    return [st shouldSpoof] && st.config.jailbreakHideBasic;
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

%ctor {
    NDRunAfterUIKitReady(^{
        %init(NDJailbreakHide);
    });
}
