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
    self.smartLocationOffset = YES;
    self.smartAirplane = YES;
    // Default OFF so install/respring never hides JB paths from tooling
    self.jailbreakHideBasic = NO;
    self.jailbreakHideDeep = NO;
    self.holographicBackup = YES;
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
    self.smartLocationOffset = [dict[@"smartLocationOffset"] boolValue];
    self.smartAirplane = dict[@"smartAirplane"] ? [dict[@"smartAirplane"] boolValue] : YES;
    self.jailbreakHideBasic = dict[@"jailbreakHideBasic"] ? [dict[@"jailbreakHideBasic"] boolValue] : NO;
    self.jailbreakHideDeep = dict[@"jailbreakHideDeep"] ? [dict[@"jailbreakHideDeep"] boolValue] : NO;
    self.holographicBackup = dict[@"holographicBackup"] ? [dict[@"holographicBackup"] boolValue] : YES;
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
        // preferred* may only live in full config plist
        NSDictionary *full = [NSDictionary dictionaryWithContentsOfFile:[NDPaths configPlistPath]];
        if ([full isKindOfClass:[NSDictionary class]]) {
            self.preferredModels = full[@"preferredModels"] ?: self.preferredModels;
            self.preferredSystems = full[@"preferredSystems"] ?: self.preferredSystems;
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
        @"smartLocationOffset": @(self.smartLocationOffset),
        @"smartAirplane": @(self.smartAirplane),
        @"jailbreakHideBasic": @(self.jailbreakHideBasic),
        @"jailbreakHideDeep": @(self.jailbreakHideDeep),
        @"holographicBackup": @(self.holographicBackup),
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
