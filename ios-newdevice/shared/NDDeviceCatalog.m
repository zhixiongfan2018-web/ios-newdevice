#import "NDDeviceCatalog.h"
#import <float.h>
#import <math.h>

@implementation NDDeviceCatalog

+ (NSArray<NSDictionary *> *)deviceModels {
    // ProductType == HardwareMachine for modern iPhones (utsname.machine / hw.machine)
    return @[
        // iPhone 11 family
        @{@"Model": @"iPhone 11", @"ProductType": @"iPhone12,1", @"HardwareMachine": @"iPhone12,1"},
        @{@"Model": @"iPhone 11 Pro", @"ProductType": @"iPhone12,3", @"HardwareMachine": @"iPhone12,3"},
        @{@"Model": @"iPhone 11 Pro Max", @"ProductType": @"iPhone12,5", @"HardwareMachine": @"iPhone12,5"},
        @{@"Model": @"iPhone SE (2nd generation)", @"ProductType": @"iPhone12,8", @"HardwareMachine": @"iPhone12,8"},

        // iPhone 12 family
        @{@"Model": @"iPhone 12 mini", @"ProductType": @"iPhone13,1", @"HardwareMachine": @"iPhone13,1"},
        @{@"Model": @"iPhone 12", @"ProductType": @"iPhone13,2", @"HardwareMachine": @"iPhone13,2"},
        @{@"Model": @"iPhone 12 Pro", @"ProductType": @"iPhone13,3", @"HardwareMachine": @"iPhone13,3"},
        @{@"Model": @"iPhone 12 Pro Max", @"ProductType": @"iPhone13,4", @"HardwareMachine": @"iPhone13,4"},

        // iPhone 13 family
        @{@"Model": @"iPhone 13 mini", @"ProductType": @"iPhone14,4", @"HardwareMachine": @"iPhone14,4"},
        @{@"Model": @"iPhone 13", @"ProductType": @"iPhone14,5", @"HardwareMachine": @"iPhone14,5"},
        @{@"Model": @"iPhone 13 Pro", @"ProductType": @"iPhone14,2", @"HardwareMachine": @"iPhone14,2"},
        @{@"Model": @"iPhone 13 Pro Max", @"ProductType": @"iPhone14,3", @"HardwareMachine": @"iPhone14,3"},
        @{@"Model": @"iPhone SE (3rd generation)", @"ProductType": @"iPhone14,6", @"HardwareMachine": @"iPhone14,6"},

        // iPhone 14 family
        @{@"Model": @"iPhone 14", @"ProductType": @"iPhone14,7", @"HardwareMachine": @"iPhone14,7"},
        @{@"Model": @"iPhone 14 Plus", @"ProductType": @"iPhone14,8", @"HardwareMachine": @"iPhone14,8"},
        @{@"Model": @"iPhone 14 Pro", @"ProductType": @"iPhone15,2", @"HardwareMachine": @"iPhone15,2"},
        @{@"Model": @"iPhone 14 Pro Max", @"ProductType": @"iPhone15,3", @"HardwareMachine": @"iPhone15,3"},

        // iPhone 15 family
        @{@"Model": @"iPhone 15", @"ProductType": @"iPhone15,4", @"HardwareMachine": @"iPhone15,4"},
        @{@"Model": @"iPhone 15 Plus", @"ProductType": @"iPhone15,5", @"HardwareMachine": @"iPhone15,5"},
        @{@"Model": @"iPhone 15 Pro", @"ProductType": @"iPhone16,1", @"HardwareMachine": @"iPhone16,1"},
        @{@"Model": @"iPhone 15 Pro Max", @"ProductType": @"iPhone16,2", @"HardwareMachine": @"iPhone16,2"},

        // iPhone 16 family
        @{@"Model": @"iPhone 16", @"ProductType": @"iPhone17,3", @"HardwareMachine": @"iPhone17,3"},
        @{@"Model": @"iPhone 16 Plus", @"ProductType": @"iPhone17,4", @"HardwareMachine": @"iPhone17,4"},
        @{@"Model": @"iPhone 16 Pro", @"ProductType": @"iPhone17,1", @"HardwareMachine": @"iPhone17,1"},
        @{@"Model": @"iPhone 16 Pro Max", @"ProductType": @"iPhone17,2", @"HardwareMachine": @"iPhone17,2"},
        @{@"Model": @"iPhone 16e", @"ProductType": @"iPhone17,5", @"HardwareMachine": @"iPhone17,5"},
        // iPad (AMG-compatible iPad spoof)
        @{@"Model": @"iPad Pro 11-inch (M4)", @"ProductType": @"iPad16,3", @"HardwareMachine": @"iPad16,3"},
        @{@"Model": @"iPad Pro 13-inch (M4)", @"ProductType": @"iPad16,4", @"HardwareMachine": @"iPad16,4"},
        @{@"Model": @"iPad Air 11-inch (M2)", @"ProductType": @"iPad14,8", @"HardwareMachine": @"iPad14,8"},
        @{@"Model": @"iPad Air 13-inch (M2)", @"ProductType": @"iPad14,10", @"HardwareMachine": @"iPad14,10"},
        @{@"Model": @"iPad (10th generation)", @"ProductType": @"iPad13,18", @"HardwareMachine": @"iPad13,18"},
        @{@"Model": @"iPad mini (6th generation)", @"ProductType": @"iPad14,1", @"HardwareMachine": @"iPad14,1"},

    ];
}

+ (NSDictionary<NSString *, NSString *> *)officialSystemBuilds {
    // Public Apple release builds (IPSW / Apple security notes). Keep SystemVer ↔ Build 1:1.
    static NSDictionary *map;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        map = @{
            // iOS 16
            @"16.0": @"20A362", @"16.0.2": @"20A380",
            @"16.1": @"20B82", @"16.1.1": @"20B101", @"16.1.2": @"20B110",
            @"16.2": @"20C65", @"16.3": @"20D47", @"16.3.1": @"20D67",
            @"16.4": @"20E247", @"16.4.1": @"20E252",
            @"16.5": @"20F66", @"16.5.1": @"20F75",
            @"16.6": @"20G75", @"16.6.1": @"20G81",
            @"16.7": @"20H19", @"16.7.1": @"20H30", @"16.7.2": @"20H115",
            @"16.7.3": @"20H232", @"16.7.4": @"20H240", @"16.7.5": @"20H307",
            @"16.7.6": @"20H320", @"16.7.7": @"20H330", @"16.7.8": @"20H343",
            @"16.7.9": @"20H348", @"16.7.10": @"20H350", @"16.7.11": @"20H360",
            @"16.7.12": @"20H364", @"16.7.13": @"20H365", @"16.7.14": @"20H370",
            @"16.7.15": @"20H380", @"16.7.16": @"20H392",
            // iOS 17
            @"17.0": @"21A329", @"17.0.1": @"21A340", @"17.0.2": @"21A351", @"17.0.3": @"21A360",
            @"17.1": @"21B74", @"17.1.1": @"21B91", @"17.1.2": @"21B101",
            @"17.2": @"21C62", @"17.2.1": @"21C66",
            @"17.3": @"21D50", @"17.3.1": @"21D61",
            @"17.4": @"21E219", @"17.4.1": @"21E236",
            @"17.5": @"21F79", @"17.5.1": @"21F90",
            @"17.6": @"21G80", @"17.6.1": @"21G93",
            @"17.7": @"21H16", @"17.7.1": @"21H216", @"17.7.2": @"21H221",
            @"17.7.3": @"21H312", @"17.7.4": @"21H414", @"17.7.5": @"21H420",
            @"17.7.6": @"21H423", @"17.7.7": @"21H433", @"17.7.8": @"21H440",
            @"17.7.9": @"21H446", @"17.7.10": @"21H450", @"17.7.11": @"21H461",
            // iOS 18
            @"18.0": @"22A3354", @"18.0.1": @"22A3370",
            @"18.1": @"22B83", @"18.1.1": @"22B91",
            @"18.2": @"22C152", @"18.2.1": @"22C161",
            @"18.3": @"22D63", @"18.3.1": @"22D72", @"18.3.2": @"22D82",
            @"18.4": @"22E240", @"18.4.1": @"22E252",
            @"18.5": @"22F76",
            @"18.6": @"22G86", @"18.6.1": @"22G90", @"18.6.2": @"22G100",
            @"18.7": @"22H20", @"18.7.1": @"22H31", @"18.7.2": @"22H124",
            @"18.7.3": @"22H217", @"18.7.4": @"22H218", @"18.7.5": @"22H311",
            @"18.7.6": @"22H320", @"18.7.7": @"22H340", @"18.7.8": @"22H352",
            @"18.7.9": @"22H355",
        };
    });
    return map;
}

+ (NSString *)buildForSystemVersion:(NSString *)systemVer {
    if (!systemVer.length) return @"";
    return [self officialSystemBuilds][systemVer] ?: @"";
}

/// Major version from "18.5" / "18.7.9" style strings. Unknown → 0.
+ (NSInteger)majorSystemVersion:(NSString *)systemVer {
    if (!systemVer.length) return 0;
    return [[[systemVer componentsSeparatedByString:@"."] firstObject] integerValue];
}

+ (BOOL)isLimitedSupportSystemVersion:(NSString *)systemVer {
    // Publicly these were narrow maintenance trains (e.g. XR/XS Australia emergency).
    // Keep in officialSystemBuilds for import lookup, but do not offer / keep on SE3+.
    if (!systemVer.length) return NO;
    static NSSet *limited;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        limited = [NSSet setWithArray:@[
            @"18.7.3", @"18.7.4", @"18.7.5", @"18.7.6", @"18.7.7", @"18.7.8", @"18.7.9",
        ]];
    });
    return [limited containsObject:systemVer];
}

+ (NSArray<NSString *> *)preferredSystemVersions {
    static NSArray *prefs;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        // General iOS 18 trains commonly seen on iPhone 12–16 / SE3.
        prefs = @[
            @"18.5",
            @"18.6", @"18.6.1", @"18.6.2",
            @"18.7", @"18.7.1", @"18.7.2",
        ];
    });
    return prefs;
}

+ (NSArray<NSString *> *)systemVersions {
    // Environments must be iOS 18+ (picker + 一键新机 pool). Prefer mainstream
    // builds; older / limited keys stay in officialSystemBuilds for AMG import.
    return [self preferredSystemVersions];
}

+ (NSArray<NSDictionary *> *)carriers {
    // United States PLMN (MCC 310/311/312/316). Names match common CTCarrier.carrierName values.
    return @[
        // AT&T
        @{@"Carrier": @"AT&T", @"MCC": @"310", @"MNC": @"410"},
        @{@"Carrier": @"AT&T", @"MCC": @"310", @"MNC": @"150"},
        @{@"Carrier": @"AT&T", @"MCC": @"310", @"MNC": @"170"},
        @{@"Carrier": @"AT&T", @"MCC": @"310", @"MNC": @"380"},
        @{@"Carrier": @"AT&T", @"MCC": @"310", @"MNC": @"030"},
        // Verizon
        @{@"Carrier": @"Verizon", @"MCC": @"311", @"MNC": @"480"},
        @{@"Carrier": @"Verizon", @"MCC": @"310", @"MNC": @"004"},
        @{@"Carrier": @"Verizon", @"MCC": @"310", @"MNC": @"012"},
        @{@"Carrier": @"Verizon", @"MCC": @"311", @"MNC": @"110"},
        @{@"Carrier": @"Verizon", @"MCC": @"311", @"MNC": @"270"},
        // T-Mobile
        @{@"Carrier": @"T-Mobile", @"MCC": @"310", @"MNC": @"260"},
        @{@"Carrier": @"T-Mobile", @"MCC": @"310", @"MNC": @"160"},
        @{@"Carrier": @"T-Mobile", @"MCC": @"310", @"MNC": @"200"},
        @{@"Carrier": @"T-Mobile", @"MCC": @"310", @"MNC": @"210"},
        @{@"Carrier": @"T-Mobile", @"MCC": @"310", @"MNC": @"220"},
        @{@"Carrier": @"T-Mobile", @"MCC": @"310", @"MNC": @"240"},
        @{@"Carrier": @"T-Mobile", @"MCC": @"310", @"MNC": @"250"},
        @{@"Carrier": @"T-Mobile", @"MCC": @"310", @"MNC": @"310"},
        @{@"Carrier": @"T-Mobile", @"MCC": @"311", @"MNC": @"490"},
        // US Cellular
        @{@"Carrier": @"US Cellular", @"MCC": @"311", @"MNC": @"580"},
        @{@"Carrier": @"US Cellular", @"MCC": @"311", @"MNC": @"220"},
        // Common MVNOs (still report parent PLMN on many devices)
        @{@"Carrier": @"Cricket", @"MCC": @"310", @"MNC": @"150"},
        @{@"Carrier": @"Metro by T-Mobile", @"MCC": @"310", @"MNC": @"260"},
        @{@"Carrier": @"Visible", @"MCC": @"311", @"MNC": @"480"},
        @{@"Carrier": @"Mint Mobile", @"MCC": @"310", @"MNC": @"260"},
        @{@"Carrier": @"Google Fi", @"MCC": @"310", @"MNC": @"260"},
    ];
}

+ (BOOL)isPlausibleCarrierName:(NSString *)name {
    if (![name isKindOfClass:[NSString class]] || name.length < 2 || name.length > 32) return NO;
    // POI / ISP / reverse-geocode leftovers (e.g. "Tencent Building, Kejizhongy")
    if ([name rangeOfString:@","].location != NSNotFound) return NO;
    if ([name rangeOfString:@"Building" options:NSCaseInsensitiveSearch].location != NSNotFound) return NO;
    if ([name rangeOfString:@"Street" options:NSCaseInsensitiveSearch].location != NSNotFound) return NO;
    if ([name rangeOfString:@"Road" options:NSCaseInsensitiveSearch].location != NSNotFound) return NO;
    if ([name rangeOfString:@"Avenue" options:NSCaseInsensitiveSearch].location != NSNotFound) return NO;
    if ([name rangeOfString:@"Kejizhong" options:NSCaseInsensitiveSearch].location != NSNotFound) return NO;
    NSString *lower = name.lowercaseString;
    for (NSString *bad in @[@"tencent", @"alibaba", @"chinanet", @"china unicom", @"china mobile",
                             @"telecom", @"broadband", @"fiber", @"datacenter", @"cloud"]) {
        if ([lower containsString:bad]) return NO;
    }
    for (NSDictionary *c in [self carriers]) {
        NSString *cn = c[@"Carrier"];
        if (cn.length && [name caseInsensitiveCompare:cn] == NSOrderedSame) return YES;
    }
    // Short alphanumeric brand-like names still OK (e.g. "Fi", "Spectrum")
    NSCharacterSet *ok = [NSCharacterSet characterSetWithCharactersInString:
                          @"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789 &+-.'"];
    return [name rangeOfCharacterFromSet:ok.invertedSet].location == NSNotFound;
}

+ (NSDictionary *)carrierForSeed:(uint32_t)seed preferMCC:(NSString *)mcc preferMNC:(NSString *)mnc {
    NSArray *list = [self carriers];
    if (mcc.length && mnc.length) {
        for (NSDictionary *c in list) {
            if ([c[@"MCC"] isEqualToString:mcc] && [c[@"MNC"] isEqualToString:mnc]) return c;
        }
        for (NSDictionary *c in list) {
            if ([c[@"MCC"] isEqualToString:mcc]) return c;
        }
    }
    return list.count ? list[seed % list.count] : @{@"Carrier": @"T-Mobile", @"MCC": @"310", @"MNC": @"260"};
}

+ (NSArray<NSString *> *)radioAccessTypes {
    // US networks are overwhelmingly LTE / 5G NR
    return @[@"LTE", @"LTE", @"LTE", @"NR", @"NR", @"NR", @"NRNSA"];
}

+ (NSArray<NSDictionary *> *)usCityCoordinates {
    // Major US metro centers. Small urban jitter applied in randomUSCoordinate.
    return @[
        @{@"city": @"New York, NY", @"lat": @40.7128, @"lon": @-74.0060, @"timezone": @"America/New_York"},
        @{@"city": @"Los Angeles, CA", @"lat": @34.0522, @"lon": @-118.2437, @"timezone": @"America/Los_Angeles"},
        @{@"city": @"Chicago, IL", @"lat": @41.8781, @"lon": @-87.6298, @"timezone": @"America/Chicago"},
        @{@"city": @"Houston, TX", @"lat": @29.7604, @"lon": @-95.3698, @"timezone": @"America/Chicago"},
        @{@"city": @"Phoenix, AZ", @"lat": @33.4484, @"lon": @-112.0740, @"timezone": @"America/Phoenix"},
        @{@"city": @"Philadelphia, PA", @"lat": @39.9526, @"lon": @-75.1652, @"timezone": @"America/New_York"},
        @{@"city": @"San Antonio, TX", @"lat": @29.4241, @"lon": @-98.4936, @"timezone": @"America/Chicago"},
        @{@"city": @"San Diego, CA", @"lat": @32.7157, @"lon": @-117.1611, @"timezone": @"America/Los_Angeles"},
        @{@"city": @"Dallas, TX", @"lat": @32.7767, @"lon": @-96.7970, @"timezone": @"America/Chicago"},
        @{@"city": @"San Jose, CA", @"lat": @37.3382, @"lon": @-121.8863, @"timezone": @"America/Los_Angeles"},
        @{@"city": @"Austin, TX", @"lat": @30.2672, @"lon": @-97.7431, @"timezone": @"America/Chicago"},
        @{@"city": @"Jacksonville, FL", @"lat": @30.3322, @"lon": @-81.6557, @"timezone": @"America/New_York"},
        @{@"city": @"Fort Worth, TX", @"lat": @32.7555, @"lon": @-97.3308, @"timezone": @"America/Chicago"},
        @{@"city": @"Columbus, OH", @"lat": @39.9612, @"lon": @-82.9988, @"timezone": @"America/New_York"},
        @{@"city": @"Charlotte, NC", @"lat": @35.2271, @"lon": @-80.8431, @"timezone": @"America/New_York"},
        @{@"city": @"San Francisco, CA", @"lat": @37.7749, @"lon": @-122.4194, @"timezone": @"America/Los_Angeles"},
        @{@"city": @"Indianapolis, IN", @"lat": @39.7684, @"lon": @-86.1581, @"timezone": @"America/Indiana/Indianapolis"},
        @{@"city": @"Seattle, WA", @"lat": @47.6062, @"lon": @-122.3321, @"timezone": @"America/Los_Angeles"},
        @{@"city": @"Denver, CO", @"lat": @39.7392, @"lon": @-104.9903, @"timezone": @"America/Denver"},
        @{@"city": @"Washington, DC", @"lat": @38.9072, @"lon": @-77.0369, @"timezone": @"America/New_York"},
        @{@"city": @"Boston, MA", @"lat": @42.3601, @"lon": @-71.0589, @"timezone": @"America/New_York"},
        @{@"city": @"El Paso, TX", @"lat": @31.7619, @"lon": @-106.4850, @"timezone": @"America/Chicago"},
        @{@"city": @"Nashville, TN", @"lat": @36.1627, @"lon": @-86.7816, @"timezone": @"America/Chicago"},
        @{@"city": @"Detroit, MI", @"lat": @42.3314, @"lon": @-83.0458, @"timezone": @"America/New_York"},
        @{@"city": @"Oklahoma City, OK", @"lat": @35.4676, @"lon": @-97.5164, @"timezone": @"America/Chicago"},
        @{@"city": @"Portland, OR", @"lat": @45.5152, @"lon": @-122.6784, @"timezone": @"America/Los_Angeles"},
        @{@"city": @"Las Vegas, NV", @"lat": @36.1699, @"lon": @-115.1398, @"timezone": @"America/Los_Angeles"},
        @{@"city": @"Memphis, TN", @"lat": @35.1495, @"lon": @-90.0490, @"timezone": @"America/Chicago"},
        @{@"city": @"Louisville, KY", @"lat": @38.2527, @"lon": @-85.7585, @"timezone": @"America/New_York"},
        @{@"city": @"Baltimore, MD", @"lat": @39.2904, @"lon": @-76.6122, @"timezone": @"America/New_York"},
        @{@"city": @"Milwaukee, WI", @"lat": @43.0389, @"lon": @-87.9065, @"timezone": @"America/Chicago"},
        @{@"city": @"Albuquerque, NM", @"lat": @35.0844, @"lon": @-106.6504, @"timezone": @"America/Denver"},
        @{@"city": @"Tucson, AZ", @"lat": @32.2226, @"lon": @-110.9747, @"timezone": @"America/Phoenix"},
        @{@"city": @"Fresno, CA", @"lat": @36.7378, @"lon": @-119.7871, @"timezone": @"America/Los_Angeles"},
        @{@"city": @"Sacramento, CA", @"lat": @38.5816, @"lon": @-121.4944, @"timezone": @"America/Los_Angeles"},
        @{@"city": @"Mesa, AZ", @"lat": @33.4152, @"lon": @-111.8315, @"timezone": @"America/Phoenix"},
        @{@"city": @"Kansas City, MO", @"lat": @39.0997, @"lon": @-94.5786, @"timezone": @"America/Chicago"},
        @{@"city": @"Atlanta, GA", @"lat": @33.7490, @"lon": @-84.3880, @"timezone": @"America/New_York"},
        @{@"city": @"Miami, FL", @"lat": @25.7617, @"lon": @-80.1918, @"timezone": @"America/New_York"},
        @{@"city": @"Raleigh, NC", @"lat": @35.7796, @"lon": @-78.6382, @"timezone": @"America/New_York"},
        @{@"city": @"Omaha, NE", @"lat": @41.2565, @"lon": @-95.9345, @"timezone": @"America/Chicago"},
        @{@"city": @"Minneapolis, MN", @"lat": @44.9778, @"lon": @-93.2650, @"timezone": @"America/Chicago"},
        @{@"city": @"Cleveland, OH", @"lat": @41.4993, @"lon": @-81.6944, @"timezone": @"America/New_York"},
        @{@"city": @"Tampa, FL", @"lat": @27.9506, @"lon": @-82.4572, @"timezone": @"America/New_York"},
        @{@"city": @"Orlando, FL", @"lat": @28.5383, @"lon": @-81.3792, @"timezone": @"America/New_York"},
        @{@"city": @"St. Louis, MO", @"lat": @38.6270, @"lon": @-90.1994, @"timezone": @"America/Chicago"},
        @{@"city": @"Pittsburgh, PA", @"lat": @40.4406, @"lon": @-79.9959, @"timezone": @"America/New_York"},
        @{@"city": @"Cincinnati, OH", @"lat": @39.1031, @"lon": @-84.5120, @"timezone": @"America/New_York"},
        @{@"city": @"Salt Lake City, UT", @"lat": @40.7608, @"lon": @-111.8910, @"timezone": @"America/Denver"},
        @{@"city": @"Honolulu, HI", @"lat": @21.3069, @"lon": @-157.8583, @"timezone": @"Pacific/Honolulu"},
        @{@"city": @"Anchorage, AK", @"lat": @61.2181, @"lon": @-149.9003, @"timezone": @"America/Anchorage"},
        @{@"city": @"New Orleans, LA", @"lat": @29.9511, @"lon": @-90.0715, @"timezone": @"America/Chicago"},
        @{@"city": @"Richmond, VA", @"lat": @37.5407, @"lon": @-77.4360, @"timezone": @"America/New_York"},
        @{@"city": @"Buffalo, NY", @"lat": @42.8864, @"lon": @-78.8784, @"timezone": @"America/New_York"},
        @{@"city": @"Rochester, NY", @"lat": @43.1566, @"lon": @-77.6088, @"timezone": @"America/New_York"},
        @{@"city": @"Providence, RI", @"lat": @41.8240, @"lon": @-71.4128, @"timezone": @"America/New_York"},
        @{@"city": @"Hartford, CT", @"lat": @41.7658, @"lon": @-72.6734, @"timezone": @"America/New_York"},
        @{@"city": @"Boise, ID", @"lat": @43.6150, @"lon": @-116.2023, @"timezone": @"America/Boise"},
        @{@"city": @"Des Moines, IA", @"lat": @41.5868, @"lon": @-93.6250, @"timezone": @"America/Chicago"},
        @{@"city": @"Madison, WI", @"lat": @43.0731, @"lon": @-89.4012, @"timezone": @"America/Chicago"},
    ];
}

+ (BOOL)isCoordinateInUS:(double)lat longitude:(double)lon {
    // Contiguous US + Alaska + Hawaii (loose bounding boxes).
    if (lat >= 24.5 && lat <= 49.5 && lon >= -125.0 && lon <= -66.5) return YES; // CONUS
    if (lat >= 51.0 && lat <= 71.5 && lon >= -180.0 && lon <= -130.0) return YES; // AK
    if (lat >= 18.5 && lat <= 22.5 && lon >= -161.0 && lon <= -154.0) return YES; // HI
    return NO;
}

+ (NSDictionary *)nearestUSCityToLatitude:(double)lat longitude:(double)lon maxDegrees:(double)maxDeg {
    NSDictionary *best = nil;
    double bestD = DBL_MAX;
    for (NSDictionary *c in [self usCityCoordinates]) {
        double dlat = [c[@"lat"] doubleValue] - lat;
        double dlon = [c[@"lon"] doubleValue] - lon;
        double d = dlat * dlat + dlon * dlon;
        if (d < bestD) { bestD = d; best = c; }
    }
    if (!best) return nil;
    double limit = maxDeg > 0 ? maxDeg : 8.0;
    if (sqrt(bestD) > limit) return nil;
    return best;
}

+ (NSDictionary *)usCoordinateForSeed:(uint32_t)seed {
    NSArray *cities = [self usCityCoordinates];
    NSDictionary *c = cities.count ? cities[seed % cities.count] : @{};
    double jitterLat = ((double)((seed >> 8) % 8000) / 100000.0) - 0.04;
    double jitterLon = ((double)((seed >> 16) % 8000) / 100000.0) - 0.04;
    return @{
        @"lat": @([c[@"lat"] doubleValue] + jitterLat),
        @"lon": @([c[@"lon"] doubleValue] + jitterLon),
        @"city": c[@"city"] ?: @"",
        @"country": @"US",
        @"timezone": c[@"timezone"] ?: @"America/New_York",
    };
}

+ (NSDictionary *)randomUSCoordinate {
    return [self usCoordinateForSeed:arc4random()];
}

+ (NSArray<NSString *> *)deviceColorsForProductType:(NSString *)productType {
    NSString *pt = productType ?: @"";
    BOOL isPad = [pt hasPrefix:@"iPad"];
    BOOL isProTitanium = [pt isEqualToString:@"iPhone15,2"] || [pt isEqualToString:@"iPhone15,3"] // 14 Pro
        || [pt isEqualToString:@"iPhone16,1"] || [pt isEqualToString:@"iPhone16,2"] // 15 Pro
        || [pt isEqualToString:@"iPhone17,1"] || [pt isEqualToString:@"iPhone17,2"]; // 16 Pro
    BOOL isSE = [pt isEqualToString:@"iPhone12,8"] || [pt isEqualToString:@"iPhone14,6"] || [pt isEqualToString:@"iPhone17,5"];
    if (isProTitanium) {
        return @[@"NaturalTitanium", @"BlueTitanium", @"WhiteTitanium", @"BlackTitanium", @"DesertTitanium"];
    }
    if (isSE) {
        return @[@"Midnight", @"Starlight", @"(PRODUCT)RED", @"Black", @"White"];
    }
    if (isPad) {
        return @[@"Space Black", @"Silver", @"Blue", @"Purple", @"Starlight"];
    }
    // 12–16 non-Pro
    return @[@"Black", @"White", @"Blue", @"Green", @"Yellow", @"Pink", @"Purple", @"Midnight", @"Starlight", @"(PRODUCT)RED", @"Ultramarine", @"Teal"];
}

+ (NSString *)modernUDIDPrefixForProductType:(NSString *)productType {
    NSString *pt = productType ?: @"";
    if ([pt hasPrefix:@"iPhone12,"]) return @"00008030";
    if ([pt hasPrefix:@"iPhone13,"]) return @"00008101";
    if ([pt hasPrefix:@"iPhone14,"]) return @"00008110";
    if ([pt hasPrefix:@"iPhone15,"]) return @"00008120";
    if ([pt hasPrefix:@"iPhone16,"]) return @"00008130";
    if ([pt hasPrefix:@"iPhone17,"]) return @"00008140";
    if ([pt hasPrefix:@"iPad"]) return @"00008110";
    return @"";
}

+ (NSArray<NSString *> *)wifiSSIDs {
    return @[
        @"NETGEAR65", @"NETGEAR-5G", @"ATT-WIFI-5GHz", @"ATT4m6x8k",
        @"xfinitywifi", @"XFINITY", @"SpectrumSetup-A8", @"Spectrum-5G",
        @"Verizon_MiFi785", @"MyVerizonWiFi", @"TMOBILE-5G", @"HomeWiFi",
        @"GoogleWifi", @"Google Nest Wifi", @"eero", @"eero-xxxxx",
        @"ASUS_AX88U", @"TP-Link_5GHz", @"TP-LINK_2.4GHz", @"Linksys0A2B",
        @"Orbi76", @"Amplifi", @"Ubiquiti", @"Office-Guest",
        @"Cafe_WiFi", @"AirportExpress", @"iPhone", @"AndroidAP",
        @"Starbucks WiFi", @"Hilton Honors", @"Marriott_Guest", @"McDonalds Free WiFi",
    ];
}

+ (NSDictionary *)randomWiFiNetwork {
    NSString *ssid = [self wifiSSIDs][arc4random_uniform((uint32_t)[self wifiSSIDs].count)];
    // Common consumer AP OUIs (not Apple handset)
    static NSArray<NSString *> *ouis;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        ouis = @[
            @"00:1F:33", @"00:14:6C", @"00:22:6B", @"00:24:B2", @"00:26:F2",
            @"08:86:3B", @"10:0D:7F", @"14:91:82", @"18:D6:C7", @"20:4E:7F",
            @"28:C6:8E", @"30:23:03", @"40:16:7E", @"44:94:FC", @"50:C7:BF",
            @"60:38:E0", @"70:4F:57", @"84:1B:5E", @"A0:63:91", @"B0:7F:B9",
            @"C0:56:27", @"CC:40:D0", @"E0:91:F5", @"E4:F4:C6", @"F8:1A:67",
        ];
    });
    NSString *oui = ouis[arc4random_uniform((uint32_t)ouis.count)];
    NSString *bssid = [NSString stringWithFormat:@"%@:%02X:%02X:%02X",
                       oui, arc4random_uniform(256), arc4random_uniform(256), arc4random_uniform(256)];
    return @{@"SSID": ssid, @"BSSID": bssid};
}


#pragma mark - Compatibility aliases

+ (NSArray<NSDictionary *> *)chinaCityCoordinates {
    return [self usCityCoordinates];
}

+ (NSDictionary *)randomChinaCoordinate {
    return [self randomUSCoordinate];
}

@end
