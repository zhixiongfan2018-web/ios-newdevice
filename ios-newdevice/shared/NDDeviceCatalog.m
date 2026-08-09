#import "NDDeviceCatalog.h"

@implementation NDDeviceCatalog

+ (NSArray<NSDictionary *> *)deviceModels {
    return @[
        @{@"Model": @"iPhone 13", @"ProductType": @"iPhone14,5", @"HardwareMachine": @"iPhone14,5"},
        @{@"Model": @"iPhone 13 Pro", @"ProductType": @"iPhone14,2", @"HardwareMachine": @"iPhone14,2"},
        @{@"Model": @"iPhone 14", @"ProductType": @"iPhone14,7", @"HardwareMachine": @"iPhone14,7"},
        @{@"Model": @"iPhone 14 Pro", @"ProductType": @"iPhone15,2", @"HardwareMachine": @"iPhone15,2"},
        @{@"Model": @"iPhone 15", @"ProductType": @"iPhone15,4", @"HardwareMachine": @"iPhone15,4"},
        @{@"Model": @"iPhone 15 Pro", @"ProductType": @"iPhone16,1", @"HardwareMachine": @"iPhone16,1"},
        @{@"Model": @"iPhone 15 Pro Max", @"ProductType": @"iPhone16,2", @"HardwareMachine": @"iPhone16,2"},
        @{@"Model": @"iPhone 12", @"ProductType": @"iPhone13,2", @"HardwareMachine": @"iPhone13,2"},
        @{@"Model": @"iPhone 11", @"ProductType": @"iPhone12,1", @"HardwareMachine": @"iPhone12,1"},
        @{@"Model": @"iPhone X", @"ProductType": @"iPhone10,3", @"HardwareMachine": @"iPhone10,3"},
    ];
}

+ (NSArray<NSString *> *)systemVersions {
    return @[
        @"15.0", @"15.1", @"15.4.1", @"15.7.1",
        @"16.0", @"16.1.1", @"16.3.1", @"16.5", @"16.6.1", @"16.7.2",
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
