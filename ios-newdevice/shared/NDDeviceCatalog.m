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
        // iOS 18 (Dopamine-era)
        @"18.0", @"18.0.1", @"18.1", @"18.1.1",
        @"18.2", @"18.2.1", @"18.3", @"18.3.1", @"18.3.2",
        @"18.4", @"18.4.1", @"18.5",
    ];
}

+ (NSArray<NSDictionary *> *)carriers {
    return @[
        // 中国移动
        @{@"Carrier": @"中国移动", @"MCC": @"460", @"MNC": @"00"},
        @{@"Carrier": @"中国移动", @"MCC": @"460", @"MNC": @"02"},
        @{@"Carrier": @"中国移动", @"MCC": @"460", @"MNC": @"04"},
        @{@"Carrier": @"中国移动", @"MCC": @"460", @"MNC": @"07"},
        @{@"Carrier": @"中国移动", @"MCC": @"460", @"MNC": @"08"},
        // 中国联通
        @{@"Carrier": @"中国联通", @"MCC": @"460", @"MNC": @"01"},
        @{@"Carrier": @"中国联通", @"MCC": @"460", @"MNC": @"06"},
        @{@"Carrier": @"中国联通", @"MCC": @"460", @"MNC": @"09"},
        // 中国电信
        @{@"Carrier": @"中国电信", @"MCC": @"460", @"MNC": @"03"},
        @{@"Carrier": @"中国电信", @"MCC": @"460", @"MNC": @"05"},
        @{@"Carrier": @"中国电信", @"MCC": @"460", @"MNC": @"11"},
        // 中国广电
        @{@"Carrier": @"中国广电", @"MCC": @"460", @"MNC": @"15"},
    ];
}

+ (NSArray<NSString *> *)radioAccessTypes {
    // Weighted toward modern RATs; no bare "WiFi" (that value is not a CT RAT string)
    return @[@"LTE", @"LTE", @"LTE", @"NR", @"NR", @"NRNSA", @"WCDMA"];
}

+ (NSArray<NSDictionary *> *)chinaCityCoordinates {
    // Landmark-ish urban centers (not ocean/desert). Small jitter applied in randomChinaCoordinate.
    return @[
        @{@"city": @"北京", @"lat": @39.9042, @"lon": @116.4074},
        @{@"city": @"上海", @"lat": @31.2304, @"lon": @121.4737},
        @{@"city": @"广州", @"lat": @23.1291, @"lon": @113.2644},
        @{@"city": @"深圳", @"lat": @22.5431, @"lon": @114.0579},
        @{@"city": @"成都", @"lat": @30.5728, @"lon": @104.0668},
        @{@"city": @"杭州", @"lat": @30.2741, @"lon": @120.1551},
        @{@"city": @"重庆", @"lat": @29.5630, @"lon": @106.5516},
        @{@"city": @"武汉", @"lat": @30.5928, @"lon": @114.3055},
        @{@"city": @"西安", @"lat": @34.3416, @"lon": @108.9398},
        @{@"city": @"南京", @"lat": @32.0603, @"lon": @118.7969},
        @{@"city": @"苏州", @"lat": @31.2989, @"lon": @120.5853},
        @{@"city": @"天津", @"lat": @39.3434, @"lon": @117.3616},
        @{@"city": @"长沙", @"lat": @28.2282, @"lon": @112.9388},
        @{@"city": @"郑州", @"lat": @34.7466, @"lon": @113.6253},
        @{@"city": @"青岛", @"lat": @36.0671, @"lon": @120.3826},
        @{@"city": @"大连", @"lat": @38.9140, @"lon": @121.6147},
        @{@"city": @"厦门", @"lat": @24.4798, @"lon": @118.0894},
        @{@"city": @"福州", @"lat": @26.0745, @"lon": @119.2965},
        @{@"city": @"济南", @"lat": @36.6512, @"lon": @117.1201},
        @{@"city": @"合肥", @"lat": @31.8206, @"lon": @117.2272},
        @{@"city": @"昆明", @"lat": @25.0389, @"lon": @102.7183},
        @{@"city": @"贵阳", @"lat": @26.6470, @"lon": @106.6302},
        @{@"city": @"南宁", @"lat": @22.8170, @"lon": @108.3669},
        @{@"city": @"海口", @"lat": @20.0440, @"lon": @110.1999},
        @{@"city": @"沈阳", @"lat": @41.8057, @"lon": @123.4315},
        @{@"city": @"长春", @"lat": @43.8171, @"lon": @125.3235},
        @{@"city": @"哈尔滨", @"lat": @45.8038, @"lon": @126.5349},
        @{@"city": @"石家庄", @"lat": @38.0428, @"lon": @114.5149},
        @{@"city": @"太原", @"lat": @37.8706, @"lon": @112.5489},
        @{@"city": @"南昌", @"lat": @28.6820, @"lon": @115.8579},
        @{@"city": @"宁波", @"lat": @29.8683, @"lon": @121.5440},
        @{@"city": @"无锡", @"lat": @31.4912, @"lon": @120.3119},
        @{@"city": @"东莞", @"lat": @23.0207, @"lon": @113.7518},
        @{@"city": @"佛山", @"lat": @23.0215, @"lon": @113.1214},
        @{@"city": @"珠海", @"lat": @22.2710, @"lon": @113.5767},
        @{@"city": @"中山", @"lat": @22.5170, @"lon": @113.3927},
        @{@"city": @"惠州", @"lat": @23.1115, @"lon": @114.4152},
        @{@"city": @"温州", @"lat": @27.9949, @"lon": @120.6994},
        @{@"city": @"金华", @"lat": @29.0790, @"lon": @119.6474},
        @{@"city": @"嘉兴", @"lat": @30.7461, @"lon": @120.7555},
        @{@"city": @"常州", @"lat": @31.8107, @"lon": @119.9741},
        @{@"city": @"徐州", @"lat": @34.2058, @"lon": @117.2841},
        @{@"city": @"扬州", @"lat": @32.3942, @"lon": @119.4129},
        @{@"city": @"洛阳", @"lat": @34.6197, @"lon": @112.4540},
        @{@"city": @"烟台", @"lat": @37.4638, @"lon": @121.4479},
        @{@"city": @"潍坊", @"lat": @36.7069, @"lon": @119.1619},
        @{@"city": @"临沂", @"lat": @35.1041, @"lon": @118.3564},
        @{@"city": @"保定", @"lat": @38.8739, @"lon": @115.4646},
        @{@"city": @"廊坊", @"lat": @39.5239, @"lon": @116.7055},
        @{@"city": @"乌鲁木齐", @"lat": @43.8256, @"lon": @87.6168},
        @{@"city": @"兰州", @"lat": @36.0611, @"lon": @103.8343},
        @{@"city": @"银川", @"lat": @38.4872, @"lon": @106.2309},
        @{@"city": @"西宁", @"lat": @36.6171, @"lon": @101.7782},
        @{@"city": @"呼和浩特", @"lat": @40.8424, @"lon": @111.7492},
        @{@"city": @"拉萨", @"lat": @29.6525, @"lon": @91.1721},
    ];
}

+ (NSDictionary *)randomChinaCoordinate {
    NSArray *cities = [self chinaCityCoordinates];
    NSDictionary *c = cities[arc4random_uniform((uint32_t)cities.count)];
    // ~±0.04° ≈ 3–4km urban jitter
    double jitterLat = ((double)arc4random_uniform(8000) / 100000.0) - 0.04;
    double jitterLon = ((double)arc4random_uniform(8000) / 100000.0) - 0.04;
    return @{
        @"lat": @([c[@"lat"] doubleValue] + jitterLat),
        @"lon": @([c[@"lon"] doubleValue] + jitterLon),
        @"city": c[@"city"] ?: @"",
    };
}

@end
