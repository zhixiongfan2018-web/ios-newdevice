#import "NDDeviceCatalog.h"

@implementation NDDeviceCatalog

+ (NSArray<NSDictionary *> *)deviceModels {
    // HardwareMachine = ProductType (sysctl hw.machine)
    // HardwareModel = board id (MobileGestalt HardwareModel), matches real Gestalt shape
    return @[
        @{@"Model": @"iPhone 13", @"ProductType": @"iPhone14,5", @"HardwareMachine": @"iPhone14,5", @"HardwareModel": @"D17AP"},
        @{@"Model": @"iPhone 13 Pro", @"ProductType": @"iPhone14,2", @"HardwareMachine": @"iPhone14,2", @"HardwareModel": @"D63AP"},
        @{@"Model": @"iPhone 14", @"ProductType": @"iPhone14,7", @"HardwareMachine": @"iPhone14,7", @"HardwareModel": @"D27AP"},
        @{@"Model": @"iPhone 14 Pro", @"ProductType": @"iPhone15,2", @"HardwareMachine": @"iPhone15,2", @"HardwareModel": @"D73AP"},
        @{@"Model": @"iPhone 15", @"ProductType": @"iPhone15,4", @"HardwareMachine": @"iPhone15,4", @"HardwareModel": @"D37AP"},
        @{@"Model": @"iPhone 15 Pro", @"ProductType": @"iPhone16,1", @"HardwareMachine": @"iPhone16,1", @"HardwareModel": @"D83AP"},
        @{@"Model": @"iPhone 15 Pro Max", @"ProductType": @"iPhone16,2", @"HardwareMachine": @"iPhone16,2", @"HardwareModel": @"D84AP"},
        @{@"Model": @"iPhone 12", @"ProductType": @"iPhone13,2", @"HardwareMachine": @"iPhone13,2", @"HardwareModel": @"D53gAP"},
        @{@"Model": @"iPhone 11", @"ProductType": @"iPhone12,1", @"HardwareMachine": @"iPhone12,1", @"HardwareModel": @"N104AP"},
        @{@"Model": @"iPhone X", @"ProductType": @"iPhone10,3", @"HardwareMachine": @"iPhone10,3", @"HardwareModel": @"D22AP"},
    ];
}

+ (NSDictionary<NSString *, NSString *> *)systemBuildMap {
    // Keep in sync with systemVersions — real public builds.
    return @{
        @"15.0": @"19A346",
        @"15.1": @"19B74",
        @"15.4.1": @"19E258",
        @"15.7.1": @"19H117",
        @"16.0": @"20A362",
        @"16.1.1": @"20B101",
        @"16.3.1": @"20D67",
        @"16.5": @"20F66",
        @"16.6.1": @"20G81",
        @"16.7.2": @"20H115",
    };
}

+ (NSArray<NSString *> *)systemVersions {
    return @[
        @"15.0", @"15.1", @"15.4.1", @"15.7.1",
        @"16.0", @"16.1.1", @"16.3.1", @"16.5", @"16.6.1", @"16.7.2",
    ];
}

+ (NSString *)buildForSystemVersion:(NSString *)systemVer {
    if (!systemVer.length) return nil;
    NSString *exact = [self systemBuildMap][systemVer];
    if (exact.length) return exact;
    // Fallback: prefix match e.g. 16.1 → 16.1.1
    for (NSString *key in [self systemBuildMap]) {
        if ([key hasPrefix:systemVer] || [systemVer hasPrefix:key]) {
            return [self systemBuildMap][key];
        }
    }
    NSArray *parts = [systemVer componentsSeparatedByString:@"."];
    NSInteger major = parts.count ? [parts[0] integerValue] : 16;
    // Last resort synthetic (should rarely hit with catalog versions).
    return [NSString stringWithFormat:@"%ldA%d", (long)(major + 4), 100 + (int)arc4random_uniform(200)];
}

+ (NSArray<NSDictionary *> *)carriers {
    return @[
        @{@"Carrier": @"中国移动", @"MCC": @"460", @"MNC": @"00"},
        @{@"Carrier": @"中国移动", @"MCC": @"460", @"MNC": @"02"},
        @{@"Carrier": @"中国联通", @"MCC": @"460", @"MNC": @"01"},
        @{@"Carrier": @"中国电信", @"MCC": @"460", @"MNC": @"03"},
        @{@"Carrier": @"中国电信", @"MCC": @"460", @"MNC": @"11"},
    ];
}

+ (NSArray<NSString *> *)radioAccessTypes {
    // Only values mappable to CTRadioAccessTechnology* (no WiFi).
    return @[@"LTE", @"NR", @"NRNSA", @"WCDMA"];
}

+ (NSDictionary *)randomChinaCoordinate {
    // Rough bounding box covering mainland cities (same idea as AMG random location).
    double minLat = 22.0, maxLat = 45.0;
    double minLon = 102.0, maxLon = 122.0;
    double lat = minLat + ((double)arc4random_uniform(100000) / 100000.0) * (maxLat - minLat);
    double lon = minLon + ((double)arc4random_uniform(100000) / 100000.0) * (maxLon - minLon);
    return @{@"lat": @(lat), @"lon": @(lon)};
}

+ (NSDictionary *)deviceEntryMatching:(NSString *)modelOrProductType {
    if (!modelOrProductType.length) return nil;
    for (NSDictionary *m in [self deviceModels]) {
        if ([m[@"Model"] isEqualToString:modelOrProductType] ||
            [m[@"ProductType"] isEqualToString:modelOrProductType] ||
            [m[@"HardwareMachine"] isEqualToString:modelOrProductType]) {
            return m;
        }
    }
    return nil;
}

@end
