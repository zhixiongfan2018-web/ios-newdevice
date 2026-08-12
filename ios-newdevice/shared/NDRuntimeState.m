#import "NDRuntimeState.h"
#import "NDPaths.h"

@implementation NDRuntimeState

+ (void)publishWithConfig:(NDConfig *)config
                  profile:(NDDeviceProfile *)profile
              currentName:(NSString *)currentName {
    if (!config) return;
    [NDPaths ensureDirectories];
    NSMutableDictionary *dict = [@{
        @"v": @1,
        @"fakeDeviceModel": @(config.fakeDeviceModel),
        @"fakeSystemVer": @(config.fakeSystemVer),
        @"fakeCarrier": @(config.fakeCarrier),
        @"spoofLocation": @(config.spoofLocation),
        @"randomLocation": @(config.randomLocation),
        @"smartLocationOffset": @(config.smartLocationOffset),
        @"smartAirplane": @(config.smartAirplane),
        @"jailbreakHideBasic": @(config.jailbreakHideBasic),
        @"jailbreakHideDeep": @(config.jailbreakHideDeep),
        @"holographicBackup": @(config.holographicBackup),
        @"targetApps": config.targetApps ?: @[],
        @"currentRecord": currentName ?: @"",
    } mutableCopy];
    if (profile) {
        dict[@"profile"] = [profile toDictionary];
    }
    NSString *path = [NDPaths runtimeStatePath];
    NSString *dir = [path stringByDeletingLastPathComponent];
    [[NSFileManager defaultManager] createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:@{NSFilePosixPermissions: @0755} error:nil];
    [dict writeToFile:path atomically:YES];
    [NDPaths makePathWorldReadable:dir];
    [NDPaths makePathWorldReadable:path];
    // Also relax preferences copies used as fallback
    [NDPaths makePathWorldReadable:[NDPaths preferencesDir]];
    [NDPaths makePathWorldReadable:[NDPaths configPlistPath]];
    [NDPaths makePathWorldReadable:[NDPaths currentRecordPointerPath]];
    if (currentName.length) {
        [NDPaths makePathWorldReadable:[NDPaths profilePathForRecord:currentName]];
        [NDPaths makePathWorldReadable:[NDPaths recordDir:currentName]];
    }
}

+ (NSDictionary *)dictionary {
    NSDictionary *dict = [NSDictionary dictionaryWithContentsOfFile:[NDPaths runtimeStatePath]];
    return [dict isKindOfClass:[NSDictionary class]] ? dict : nil;
}

+ (NDDeviceProfile *)profileFromDictionary:(NSDictionary *)dict {
    id profileDict = dict[@"profile"];
    if (![profileDict isKindOfClass:[NSDictionary class]]) return nil;
    return [NDDeviceProfile profileFromDictionary:profileDict];
}

@end
