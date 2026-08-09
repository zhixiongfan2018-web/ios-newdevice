#import "NDConfig.h"
#import "NDPaths.h"

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
    self.jailbreakHideBasic = YES;
    self.jailbreakHideDeep = NO;
    self.holographicBackup = YES;
    self.targetApps = @[];
    self.preferredModels = @[];
    self.preferredSystems = @[];
}

- (void)reload {
    [NDPaths ensureDirectories];
    NSDictionary *dict = [NSDictionary dictionaryWithContentsOfFile:[NDPaths configPlistPath]];
    if (![dict isKindOfClass:[NSDictionary class]]) {
        [self applyDefaults];
        [self save];
        return;
    }
    self.fakeDeviceModel = [dict[@"fakeDeviceModel"] boolValue];
    self.fakeSystemVer = [dict[@"fakeSystemVer"] boolValue];
    self.fakeCarrier = [dict[@"fakeCarrier"] boolValue];
    self.spoofLocation = dict[@"spoofLocation"] ? [dict[@"spoofLocation"] boolValue] : YES;
    self.randomLocation = dict[@"randomLocation"] ? [dict[@"randomLocation"] boolValue] : YES;
    self.smartLocationOffset = [dict[@"smartLocationOffset"] boolValue];
    self.smartAirplane = dict[@"smartAirplane"] ? [dict[@"smartAirplane"] boolValue] : YES;
    self.jailbreakHideBasic = dict[@"jailbreakHideBasic"] ? [dict[@"jailbreakHideBasic"] boolValue] : YES;
    self.jailbreakHideDeep = [dict[@"jailbreakHideDeep"] boolValue];
    self.holographicBackup = dict[@"holographicBackup"] ? [dict[@"holographicBackup"] boolValue] : YES;
    self.targetApps = dict[@"targetApps"] ?: @[];
    self.preferredModels = dict[@"preferredModels"] ?: @[];
    self.preferredSystems = dict[@"preferredSystems"] ?: @[];
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
    return [dict writeToFile:[NDPaths configPlistPath] atomically:YES];
}

- (BOOL)isTargetApp:(NSString *)bundleId {
    if (!bundleId.length) return NO;
    if ([bundleId isEqualToString:NDBundleID]) return YES;
    return [self.targetApps containsObject:bundleId];
}

@end
