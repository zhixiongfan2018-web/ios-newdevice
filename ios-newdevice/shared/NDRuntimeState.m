#import "NDRuntimeState.h"
#import "NDPaths.h"
#import "NDIfaddrsFingerprint.h"

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
        @"locationFromIP": @(config.locationFromIP),
        @"smartLocationOffset": @(config.smartLocationOffset),
        @"smartAirplane": @(config.smartAirplane),
        @"jailbreakHideBasic": @(config.jailbreakHideBasic),
        @"jailbreakHideDeep": @(config.jailbreakHideDeep),
        @"holographicBackup": @(config.holographicBackup),
        @"allowIPadSpoof": @(config.allowIPadSpoof),
        @"clearPasteboardOnSwitch": @(config.clearPasteboardOnSwitch),
        @"importKeychainWithData": @(config.importKeychainWithData),
        @"slimExportStripMedia": @(config.slimExportStripMedia),
        @"targetApps": config.targetApps ?: @[],
        @"currentRecord": currentName ?: @"",
    } mutableCopy];
    if (profile) {
        dict[@"profile"] = [profile toDictionary];
    }

    // Publish AMG-style ifaddrs fingerprint (import or synthesize) for sandboxed tweaks
    if (currentName.length && ![currentName isEqualToString:@"原始机器"]) {
        NSDictionary *ifa = [NDIfaddrsFingerprint loadForRecord:currentName];
        if (!ifa.count && profile) {
            ifa = [NDIfaddrsFingerprint synthesizeFromProfileWiFiMAC:profile.WiFiMAC];
        }
        if (ifa.count && profile.WiFiMAC.length) {
            NSMutableDictionary *mutableIfa = [ifa mutableCopy];
            NSMutableDictionary *en0 = [mutableIfa[@"en0"] isKindOfClass:[NSDictionary class]]
                ? [mutableIfa[@"en0"] mutableCopy]
                : [NSMutableDictionary dictionary];
            en0[@"mac"] = profile.WiFiMAC;
            mutableIfa[@"en0"] = en0;
            ifa = mutableIfa;
        }
        if (ifa.count) {
            NSString *ifaPath = [NDPaths ifaddrsPathForRecord:currentName];
            [[NSFileManager defaultManager] createDirectoryAtPath:[NDPaths recordDir:currentName]
                                     withIntermediateDirectories:YES attributes:nil error:nil];
            [ifa writeToFile:ifaPath atomically:YES];
            dict[@"ifaddrs"] = ifa;
        }
    }

    NSString *path = [NDPaths runtimeStatePath];
    NSString *dir = [NDPaths runtimeStateDir];
    NSError *writeErr = nil;
    [[NSFileManager defaultManager] createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:@{NSFilePosixPermissions: @0755} error:&writeErr];
    BOOL wrote = [dict writeToFile:path atomically:YES];
    if (!wrote) {
        NSLog(@"[NewDevice] runtime.plist publish failed at %@", path);
    }
    [NDPaths makePathWorldReadable:dir];
    [NDPaths makePathWorldReadable:path];
    // Also relax preferences copies used as fallback (may still be unreadable in sandbox)
    [NDPaths makePathWorldReadable:[NDPaths preferencesDir]];
    [NDPaths makePathWorldReadable:[NDPaths configPlistPath]];
    [NDPaths makePathWorldReadable:[NDPaths currentRecordPointerPath]];
    if (currentName.length) {
        [NDPaths makePathWorldReadable:[NDPaths profilePathForRecord:currentName]];
        [NDPaths makePathWorldReadable:[NDPaths recordDir:currentName]];
        [NDPaths makePathWorldReadable:[NDPaths ifaddrsPathForRecord:currentName]];
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
