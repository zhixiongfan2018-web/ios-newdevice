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

/// Join jb prefix with an absolute rooted path like "/var/mobile/..."
+ (NSString *)jbPath:(NSString *)absolutePath {
    NSString *prefix = [self jbPrefix];
    if (!absolutePath.length) return prefix ?: @"";
    if (!prefix.length) return absolutePath;
    if ([absolutePath hasPrefix:prefix]) return absolutePath;
    return [prefix stringByAppendingString:absolutePath];
}

+ (NSString *)preferencesDir {
    return [self jbPath:@"/var/mobile/Library/Preferences/com.local.newdevice"];
}

+ (NSString *)configPlistPath {
    return [[self preferencesDir] stringByAppendingPathComponent:@"config.plist"];
}

+ (NSString *)recordsRoot {
    return [self jbPath:@"/var/mobile/NewDevice/Records"];
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

+ (NSString *)ifaddrsPathForRecord:(NSString *)name {
    return [[self recordDir:name] stringByAppendingPathComponent:@"ifaddrs.plist"];
}

+ (NSString *)pasteboardDirForRecord:(NSString *)name {
    return [[self recordDir:name] stringByAppendingPathComponent:@"Pasteboard"];
}

+ (NSString *)resultFilePath {
    return [self jbPath:@"/var/mobile/newdeviceResult.txt"];
}

+ (NSString *)currentRecordPointerPath {
    return [[self preferencesDir] stringByAppendingPathComponent:@"currentRecord.txt"];
}

+ (NSString *)lastSessionRecordPath {
    return [[self preferencesDir] stringByAppendingPathComponent:@"lastSession.txt"];
}

+ (NSString *)runtimeStateDir {
    return [self jbPath:@"/Library/NewDevice"];
}

+ (NSString *)runtimeStatePath {
    // Outside app containers; world-readable snapshot for injected tweaks
    return [[self runtimeStateDir] stringByAppendingPathComponent:@"runtime.plist"];
}

+ (void)chmodPath:(NSString *)path mode:(NSUInteger)mode {
    if (!path.length) return;
    NSFileManager *fm = [NSFileManager defaultManager];
    if (![fm fileExistsAtPath:path]) return;
    [fm setAttributes:@{NSFilePosixPermissions: @(mode)} ofItemAtPath:path error:nil];
}

+ (void)makePathWorldReadable:(NSString *)path {
    if (!path.length) return;
    NSFileManager *fm = [NSFileManager defaultManager];
    BOOL isDir = NO;
    if (![fm fileExistsAtPath:path isDirectory:&isDir]) return;
    [self chmodPath:path mode:(isDir ? 0755 : 0644)];

    // Always ensure the runtime snapshot directory chain is traversable by sandboxed apps.
    NSString *runtimeDir = [self runtimeStateDir];
    [self chmodPath:runtimeDir mode:0755];
    NSString *library = [runtimeDir stringByDeletingLastPathComponent]; // .../Library
    if ([library hasSuffix:@"/Library"]) {
        [self chmodPath:library mode:0755];
    }
}

+ (NSString *)mediaHomeDir {
    return @"/var/mobile/Media/NewDevice";
}

+ (NSString *)mediaImportDir {
    return [[self mediaHomeDir] stringByAppendingPathComponent:@"import"];
}

+ (NSString *)mediaExportDir {
    return [[self mediaHomeDir] stringByAppendingPathComponent:@"export"];
}

+ (void)ensureDirectories {
    NSFileManager *fm = [NSFileManager defaultManager];
    NSArray<NSString *> *dirs = @[
        [self preferencesDir],
        [self recordsRoot],
        [self runtimeStateDir],
        // Visible in Aisi file manager (Media root)
        [self mediaHomeDir],
        [self mediaImportDir],
        [self mediaExportDir],
        @"/var/mobile/Media/AMG/import",
        @"/var/mobile/Media/AMG/export",
        @"/var/mobile/AMG_tar",
    ];
    for (NSString *dir in dirs) {
        if (![fm fileExistsAtPath:dir]) {
            [fm createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:@{NSFilePosixPermissions: @0755} error:nil];
        }
        [self makePathWorldReadable:dir];
    }

    // Drop a short readme so the folder is obvious in Aisi
    NSString *readme = [[self mediaHomeDir] stringByAppendingPathComponent:@"使用说明.txt"];
    if (![fm fileExistsAtPath:readme]) {
        NSString *text =
            @"NewDevice 用户目录（爱思「文件管理」可见）\n"
            @"\n"
            @"import/  把要导入的 .tar.gz 放这里，然后打开 App → 工具 → 导入\n"
            @"export/  App「导出」生成经典 AMG 包（.tar.gz，路径 var/mobile/AMG/…）\n"
            @"\n"
            @"内部运行数据在越狱路径，不在此显示：\n"
            @"/var/jb/var/mobile/NewDevice/Records\n";
        [text writeToFile:readme atomically:YES encoding:NSUTF8StringEncoding error:nil];
        [self makePathWorldReadable:readme];
    }
}

@end
