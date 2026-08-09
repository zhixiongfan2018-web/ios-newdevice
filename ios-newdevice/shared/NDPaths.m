#import "NDPaths.h"

NSString * const NDBundleID = @"com.local.newdevice";
NSString * const NDNotifyReload = @"com.local.newdevice.reload";
NSString * const NDHTTPHost = @"127.0.0.1";
NSInteger const NDHTTPPort = 8080;

@implementation NDPaths

+ (NSString *)jbPrefix {
    static NSString *prefix;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        if ([[NSFileManager defaultManager] fileExistsAtPath:@"/var/jb"]) {
            prefix = @"/var/jb";
        } else {
            prefix = @"";
        }
    });
    return prefix;
}

+ (NSString *)preferencesDir {
    return [[self jbPrefix] stringByAppendingPathComponent:@"/var/mobile/Library/Preferences/com.local.newdevice"];
}

+ (NSString *)configPlistPath {
    return [[self preferencesDir] stringByAppendingPathComponent:@"config.plist"];
}

+ (NSString *)recordsRoot {
    return [[self jbPrefix] stringByAppendingPathComponent:@"/var/mobile/NewDevice/Records"];
}

+ (NSString *)recordDir:(NSString *)name {
    return [[self recordsRoot] stringByAppendingPathComponent:name];
}

+ (NSString *)profilePathForRecord:(NSString *)name {
    return [[self recordDir:name] stringByAppendingPathComponent:@"profile.plist"];
}

+ (NSString *)appsBackupDirForRecord:(NSString *)name bundleId:(NSString *)bundleId {
    return [[[self recordDir:name] stringByAppendingPathComponent:@"apps"] stringByAppendingPathComponent:bundleId];
}

+ (NSString *)resultFilePath {
    return [[self jbPrefix] stringByAppendingPathComponent:@"/var/mobile/newdeviceResult.txt"];
}

+ (NSString *)currentRecordPointerPath {
    return [[self preferencesDir] stringByAppendingPathComponent:@"currentRecord.txt"];
}

+ (void)ensureDirectories {
    NSFileManager *fm = [NSFileManager defaultManager];
    NSArray<NSString *> *dirs = @[
        [self preferencesDir],
        [self recordsRoot],
    ];
    for (NSString *dir in dirs) {
        if (![fm fileExistsAtPath:dir]) {
            [fm createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:@{NSFilePosixPermissions: @0755} error:nil];
        }
    }
}

@end
