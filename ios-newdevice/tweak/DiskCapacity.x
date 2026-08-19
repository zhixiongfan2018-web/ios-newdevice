#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <sys/mount.h>
#import <dlfcn.h>
#import <substrate.h>
#import "NDTweakState.h"
#import "NDSafeLoad.h"

%group NDDiskCapacity
%hook NSFileManager
- (NSDictionary *)attributesOfFileSystemForPath:(NSString *)path error:(NSError **)error {
    NSDictionary *orig = %orig;
    NDTweakState *st = [NDTweakState shared];
    if (![st shouldSpoof] || !st.config.fakeDeviceModel || st.profile.DiskCapacity == 0) return orig;
    if (![orig isKindOfClass:[NSDictionary class]]) return orig;
    NSMutableDictionary *m = [orig mutableCopy];
    uint64_t cap = st.profile.DiskCapacity;
    // Keep free space plausible: 15–55% of capacity based on existing ratio when possible
    uint64_t free = cap / 3;
    NSNumber *oldSize = orig[NSFileSystemSize];
    NSNumber *oldFree = orig[NSFileSystemFreeSize];
    if (oldSize && oldFree && [oldSize unsignedLongLongValue] > 0) {
        double ratio = (double)[oldFree unsignedLongLongValue] / (double)[oldSize unsignedLongLongValue];
        if (ratio > 0.05 && ratio < 0.95) free = (uint64_t)(cap * ratio);
    }
    m[NSFileSystemSize] = @(cap);
    m[NSFileSystemFreeSize] = @(free);
    m[NSFileSystemFreeNodes] = orig[NSFileSystemFreeNodes] ?: @0;
    return m;
}
%end
%end // NDDiskCapacity

static int (*orig_statfs)(const char *, struct statfs *);
static int (*orig_statfs64)(const char *, struct statfs *);

static void NDPatchStatfs(struct statfs *buf) {
    if (!buf) return;
    NDTweakState *st = [NDTweakState shared];
    if (![st shouldSpoof] || !st.config.fakeDeviceModel || st.profile.DiskCapacity == 0) return;
    uint64_t bsize = buf->f_bsize ? buf->f_bsize : 4096;
    uint64_t blocks = st.profile.DiskCapacity / bsize;
    if (blocks == 0) return;
    double ratio = (buf->f_blocks > 0) ? ((double)buf->f_bfree / (double)buf->f_blocks) : 0.33;
    if (ratio < 0.05 || ratio > 0.95) ratio = 0.33;
    buf->f_blocks = blocks;
    buf->f_bfree = (uint64_t)(blocks * ratio);
    buf->f_bavail = buf->f_bfree;
}

static int hooked_statfs(const char *path, struct statfs *buf) {
    int rc = orig_statfs ? orig_statfs(path, buf) : -1;
    if (rc == 0) NDPatchStatfs(buf);
    return rc;
}

static int hooked_statfs64(const char *path, struct statfs *buf) {
    int rc = orig_statfs64 ? orig_statfs64(path, buf) : -1;
    if (rc == 0) NDPatchStatfs(buf);
    return rc;
}

%ctor {
    if (!NDIsPrizePicksHost()) {
        NDRunAfterUIKitReady(^{
            %init(NDDiskCapacity);
        });
    }
    NDRunRiskyCHooksAfterUIKitReady(^{
        void *s = dlsym(RTLD_DEFAULT, "statfs");
        if (s) MSHookFunction(s, (void *)hooked_statfs, (void **)&orig_statfs);
        void *s64 = dlsym(RTLD_DEFAULT, "statfs64");
        if (s64) MSHookFunction(s64, (void *)hooked_statfs64, (void **)&orig_statfs64);
    });
}
