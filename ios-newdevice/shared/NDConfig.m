#import "NDConfig.h"
#import "NDPaths.h"
#import "NDRuntimeState.h"
#import "NDRecordStore.h"
#import <notify.h>

@implementation NDConfig

+ (instancetype)shared {
    static NDConfig *cfg;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        cfg = [NDConfig new];
        [cfg reload];
    });
    return cfg;
}

- (void)applyDefaults {
    self.fakeDeviceModel = YES;
    self.fakeSystemVer = YES;
    self.fakeCarrier = YES;
    self.spoofLocation = YES;
    self.randomLocation = YES;
    self.locationFromIP = YES;
    self.smartLocationOffset = YES;
    self.smartAirplane = NO; // match AMG machineNewAirplaneMode=0 on this device
    // Default OFF so install/respring never hides JB paths from tooling
    self.jailbreakHideBasic = NO;
    self.jailbreakHideDeep = NO;
    self.holographicBackup = YES;
    self.allowIPadSpoof = NO;
    self.clearPasteboardOnSwitch = YES;
    self.importKeychainWithData = YES;
    self.slimExportStripMedia = NO;
    self.targetApps = @[];
    self.preferredModels = @[];
    self.preferredSystems = @[];
}

- (void)applyDictionary:(NSDictionary *)dict {
    self.fakeDeviceModel = [dict[@"fakeDeviceModel"] boolValue];
    self.fakeSystemVer = [dict[@"fakeSystemVer"] boolValue];
    self.fakeCarrier = [dict[@"fakeCarrier"] boolValue];
    self.spoofLocation = dict[@"spoofLocation"] ? [dict[@"spoofLocation"] boolValue] : YES;
    self.randomLocation = dict[@"randomLocation"] ? [dict[@"randomLocation"] boolValue] : YES;
    self.locationFromIP = dict[@"locationFromIP"] ? [dict[@"locationFromIP"] boolValue] : YES;
    self.smartLocationOffset = [dict[@"smartLocationOffset"] boolValue];
    self.smartAirplane = dict[@"smartAirplane"] ? [dict[@"smartAirplane"] boolValue] : NO;
    self.jailbreakHideBasic = dict[@"jailbreakHideBasic"] ? [dict[@"jailbreakHideBasic"] boolValue] : NO;
    self.jailbreakHideDeep = dict[@"jailbreakHideDeep"] ? [dict[@"jailbreakHideDeep"] boolValue] : NO;
    self.holographicBackup = dict[@"holographicBackup"] ? [dict[@"holographicBackup"] boolValue] : YES;
    self.allowIPadSpoof = dict[@"allowIPadSpoof"] ? [dict[@"allowIPadSpoof"] boolValue] : NO;
    self.clearPasteboardOnSwitch = dict[@"clearPasteboardOnSwitch"] ? [dict[@"clearPasteboardOnSwitch"] boolValue] : YES;
    self.importKeychainWithData = dict[@"importKeychainWithData"] ? [dict[@"importKeychainWithData"] boolValue] : YES;
    self.slimExportStripMedia = dict[@"slimExportStripMedia"] ? [dict[@"slimExportStripMedia"] boolValue] : NO;
    self.targetApps = dict[@"targetApps"] ?: @[];
    self.preferredModels = dict[@"preferredModels"] ?: @[];
    self.preferredSystems = dict[@"preferredSystems"] ?: @[];
}

- (void)reload {
    [NDPaths ensureDirectories];

    // Prefer world-readable runtime snapshot (works inside sandboxed target apps)
    NSDictionary *runtime = [NDRuntimeState dictionary];
    if (runtime) {
        [self applyDictionary:runtime];
        // preferred* + Tools toggles may only live in full config plist on older runtime.plist
        NSDictionary *full = [NSDictionary dictionaryWithContentsOfFile:[NDPaths configPlistPath]];
        if ([full isKindOfClass:[NSDictionary class]]) {
            self.preferredModels = full[@"preferredModels"] ?: self.preferredModels;
            self.preferredSystems = full[@"preferredSystems"] ?: self.preferredSystems;
            if (!runtime[@"importKeychainWithData"] && full[@"importKeychainWithData"]) {
                self.importKeychainWithData = [full[@"importKeychainWithData"] boolValue];
            }
            if (!runtime[@"slimExportStripMedia"] && full[@"slimExportStripMedia"]) {
                self.slimExportStripMedia = [full[@"slimExportStripMedia"] boolValue];
            }
        }
        return;
    }

    NSDictionary *dict = [NSDictionary dictionaryWithContentsOfFile:[NDPaths configPlistPath]];
    if (![dict isKindOfClass:[NSDictionary class]]) {
        // NEVER save defaults from tweak/target-app context — that would wipe targetApps.
        [self applyDefaults];
        return;
    }
    [self applyDictionary:dict];
}

- (BOOL)save {
    [NDPaths ensureDirectories];
    NSDictionary *dict = @{
        @"fakeDeviceModel": @(self.fakeDeviceModel),
        @"fakeSystemVer": @(self.fakeSystemVer),
        @"fakeCarrier": @(self.fakeCarrier),
        @"spoofLocation": @(self.spoofLocation),
        @"randomLocation": @(self.randomLocation),
        @"locationFromIP": @(self.locationFromIP),
        @"smartLocationOffset": @(self.smartLocationOffset),
        @"smartAirplane": @(self.smartAirplane),
        @"jailbreakHideBasic": @(self.jailbreakHideBasic),
        @"jailbreakHideDeep": @(self.jailbreakHideDeep),
        @"holographicBackup": @(self.holographicBackup),
        @"allowIPadSpoof": @(self.allowIPadSpoof),
        @"clearPasteboardOnSwitch": @(self.clearPasteboardOnSwitch),
        @"importKeychainWithData": @(self.importKeychainWithData),
        @"slimExportStripMedia": @(self.slimExportStripMedia),
        @"targetApps": self.targetApps ?: @[],
        @"preferredModels": self.preferredModels ?: @[],
        @"preferredSystems": self.preferredSystems ?: @[],
    };
    BOOL ok = [dict writeToFile:[NDPaths configPlistPath] atomically:YES];
    [NDPaths makePathWorldReadable:[NDPaths preferencesDir]];
    [NDPaths makePathWorldReadable:[NDPaths configPlistPath]];

    NSString *current = [[NDRecordStore shared] currentRecordName];
    NDDeviceProfile *profile = [[NDRecordStore shared] currentProfile];
    [NDRuntimeState publishWithConfig:self profile:profile currentName:current];
    notify_post([NDNotifyReload UTF8String]);
    return ok;
}

- (BOOL)isTargetApp:(NSString *)bundleId {
    if (!bundleId.length) return NO;
    if ([bundleId isEqualToString:NDBundleID]) return YES;
    for (NSString *item in self.targetApps) {
        if ([item isKindOfClass:[NSString class]] && [item isEqualToString:bundleId]) return YES;
    }
    return NO;
}

@end
