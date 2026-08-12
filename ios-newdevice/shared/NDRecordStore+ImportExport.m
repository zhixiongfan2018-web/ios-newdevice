#import "NDRecordStore+ImportExport.h"
#import "NDRecordStore.h"
#import "NDPaths.h"
#import "NDConfig.h"
#import "NDAppDataManager.h"
#import "NDDeviceProfile.h"
#import <spawn.h>
#import <sys/wait.h>

extern char **environ;

@implementation NDRecordStore (ImportExport)

+ (NSString *)amgTarPath { return @"/var/mobile/AMG_tar"; }
+ (NSString *)amgMediaImportPath { return @"/var/mobile/Media/AMG/import"; }
+ (NSString *)amgMediaExportPath { return @"/var/mobile/Media/AMG/export"; }
+ (NSString *)iGrimaceImportPath { return @"/var/mobile/iGrimace"; }
+ (NSString *)awzImportPath { return @"/var/mobile/importdata"; }

+ (NSString *)resolvedAMGImportPath {
    NSFileManager *fm = [NSFileManager defaultManager];
    NSArray *candidates = @[
        [self amgTarPath],
        [self amgMediaImportPath],
        @"/var/mobile/Media/AMG",
        @"/var/mobile/AMG",
    ];
    for (NSString *p in candidates) {
        BOOL isDir = NO;
        if ([fm fileExistsAtPath:p isDirectory:&isDir] && isDir) return p;
    }
    return [self amgTarPath];
}

- (BOOL)NDSpawn:(const char *)path args:(char *const[])argv {
    pid_t pid = 0;
    if (posix_spawn(&pid, path, NULL, NULL, argv, environ) != 0) return NO;
    if (pid > 0) {
        int status = 0;
        waitpid(pid, &status, 0);
        return WIFEXITED(status) && WEXITSTATUS(status) == 0;
    }
    return NO;
}

- (BOOL)NDExtractArchive:(NSString *)archive toDirectory:(NSString *)dest {
    NSFileManager *fm = [NSFileManager defaultManager];
    [fm createDirectoryAtPath:dest withIntermediateDirectories:YES attributes:nil error:nil];
    NSString *lower = archive.lowercaseString;
    const char *tarBins[] = { "/var/jb/usr/bin/tar", "/usr/bin/tar", "/bin/tar", NULL };
    const char *unzipBins[] = { "/var/jb/usr/bin/unzip", "/usr/bin/unzip", NULL };

    if ([lower hasSuffix:@".zip"]) {
        for (const char **b = unzipBins; *b; b++) {
            NSString *bin = [NSString stringWithUTF8String:*b];
            if (![fm fileExistsAtPath:bin]) continue;
            char *argv[] = { (char *)*b, "-o", (char *)archive.fileSystemRepresentation, "-d", (char *)dest.fileSystemRepresentation, NULL };
            if ([self NDSpawn:*b args:argv]) return YES;
        }
        return NO;
    }

    // .tar / .tar.gz / .tgz (AMG packs into AMG_tar)
    for (const char **b = tarBins; *b; b++) {
        NSString *bin = [NSString stringWithUTF8String:*b];
        if (![fm fileExistsAtPath:bin]) continue;
        if ([lower hasSuffix:@".tar.gz"] || [lower hasSuffix:@".tgz"]) {
            char *argv[] = { (char *)*b, "-xzf", (char *)archive.fileSystemRepresentation, "-C", (char *)dest.fileSystemRepresentation, NULL };
            if ([self NDSpawn:*b args:argv]) return YES;
        } else if ([lower hasSuffix:@".tar"]) {
            char *argv[] = { (char *)*b, "-xf", (char *)archive.fileSystemRepresentation, "-C", (char *)dest.fileSystemRepresentation, NULL };
            if ([self NDSpawn:*b args:argv]) return YES;
        }
    }
    return NO;
}

- (NSUInteger)NDImportUnpackedTree:(NSString *)dir
                     importKeychain:(BOOL)importKeychain
                              error:(NSError **)error {
    BOOL prev = [NDConfig shared].importKeychainWithData;
    [NDConfig shared].importKeychainWithData = importKeychain;
    NSUInteger n = [self importAMGRecordsFromDirectory:dir error:error];
    [NDConfig shared].importKeychainWithData = prev;
    return n;
}

- (NSUInteger)importAMGRecordsFromDirectory:(NSString *)dir
                              importKeychain:(BOOL)importKeychain
                                       error:(NSError **)error {
    if (!dir.length) dir = [[self class] resolvedAMGImportPath];
    NSFileManager *fm = [NSFileManager defaultManager];
    BOOL isDir = NO;
    if (![fm fileExistsAtPath:dir isDirectory:&isDir] || !isDir) {
        if (error) *error = [NSError errorWithDomain:@"NDRecordStore" code:30 userInfo:@{NSLocalizedDescriptionKey: [NSString stringWithFormat:@"AMG 导入目录不存在: %@\n请把 AMG「导出」的包放到 /var/mobile/AMG_tar", dir]}];
        return 0;
    }

    NSUInteger total = 0;
    // 1) Folder trees (and nested record dirs)
    total += [self NDImportUnpackedTree:dir importKeychain:importKeychain error:error];

    // 2) Archives that official AMG dumps into AMG_tar (no manual decrypt)
    NSArray *entries = [fm contentsOfDirectoryAtPath:dir error:nil] ?: @[];
    NSString *scratchRoot = [NSTemporaryDirectory() stringByAppendingPathComponent:@"nd-amg-import"];
    [fm createDirectoryAtPath:scratchRoot withIntermediateDirectories:YES attributes:nil error:nil];

    for (NSString *entry in entries) {
        NSString *lower = entry.lowercaseString;
        BOOL isArchive = [lower hasSuffix:@".tar.gz"] || [lower hasSuffix:@".tgz"] || [lower hasSuffix:@".tar"] || [lower hasSuffix:@".zip"] || [lower hasSuffix:@".gz"];
        if (!isArchive) continue;
        NSString *archive = [dir stringByAppendingPathComponent:entry];
        NSString *dest = [scratchRoot stringByAppendingPathComponent:[[entry stringByDeletingPathExtension] stringByDeletingPathExtension]];
        [fm removeItemAtPath:dest error:nil];
        if (![self NDExtractArchive:archive toDirectory:dest]) continue;

        // Archives often wrap var/mobile/AMG/<record>/ — walk a few levels for faker.plist / record folders
        NSString *importRoot = dest;
        NSString *nestedAMG = [dest stringByAppendingPathComponent:@"var/mobile/AMG"];
        if ([fm fileExistsAtPath:nestedAMG]) importRoot = nestedAMG;
        else {
            NSString *nestedTar = [dest stringByAppendingPathComponent:@"var/mobile/AMG_tar"];
            if ([fm fileExistsAtPath:nestedTar]) importRoot = nestedTar;
        }
        total += [self NDImportUnpackedTree:importRoot importKeychain:importKeychain error:nil];
    }

    if (total == 0 && error && !*error) {
        *error = [NSError errorWithDomain:@"NDRecordStore" code:31 userInfo:@{NSLocalizedDescriptionKey: @"未找到可导入的 AMG 记录。请使用 AMG「导出 AMG 数据」得到的包放到 /var/mobile/AMG_tar，不要只拷运行时目录 /var/mobile/AMG（其中 faker.plist 为落盘密文）。"}];
    }
    return total;
}

- (NSUInteger)importForeignRecordsFromDirectory:(NSString *)dir
                                           kind:(NSString *)kind
                                  importKeychain:(BOOL)importKeychain
                                           error:(NSError **)error {
    if (!dir.length) {
        if ([kind.lowercaseString containsString:@"awz"]) dir = [NDRecordStore awzImportPath];
        else if ([kind.lowercaseString containsString:@"grimace"] || [kind.lowercaseString containsString:@"igrimace"]) dir = [NDRecordStore iGrimaceImportPath];
        else dir = [NDRecordStore resolvedAMGImportPath];
    }
    NSFileManager *fm = [NSFileManager defaultManager];
    BOOL isDir = NO;
    if (![fm fileExistsAtPath:dir isDirectory:&isDir] || !isDir) {
        if (error) *error = [NSError errorWithDomain:@"NDRecordStore" code:30 userInfo:@{NSLocalizedDescriptionKey: [NSString stringWithFormat:@"%@ 目录不存在: %@", kind ?: @"数据", dir]}];
        return 0;
    }
    if ([kind.lowercaseString containsString:@"amg"]) {
        return [self importAMGRecordsFromDirectory:dir importKeychain:importKeychain error:error];
    }
    return [self NDImportUnpackedTree:dir importKeychain:importKeychain error:error];
}

- (BOOL)NDCopyTree:(NSString *)src to:(NSString *)dst {
    NSFileManager *fm = [NSFileManager defaultManager];
    if (![fm fileExistsAtPath:src]) return YES;
    [fm removeItemAtPath:dst error:nil];
    NSString *parent = [dst stringByDeletingLastPathComponent];
    [fm createDirectoryAtPath:parent withIntermediateDirectories:YES attributes:nil error:nil];
    return [fm copyItemAtPath:src toPath:dst error:nil];
}

- (NSUInteger)exportAMGRecordsToDirectory:(NSString *)dir
                                     slim:(BOOL)slim
                                    error:(NSError **)error {
    if (!dir.length) dir = [NDRecordStore amgTarPath];
    NSFileManager *fm = [NSFileManager defaultManager];
    if (![fm createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:error]) return 0;

    NSUInteger exported = 0;
    NSArray *names = [self allRecordNames];
    NSArray *apps = [NDConfig shared].targetApps ?: @[];
    for (NSString *name in names) {
        if ([name isEqualToString:@"原始机器"]) continue;
        NDDeviceProfile *p = [self profileNamed:name];
        if (!p) continue;
        NSString *out = [dir stringByAppendingPathComponent:name];
        [fm removeItemAtPath:out error:nil];
        // Plaintext faker — re-import does NOT need decryption
        if (![p writeAMGFakerToDirectory:out error:nil]) continue;

        NSDictionary *desc = @{
            @"title": name,
            @"appName": apps ?: @[],
        };
        [desc writeToFile:[out stringByAppendingPathComponent:@"description.plist"] atomically:YES];
        [apps writeToFile:[out stringByAppendingPathComponent:@"selectApp.plist"] atomically:YES];

        NSString *ifa = [NDPaths ifaddrsPathForRecord:name];
        if ([fm fileExistsAtPath:ifa]) {
            [self NDCopyTree:ifa to:[out stringByAppendingPathComponent:@"ifaddrs.plist"]];
        }
        NSString *pb = [NDPaths pasteboardDirForRecord:name];
        if ([fm fileExistsAtPath:pb]) {
            [self NDCopyTree:pb to:[out stringByAppendingPathComponent:@"Pasteboard"]];
        }
        NSString *ag = [[NDPaths recordDir:name] stringByAppendingPathComponent:@"AppGroup"];
        if ([fm fileExistsAtPath:ag]) {
            [self NDCopyTree:ag to:[out stringByAppendingPathComponent:@"AppGroup"]];
        }

        for (NSString *bid in apps) {
            NSString *src = [NDPaths appsBackupDirForRecord:name bundleId:bid];
            if (![fm fileExistsAtPath:src]) continue;
            NSString *dst = [out stringByAppendingPathComponent:bid];
            [self NDCopyTree:src to:dst];
        }

        if (slim || [NDConfig shared].slimExportStripMedia) {
            [[NDAppDataManager shared] slimMediaInDirectory:out];
        }
        exported++;
    }
    return exported;
}

- (BOOL)slimRecord:(NSString *)name error:(NSError **)error {
    if (!name.length) return NO;
    NSString *root = [NDPaths recordDir:name];
    [[NDAppDataManager shared] slimMediaInDirectory:root];
    return YES;
}

@end
