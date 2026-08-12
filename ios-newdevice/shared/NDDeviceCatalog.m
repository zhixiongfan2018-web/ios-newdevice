#import "NDDeviceCatalog.h"

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
    ];
}

+ (NSArray<NSString *> *)systemVersions {
    // Dense public releases — paired with build map in NDDeviceProfile
    return @[
        // iOS 16
        @"16.0", @"16.0.2", @"16.1", @"16.1.1", @"16.1.2",
        @"16.2", @"16.3", @"16.3.1", @"16.4", @"16.4.1",
        @"16.5", @"16.5.1", @"16.6", @"16.6.1",
        @"16.7", @"16.7.1", @"16.7.2", @"16.7.5", @"16.7.8", @"16.7.10",
        // iOS 17
        @"17.0", @"17.0.1", @"17.0.2", @"17.0.3",
        @"17.1", @"17.1.1", @"17.1.2",
        @"17.2", @"17.2.1", @"17.3", @"17.3.1",
        @"17.4", @"17.4.1", @"17.5", @"17.5.1",
        @"17.6", @"17.6.1", @"17.7", @"17.7.1", @"17.7.2",
        // iOS 18
        @"18.0", @"18.0.1", @"18.1", @"18.1.1",
        @"18.2", @"18.2.1", @"18.3", @"18.3.1", @"18.3.2",
        @"18.4", @"18.4.1", @"18.5",
    ];
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

+ (NSArray<NSString *> *)radioAccessTypes {
    // US networks are overwhelmingly LTE / 5G NR
    return @[@"LTE", @"LTE", @"LTE", @"NR", @"NR", @"NR", @"NRNSA"];
}

+ (NSArray<NSDictionary *> *)usCityCoordinates {
    // Major US metro centers. Small urban jitter applied in randomUSCoordinate.
    return @[
        @{@"city": @"New York, NY", @"lat": @40.7128, @"lon": @-74.0060},
        @{@"city": @"Los Angeles, CA", @"lat": @34.0522, @"lon": @-118.2437},
        @{@"city": @"Chicago, IL", @"lat": @41.8781, @"lon": @-87.6298},
        @{@"city": @"Houston, TX", @"lat": @29.7604, @"lon": @-95.3698},
        @{@"city": @"Phoenix, AZ", @"lat": @33.4484, @"lon": @-112.0740},
        @{@"city": @"Philadelphia, PA", @"lat": @39.9526, @"lon": @-75.1652},
        @{@"city": @"San Antonio, TX", @"lat": @29.4241, @"lon": @-98.4936},
        @{@"city": @"San Diego, CA", @"lat": @32.7157, @"lon": @-117.1611},
        @{@"city": @"Dallas, TX", @"lat": @32.7767, @"lon": @-96.7970},
        @{@"city": @"San Jose, CA", @"lat": @37.3382, @"lon": @-121.8863},
        @{@"city": @"Austin, TX", @"lat": @30.2672, @"lon": @-97.7431},
        @{@"city": @"Jacksonville, FL", @"lat": @30.3322, @"lon": @-81.6557},
        @{@"city": @"Fort Worth, TX", @"lat": @32.7555, @"lon": @-97.3308},
        @{@"city": @"Columbus, OH", @"lat": @39.9612, @"lon": @-82.9988},
        @{@"city": @"Charlotte, NC", @"lat": @35.2271, @"lon": @-80.8431},
        @{@"city": @"San Francisco, CA", @"lat": @37.7749, @"lon": @-122.4194},
        @{@"city": @"Indianapolis, IN", @"lat": @39.7684, @"lon": @-86.1581},
        @{@"city": @"Seattle, WA", @"lat": @47.6062, @"lon": @-122.3321},
        @{@"city": @"Denver, CO", @"lat": @39.7392, @"lon": @-104.9903},
        @{@"city": @"Washington, DC", @"lat": @38.9072, @"lon": @-77.0369},
        @{@"city": @"Boston, MA", @"lat": @42.3601, @"lon": @-71.0589},
        @{@"city": @"El Paso, TX", @"lat": @31.7619, @"lon": @-106.4850},
        @{@"city": @"Nashville, TN", @"lat": @36.1627, @"lon": @-86.7816},
        @{@"city": @"Detroit, MI", @"lat": @42.3314, @"lon": @-83.0458},
        @{@"city": @"Oklahoma City, OK", @"lat": @35.4676, @"lon": @-97.5164},
        @{@"city": @"Portland, OR", @"lat": @45.5152, @"lon": @-122.6784},
        @{@"city": @"Las Vegas, NV", @"lat": @36.1699, @"lon": @-115.1398},
        @{@"city": @"Memphis, TN", @"lat": @35.1495, @"lon": @-90.0490},
        @{@"city": @"Louisville, KY", @"lat": @38.2527, @"lon": @-85.7585},
        @{@"city": @"Baltimore, MD", @"lat": @39.2904, @"lon": @-76.6122},
        @{@"city": @"Milwaukee, WI", @"lat": @43.0389, @"lon": @-87.9065},
        @{@"city": @"Albuquerque, NM", @"lat": @35.0844, @"lon": @-106.6504},
        @{@"city": @"Tucson, AZ", @"lat": @32.2226, @"lon": @-110.9747},
        @{@"city": @"Fresno, CA", @"lat": @36.7378, @"lon": @-119.7871},
        @{@"city": @"Sacramento, CA", @"lat": @38.5816, @"lon": @-121.4944},
        @{@"city": @"Mesa, AZ", @"lat": @33.4152, @"lon": @-111.8315},
        @{@"city": @"Kansas City, MO", @"lat": @39.0997, @"lon": @-94.5786},
        @{@"city": @"Atlanta, GA", @"lat": @33.7490, @"lon": @-84.3880},
        @{@"city": @"Miami, FL", @"lat": @25.7617, @"lon": @-80.1918},
        @{@"city": @"Raleigh, NC", @"lat": @35.7796, @"lon": @-78.6382},
        @{@"city": @"Omaha, NE", @"lat": @41.2565, @"lon": @-95.9345},
        @{@"city": @"Minneapolis, MN", @"lat": @44.9778, @"lon": @-93.2650},
        @{@"city": @"Cleveland, OH", @"lat": @41.4993, @"lon": @-81.6944},
        @{@"city": @"Tampa, FL", @"lat": @27.9506, @"lon": @-82.4572},
        @{@"city": @"Orlando, FL", @"lat": @28.5383, @"lon": @-81.3792},
        @{@"city": @"St. Louis, MO", @"lat": @38.6270, @"lon": @-90.1994},
        @{@"city": @"Pittsburgh, PA", @"lat": @40.4406, @"lon": @-79.9959},
        @{@"city": @"Cincinnati, OH", @"lat": @39.1031, @"lon": @-84.5120},
        @{@"city": @"Salt Lake City, UT", @"lat": @40.7608, @"lon": @-111.8910},
        @{@"city": @"Honolulu, HI", @"lat": @21.3069, @"lon": @-157.8583},
        @{@"city": @"Anchorage, AK", @"lat": @61.2181, @"lon": @-149.9003},
        @{@"city": @"New Orleans, LA", @"lat": @29.9511, @"lon": @-90.0715},
        @{@"city": @"Richmond, VA", @"lat": @37.5407, @"lon": @-77.4360},
        @{@"city": @"Buffalo, NY", @"lat": @42.8864, @"lon": @-78.8784},
        @{@"city": @"Rochester, NY", @"lat": @43.1566, @"lon": @-77.6088},
        @{@"city": @"Providence, RI", @"lat": @41.8240, @"lon": @-71.4128},
        @{@"city": @"Hartford, CT", @"lat": @41.7658, @"lon": @-72.6734},
        @{@"city": @"Boise, ID", @"lat": @43.6150, @"lon": @-116.2023},
        @{@"city": @"Des Moines, IA", @"lat": @41.5868, @"lon": @-93.6250},
        @{@"city": @"Madison, WI", @"lat": @43.0731, @"lon": @-89.4012},
    ];
}

+ (NSDictionary *)randomUSCoordinate {
    NSArray *cities = [self usCityCoordinates];
    NSDictionary *c = cities[arc4random_uniform((uint32_t)cities.count)];
    // ~±0.04° ≈ 3–4km urban jitter
    double jitterLat = ((double)arc4random_uniform(8000) / 100000.0) - 0.04;
    double jitterLon = ((double)arc4random_uniform(8000) / 100000.0) - 0.04;
    return @{
        @"lat": @([c[@"lat"] doubleValue] + jitterLat),
        @"lon": @([c[@"lon"] doubleValue] + jitterLon),
        @"city": c[@"city"] ?: @"",
        @"country": @"US",
    };
}

#pragma mark - Compatibility aliases

+ (NSArray<NSDictionary *> *)chinaCityCoordinates {
    return [self usCityCoordinates];
}

+ (NSDictionary *)randomChinaCoordinate {
    return [self randomUSCoordinate];
}

@end
