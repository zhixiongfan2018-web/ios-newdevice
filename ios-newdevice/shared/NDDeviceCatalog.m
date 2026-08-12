#import "NDDeviceCatalog.h"

@implementation NDDeviceCatalog

+ (NSArray<NSDictionary *> *)deviceModels {
    return @[
        @{@"Model": @"iPhone SE (3rd generation)", @"ProductType": @"iPhone14,6", @"HardwareMachine": @"iPhone14,6"},
        @{@"Model": @"iPhone 13", @"ProductType": @"iPhone14,5", @"HardwareMachine": @"iPhone14,5"},
        @{@"Model": @"iPhone 13 Pro", @"ProductType": @"iPhone14,2", @"HardwareMachine": @"iPhone14,2"},
        @{@"Model": @"iPhone 14", @"ProductType": @"iPhone14,7", @"HardwareMachine": @"iPhone14,7"},
        @{@"Model": @"iPhone 14 Pro", @"ProductType": @"iPhone15,2", @"HardwareMachine": @"iPhone15,2"},
        @{@"Model": @"iPhone 15", @"ProductType": @"iPhone15,4", @"HardwareMachine": @"iPhone15,4"},
        @{@"Model": @"iPhone 15 Pro", @"ProductType": @"iPhone16,1", @"HardwareMachine": @"iPhone16,1"},
        @{@"Model": @"iPhone 15 Pro Max", @"ProductType": @"iPhone16,2", @"HardwareMachine": @"iPhone16,2"},
        @{@"Model": @"iPhone 16", @"ProductType": @"iPhone17,3", @"HardwareMachine": @"iPhone17,3"},
        @{@"Model": @"iPhone 16 Pro", @"ProductType": @"iPhone17,1", @"HardwareMachine": @"iPhone17,1"},
        @{@"Model": @"iPhone 16 Pro Max", @"ProductType": @"iPhone17,2", @"HardwareMachine": @"iPhone17,2"},
        @{@"Model": @"iPhone 12", @"ProductType": @"iPhone13,2", @"HardwareMachine": @"iPhone13,2"},
        @{@"Model": @"iPhone 11", @"ProductType": @"iPhone12,1", @"HardwareMachine": @"iPhone12,1"},
    ];
}

+ (NSArray<NSString *> *)systemVersions {
    // Real device is often iOS 18.x (Dopamine). Include 17/18 so spoofed versions match modern apps.
    return @[
        @"17.0", @"17.1.1", @"17.4.1", @"17.5.1", @"17.6.1",
        @"18.0", @"18.1", @"18.2.1", @"18.3.1", @"18.4", @"18.5",
        @"16.7.2", @"16.6.1",
    ];
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
    return @[@"LTE", @"NR", @"NRNSA", @"WCDMA", @"WiFi"];
}

+ (NSDictionary *)randomChinaCoordinate {
    // Rough bounding box covering mainland cities
    double minLat = 22.0, maxLat = 45.0;
    double minLon = 102.0, maxLon = 122.0;
    double lat = minLat + ((double)arc4random_uniform(100000) / 100000.0) * (maxLat - minLat);
    double lon = minLon + ((double)arc4random_uniform(100000) / 100000.0) * (maxLon - minLon);
    return @{@"lat": @(lat), @"lon": @(lon)};
}

@end
