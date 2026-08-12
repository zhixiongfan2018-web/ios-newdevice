#import "NDRecordStore+ImportExport.h"
#import "NDRecordStore.h"
#import "NDPaths.h"
#import "NDConfig.h"
#import "NDAppDataManager.h"
#import "NDDeviceProfile.h"

@implementation NDRecordStore (ImportExport)

+ (NSString *)amgMediaImportPath { return @"/var/mobile/Media/AMG/import"; }
+ (NSString *)amgMediaExportPath { return @"/var/mobile/Media/AMG/export"; }
+ (NSString *)iGrimaceImportPath { return @"/var/mobile/iGrimace"; }
+ (NSString *)awzImportPath { return @"/var/mobile/importdata"; }

- (NSUInteger)importAMGRecordsFromDirectory:(NSString *)dir
                              importKeychain:(BOOL)importKeychain
                                       error:(NSError **)error {
    BOOL prev = [NDConfig shared].importKeychainWithData;
    [NDConfig shared].importKeychainWithData = importKeychain;
    NSUInteger n = [self importAMGRecordsFromDirectory:dir error:error];
    [NDConfig shared].importKeychainWithData = prev;
    return n;
}

- (NSUInteger)importForeignRecordsFromDirectory:(NSString *)dir
                                           kind:(NSString *)kind
                                  importKeychain:(BOOL)importKeychain
                                           error:(NSError **)error {
    // AWZ / iGrimace dumps are folder trees with identity plists; reuse AMG importer.
    if (!dir.length) {
        if ([kind.lowercaseString containsString:@"awz"]) dir = [NDRecordStore awzImportPath];
        else if ([kind.lowercaseString containsString:@"grimace"] || [kind.lowercaseString containsString:@"igrimace"]) dir = [NDRecordStore iGrimaceImportPath];
        else dir = [NDRecordStore amgMediaImportPath];
    }
    NSFileManager *fm = [NSFileManager defaultManager];
    BOOL isDir = NO;
    if (![fm fileExistsAtPath:dir isDirectory:&isDir] || !isDir) {
        if (error) *error = [NSError errorWithDomain:@"NDRecordStore" code:30 userInfo:@{NSLocalizedDescriptionKey: [NSString stringWithFormat:@"%@ 目录不存在: %@", kind ?: @"数据", dir]}];
        return 0;
    }
    return [self importAMGRecordsFromDirectory:dir importKeychain:importKeychain error:error];
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
    if (!dir.length) dir = [NDRecordStore amgMediaExportPath];
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
        if (![p writeAMGFakerToDirectory:out error:nil]) continue;

        // description with target app display names
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

        // Holographic apps: Records/<name>/apps/<bid> → export/<name>/<bid>
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
