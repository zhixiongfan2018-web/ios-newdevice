#import "NDDeviceProfile.h"
#import "NDDeviceCatalog.h"
#import "NDDeviceCatalog+Metrics.h"
#import "NDConfig.h"
#import <stdlib.h>
#import <float.h>
#import <mach/mach_time.h>

static NSString *NDRandomHex(NSUInteger length) {
    static const char *hex = "0123456789abcdef";
    NSMutableString *s = [NSMutableString stringWithCapacity:length];
    for (NSUInteger i = 0; i < length; i++) {
        [s appendFormat:@"%c", hex[arc4random_uniform(16)]];
    }
    return s;
}

static NSString *NDRandomUUID(void) {
    return [[NSUUID UUID] UUIDString];
}

/// AMG faker stores DiskSpace/Memory as decimal strings — NSString has no unsignedLongLongValue on some iOS builds.
static unsigned long long NDUnsignedLongLongFrom(id v) {
    if (!v || v == [NSNull null]) return 0;
    if ([v isKindOfClass:[NSNumber class]]) return [(NSNumber *)v unsignedLongLongValue];
    if ([v isKindOfClass:[NSString class]]) {
        NSString *s = [(NSString *)v stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
        if (!s.length) return 0;
        return strtoull(s.UTF8String, NULL, 10);
    }
    if ([v respondsToSelector:@selector(longLongValue)]) return (unsigned long long)[v longLongValue];
    return 0;
}

/// Apple-assigned OUI prefixes commonly seen on iPhone Wi‑Fi / BT interfaces.
static NSArray<NSString *> *NDAppleOUIs(void) {
    static NSArray<NSString *> *ouis;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        ouis = @[
            @"00:1E:C2", @"00:25:00", @"04:0C:CE", @"04:15:52", @"04:26:65",
            @"04:48:9A", @"04:54:53", @"04:DB:56", @"04:E5:36", @"08:66:98",
            @"08:70:45", @"0C:74:C2", @"0C:BC:9F", @"10:1C:0C", @"10:94:BB",
            @"14:10:9F", @"14:20:5E", @"14:7D:DA", @"18:65:90", @"1C:1A:C0",
            @"1C:36:BB", @"20:78:F0", @"24:A0:74", @"24:F0:94", @"28:37:37",
            @"28:6A:BA", @"28:CF:E9", @"2C:1F:23", @"30:90:AB", @"34:15:9E",
            @"34:A3:95", @"38:89:2C", @"3C:07:54", @"40:30:04", @"40:33:1A",
            @"40:A6:D9", @"44:2A:60", @"48:43:7C", @"4C:74:BF", @"50:32:37",
            @"54:26:96", @"54:72:4F", @"58:55:CA", @"5C:8D:4E", @"5C:95:AE",
            @"60:33:4B", @"60:92:17", @"64:A3:CB", @"64:B0:A6", @"68:09:27",
            @"68:96:7B", @"68:D9:3C", @"6C:40:08", @"6C:70:9F", @"6C:72:E7",
            @"70:3E:AC", @"70:48:0F", @"70:DE:E2", @"74:1B:B2", @"78:4F:43",
            @"78:7E:61", @"7C:01:91", @"7C:04:D0", @"7C:11:BE", @"7C:50:49",
            @"80:BE:05", @"80:E6:50", @"84:38:35", @"84:89:AD", @"84:A1:34",
            @"88:63:DF", @"88:66:A5", @"8C:29:37", @"8C:85:90", @"90:27:E4",
            @"90:B0:ED", @"94:BF:2D", @"98:01:A7", @"98:10:E8", @"9C:04:EB",
            @"9C:84:BF", @"9C:F3:87", @"A4:83:E7", @"A4:B1:97", @"A8:60:B6",
            @"A8:BB:CF", @"AC:1F:74", @"AC:87:A3", @"AC:BC:32", @"B0:65:BD",
            @"B4:F0:AB", @"B8:17:C2", @"B8:53:AC", @"B8:63:4D", @"B8:C1:11",
            @"BC:52:B7", @"BC:67:78", @"BC:92:6B", @"C0:A5:3E", @"C8:69:CD",
            @"C8:B5:B7", @"CC:08:E0", @"CC:25:EF", @"D0:03:4B", @"D0:23:DB",
            @"D0:4F:7E", @"D4:61:9D", @"D8:1C:79", @"D8:A2:5E", @"DC:2B:2A",
            @"DC:37:14", @"DC:56:E7", @"E0:33:8E", @"E0:B9:BA", @"E4:CE:8F",
            @"E8:04:0B", @"E8:80:2E", @"EC:35:86", @"F0:18:98", @"F0:99:BF",
            @"F0:DB:E2", @"F4:0F:24", @"F4:F1:5A", @"F8:1E:DF", @"F8:4D:89",
            @"FC:25:3F", @"FC:E9:98",
        ];
    });
    return ouis;
}

static NSString *NDRandomMAC(void) {
    NSString *oui = NDAppleOUIs()[arc4random_uniform((uint32_t)NDAppleOUIs().count)];
    // Globally administered (clear multicast + local bits) — matches real Apple NICs
    uint8_t b3 = (uint8_t)arc4random_uniform(256);
    uint8_t b4 = (uint8_t)arc4random_uniform(256);
    uint8_t b5 = (uint8_t)arc4random_uniform(256);
    return [NSString stringWithFormat:@"%@:%02X:%02X:%02X", oui, b3, b4, b5];
}

static NSString *NDLuhnCheckDigit(NSString *digits) {
    NSInteger sum = 0;
    BOOL dbl = YES;
    for (NSInteger i = (NSInteger)digits.length - 1; i >= 0; i--) {
        NSInteger d = [digits characterAtIndex:(NSUInteger)i] - '0';
        if (dbl) {
            d *= 2;
            if (d > 9) d -= 9;
        }
        sum += d;
        dbl = !dbl;
    }
    return [NSString stringWithFormat:@"%ld", (long)((10 - (sum % 10)) % 10)];
}

/// Same OUI family as Wi‑Fi, different NIC — how real iPhones expose Wifi/BT addresses.
static NSString *NDPairedBTMAC(NSString *wifiMAC, uint32_t seed) {
    NSString *oui = @"A4:83:E7";
    if (wifiMAC.length >= 8) oui = [[wifiMAC substringToIndex:8] uppercaseString];
    uint8_t b3 = (uint8_t)((seed >> 8) & 0xff);
    uint8_t b4 = (uint8_t)((seed >> 16) & 0xff);
    uint8_t b5 = (uint8_t)(((seed >> 24) ^ 0x5A) & 0xff);
    return [NSString stringWithFormat:@"%@:%02X:%02X:%02X", oui, b3, b4, b5];
}

static BOOL NDAppleOUIKnown(NSString *mac) {
    if (mac.length < 8) return NO;
    NSString *oui = [[mac substringToIndex:8] uppercaseString];
    for (NSString *o in NDAppleOUIs()) {
        if ([o isEqualToString:oui]) return YES;
    }
    return NO;
}

static BOOL NDLooksLikeAppleSerial(NSString *s) {
    if (s.length < 10 || s.length > 12) return NO;
    NSCharacterSet *ok = [NSCharacterSet characterSetWithCharactersInString:@"ABCDEFGHJKLMNPQRSTUVWXYZ0123456789"];
    if ([s.uppercaseString rangeOfCharacterFromSet:ok.invertedSet].location != NSNotFound) return NO;
    // Reject pure hex blobs (common bad imports) — real serials mix letters beyond A-F.
    NSCharacterSet *hexOnly = [NSCharacterSet characterSetWithCharactersInString:@"0123456789ABCDEF"];
    BOOL allHex = [s.uppercaseString rangeOfCharacterFromSet:hexOnly.invertedSet].location == NSNotFound;
    if (allHex) return NO;
    NSCharacterSet *letters = [NSCharacterSet letterCharacterSet];
    NSCharacterSet *digits = [NSCharacterSet decimalDigitCharacterSet];
    BOOL hasLetter = [s rangeOfCharacterFromSet:letters].location != NSNotFound;
    BOOL hasDigit = [s rangeOfCharacterFromSet:digits].location != NSNotFound;
    return hasLetter && hasDigit;
}

static NSString *NDSeededSerial(uint32_t seed) {
    static NSString *alpha = @"CDEFGHJKLMNPQRSTUVWXYZ";
    static NSString *alnum = @"CDEFGHJKLMNPQRSTUVWXYZ0123456789";
    NSUInteger len = ((seed % 100) < 65) ? 10 : 12;
    NSMutableString *s = [NSMutableString stringWithCapacity:len];
    uint32_t x = seed ? seed : 1;
    [s appendFormat:@"%C", [alpha characterAtIndex:x % alpha.length]];
    for (NSUInteger i = 1; i < len; i++) {
        x = x * 1664525u + 1013904223u;
        [s appendFormat:@"%C", [alnum characterAtIndex:x % alnum.length]];
    }
    // Guarantee not pure-hex
    if (!NDLooksLikeAppleSerial(s)) {
        [s replaceCharactersInRange:NSMakeRange(MIN(3, s.length - 1), 1) withString:@"K"];
        [s replaceCharactersInRange:NSMakeRange(MIN(5, s.length - 1), 1) withString:@"7"];
    }
    return s;
}

static NSString *NDSeededIMEI(uint32_t seed) {
    static NSArray<NSString *> *tacs;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        tacs = @[
            @"35391808", @"35433810", @"35693803", @"35326005", @"35929806",
            @"35328509", @"35407110", @"35838708", @"35332210", @"35728009",
            @"35316711", @"35499910", @"35875508", @"35307909", @"35940508",
        ];
    });
    NSString *tac = tacs[seed % tacs.count];
    NSString *snr = [NSString stringWithFormat:@"%06u", (seed / 17) % 1000000];
    NSString *body = [tac stringByAppendingString:snr];
    return [body stringByAppendingString:NDLuhnCheckDigit(body)];
}

/// Modern iPhone serials are typically 10 chars (newer) or 12 chars (legacy).
static NSString *NDRandomSerial(void) {
    return NDSeededSerial(arc4random());
}

/// Userland IMEI string (15 digits). Not baseband-level; for apps reading Gestalt / CT.
static NSString *NDRandomIMEI(void) {
    static NSArray<NSString *> *tacs;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        // Publicly documented / commonly observed Apple TAC prefixes (8 digits)
        tacs = @[
            @"35391808", @"35433810", @"35693803", @"35326005", @"35929806",
            @"35328509", @"35407110", @"35838708", @"35332210", @"35728009",
            @"35316711", @"35499910", @"35875508", @"35307909", @"35940508",
        ];
    });
    NSString *tac = tacs[arc4random_uniform((uint32_t)tacs.count)];
    NSString *snr = [NSString stringWithFormat:@"%06u", arc4random_uniform(1000000)];
    NSString *body = [tac stringByAppendingString:snr];
    return [body stringByAppendingString:NDLuhnCheckDigit(body)];
}

static NSString *NDRandomOpenUDID(void) {
    return NDRandomHex(40);
}

static NSTimeInterval NDRandomBootTime(void) {
    // Boot sometime in the last 1–14 days
    NSTimeInterval now = [[NSDate date] timeIntervalSince1970];
    NSTimeInterval ago = 3600.0 + arc4random_uniform(14 * 24 * 3600);
    return now - ago;
}

static NSDictionary<NSString *, NSString *> *NDKnownBuilds(void) {
    return [NDDeviceCatalog officialSystemBuilds];
}

static NSString *NDRandomBuild(NSString *systemVer) {
    NSString *hit = [NDDeviceCatalog buildForSystemVersion:systemVer ?: @""];
    if (hit.length) return hit;

    NSArray *parts = [systemVer componentsSeparatedByString:@"."];
    NSInteger major = parts.count ? [parts[0] integerValue] : 18;
    // iOS N → (N+4)Axxx  (15→19A, 16→20A, 17→21A, 18→22A)
    NSInteger train = major + 4;
    if (train < 19) train = 19;
    return [NSString stringWithFormat:@"%ldA%u", (long)train, 100u + arc4random_uniform(800)];
}

static BOOL NDLooksLikeProductType(NSString *s) {
    if (s.length < 5) return NO;
    NSRegularExpression *re = [NSRegularExpression regularExpressionWithPattern:@"^(iPhone|iPad)\\d+,\\d+$" options:0 error:nil];
    return [re numberOfMatchesInString:s options:0 range:NSMakeRange(0, s.length)] == 1;
}

@implementation NDDeviceProfile

+ (instancetype)originalProfile {
    NDDeviceProfile *p = [NDDeviceProfile new];
    p.name = @"原始机器";
    p.enabled = YES;
    p.spoofDeviceIdentity = NO;
    p.createdAt = [NSDate date];
    p.IDFA = @"";
    p.IDFV = @"";
    p.UUID = @"";
    p.Serial = @"";
    p.UDID = @"";
    p.WiFiMAC = @"";
    p.BTMAC = @"";
    p.DeviceToken = @"";
    p.IMEI = @"";
    p.IMEI2 = @"";
    p.SSID = @"";
    p.BSSID = @"";
    p.OpenUDID = @"";
    p.TimeZone = @"";
    p.BootTime = 0;
    p.DeviceColor = @"";
    p.DiskCapacity = 0;
    p.PhysicalMemory = 0;
    p.Brightness = -1;
    p.BatteryLevel = -1;
    p.ICCID = @"";
    p.AdvertisingTrackingEnabled = YES;
    p.Model = @"";
    p.DeviceName = @"";
    p.ProductType = @"";
    p.HardwareMachine = @"";
    p.SystemVer = @"";
    p.Build = @"";
    p.Carrier = @"";
    p.MCC = @"";
    p.MNC = @"";
    p.RadioAccess = @"";
    p.Latitude = 0;
    p.Longitude = 0;
    p.Altitude = 10;
    return p;
}

+ (instancetype)randomProfileWithName:(NSString *)name
                       preferredModel:(NSString *)model
                      preferredSystem:(NSString *)systemVer {
    NDDeviceProfile *p = [NDDeviceProfile new];
    p.name = name;
    p.enabled = YES;
    p.spoofDeviceIdentity = YES;
    p.createdAt = [NSDate date];

    // Extra entropy so rapid 一键新机 / AMG fill never collide on weak patterns.
    uint32_t tick = (uint32_t)mach_absolute_time();
    uint32_t nameMix = 2166136261u;
    for (const char *cs = (name ?: @"").UTF8String; cs && *cs; cs++) {
        nameMix ^= (uint8_t)(*cs);
        nameMix *= 16777619u;
    }

    NSDictionary *dev = nil;
    NSArray *allModels = [NDDeviceCatalog deviceModels];
    BOOL allowPad = [NDConfig shared].allowIPadSpoof;
    NSMutableArray *models = [NSMutableArray array];
    for (NSDictionary *m in allModels) {
        NSString *pt = m[@"ProductType"] ?: @"";
        if (!allowPad && [pt hasPrefix:@"iPad"]) continue;
        [models addObject:m];
    }
    if (!models.count) models = [allModels mutableCopy];

    if (model.length) {
        for (NSDictionary *m in allModels) {
            if ([m[@"Model"] isEqualToString:model] || [m[@"ProductType"] isEqualToString:model]) {
                dev = m;
                break;
            }
        }
    }
    if (!dev) {
        // Bias toward recent devices (14+) without excluding older ones
        NSUInteger biasStart = 0;
        for (NSUInteger i = 0; i < models.count; i++) {
            NSString *pt = models[i][@"ProductType"];
            if ([pt hasPrefix:@"iPhone14,"] || [pt hasPrefix:@"iPhone15,"] ||
                [pt hasPrefix:@"iPhone16,"] || [pt hasPrefix:@"iPhone17,"]) {
                biasStart = i;
                break;
            }
        }
        if (biasStart > 0 && arc4random_uniform(100) < 70) {
            NSUInteger span = models.count - biasStart;
            dev = models[biasStart + ((arc4random_uniform((uint32_t)span) + tick) % span)];
        } else {
            dev = models[(arc4random_uniform((uint32_t)models.count) + tick) % models.count];
        }
    }

    NSArray *systems = [NDDeviceCatalog systemVersions]; // already iOS 18+ only
    NSString *sys = systemVer;
    if (sys.length && [NDDeviceCatalog majorSystemVersion:sys] < 18) sys = @"";
    if (!sys.length) {
        if (systems.count) {
            sys = systems[(arc4random_uniform((uint32_t)systems.count) + tick) % systems.count];
        } else {
            sys = @"18.5";
        }
    }
    NSArray *carrierList = [NDDeviceCatalog carriers];
    NSDictionary *carrier = carrierList[(arc4random_uniform((uint32_t)carrierList.count) + (tick >> 3)) % carrierList.count];
    NSDictionary *coord = [NDDeviceCatalog randomUSCoordinate];

    p.IDFA = NDRandomUUID();
    p.IDFV = NDRandomUUID();
    p.UUID = NDRandomUUID();
    p.Serial = NDRandomSerial();
    p.UDID = NDRandomHex(40); // lowercase 40-hex, matches Apple UDID style
    p.WiFiMAC = NDRandomMAC();
    p.BTMAC = NDPairedBTMAC(p.WiFiMAC, arc4random() ^ tick ^ nameMix);
    p.DeviceToken = NDRandomHex(64);
    p.IMEI = NDRandomIMEI();
    p.IMEI2 = NDRandomIMEI();
    NSDictionary *wifi = [NDDeviceCatalog randomWiFiNetwork];
    p.SSID = wifi[@"SSID"] ?: @"HomeWiFi";
    p.BSSID = wifi[@"BSSID"] ?: @"00:00:00:00:00:00";
    p.OpenUDID = NDRandomOpenUDID();
    p.BootTime = NDRandomBootTime();
    static NSArray<NSString *> *colors;
    static dispatch_once_t colorOnce;
    dispatch_once(&colorOnce, ^{
        colors = @[@"Black", @"White", @"Blue", @"Pink", @"Yellow", @"Green", @"Purple", @"NaturalTitanium", @"BlueTitanium", @"WhiteTitanium", @"BlackTitanium"];
    });
    p.DeviceColor = colors[(arc4random_uniform((uint32_t)colors.count) + tick) % colors.count];
    p.DiskCapacity = [NDDeviceCatalog diskBytesForProductType:dev[@"ProductType"]];
    p.PhysicalMemory = [NDDeviceCatalog memoryBytesForProductType:dev[@"ProductType"]];
    p.Brightness = 0.35f + (arc4random_uniform(50) / 100.0f);
    p.BatteryLevel = 0.25f + (arc4random_uniform(70) / 100.0f);
    p.ICCID = [NSString stringWithFormat:@"8901%016llu", ((unsigned long long)arc4random() << 32) | (arc4random() ^ tick)];
    if (p.ICCID.length > 20) p.ICCID = [p.ICCID substringToIndex:20];
    p.AdvertisingTrackingEnabled = YES;

    p.Model = dev[@"Model"];
    // AMG-style user device name — mix record name so environments don't share the same label
    static NSArray<NSString *> *namePrefixes;
    static dispatch_once_t nameOnce;
    dispatch_once(&nameOnce, ^{
        namePrefixes = @[@"Alex", @"Jordan", @"Sam", @"Taylor", @"Chris", @"Jamie", @"Casey", @"Morgan", @"Riley", @"Avery",
                         @"Drew", @"Quinn", @"Reese", @"Skyler", @"Parker", @"Cameron", @"Blake", @"Hayden", @"Rowan", @"Sage"];
    });
    NSString *who = namePrefixes[(nameMix + tick) % namePrefixes.count];
    BOOL isPad = [((NSString *)dev[@"ProductType"] ?: @"") hasPrefix:@"iPad"];
    p.DeviceName = [NSString stringWithFormat:@"%@'s %@", who, isPad ? @"iPad" : @"iPhone"];
    p.ProductType = dev[@"ProductType"];
    p.HardwareMachine = dev[@"HardwareMachine"];
    p.SystemVer = sys;
    p.Build = NDRandomBuild(sys);

    p.Carrier = carrier[@"Carrier"];
    p.MCC = carrier[@"MCC"];
    p.MNC = carrier[@"MNC"];
    NSArray *rats = [NDDeviceCatalog radioAccessTypes];
    p.RadioAccess = rats[(arc4random_uniform((uint32_t)rats.count) + tick) % rats.count];

    p.Latitude = [coord[@"lat"] doubleValue];
    p.Longitude = [coord[@"lon"] doubleValue];
    p.TimeZone = coord[@"timezone"] ?: @"America/New_York";
    // Urban altitude: mostly low buildings / street level
    p.Altitude = 8.0 + (double)arc4random_uniform(120) + ((double)arc4random_uniform(100) / 100.0);
    return p;
}

+ (BOOL)NDStringLooksBase64:(NSString *)s {
    if (![s isKindOfClass:[NSString class]] || s.length < 8) return NO;
    NSString *compact = [[s stringByReplacingOccurrencesOfString:@" " withString:@""]
                         stringByReplacingOccurrencesOfString:@"\n" withString:@""];
    if (compact.length < 8 || (compact.length % 4) != 0) return NO;
    NSCharacterSet *allowed = [NSCharacterSet characterSetWithCharactersInString:@"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/="];
    return [compact rangeOfCharacterFromSet:allowed.invertedSet].location == NSNotFound;
}

+ (BOOL)NDStringLooksLikeUUID:(NSString *)s {
    return [[NSUUID alloc] initWithUUIDString:s] != nil;
}

+ (BOOL)NDStringLooksLikeMAC:(NSString *)s {
    if (s.length < 11) return NO;
    NSRegularExpression *re = [NSRegularExpression regularExpressionWithPattern:@"^([0-9A-Fa-f]{2}:){5}[0-9A-Fa-f]{2}$" options:0 error:nil];
    return [re numberOfMatchesInString:s options:0 range:NSMakeRange(0, s.length)] == 1;
}

+ (BOOL)NDStringLooksPlaintextIdentity:(NSString *)s forKey:(NSString *)key {
    if (![s isKindOfClass:[NSString class]] || !s.length) return NO;
    if ([key isEqualToString:@"IDFA"] || [key isEqualToString:@"IDFV"] || [key isEqualToString:@"UUID"]) {
        return [self NDStringLooksLikeUUID:s];
    }
    if ([key isEqualToString:@"WiFiMAC"] || [key isEqualToString:@"BTMAC"] || [key isEqualToString:@"BSSID"] ||
        [key isEqualToString:@"WifiAddress"] || [key isEqualToString:@"BlueAddress"] || [key isEqualToString:@"BluetoothAddress"]) {
        return [self NDStringLooksLikeMAC:s];
    }
    if ([key isEqualToString:@"UDID"]) {
        NSCharacterSet *hex = [NSCharacterSet characterSetWithCharactersInString:@"0123456789abcdefABCDEF"];
        return s.length == 40 && [s rangeOfCharacterFromSet:hex.invertedSet].location == NSNotFound;
    }
    if ([key isEqualToString:@"Serial"] || [key isEqualToString:@"SerialNumber"] || [key isEqualToString:@"SerialNum"]) {
        // Apple serial-ish: alphanumeric, typically 10–12
        if (s.length < 8 || s.length > 16) return NO;
        NSCharacterSet *ok = [NSCharacterSet characterSetWithCharactersInString:@"ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789"];
        return [s.uppercaseString rangeOfCharacterFromSet:ok.invertedSet].location == NSNotFound;
    }
    if ([key isEqualToString:@"SystemVer"] || [key isEqualToString:@"SystemVersion"] || [key isEqualToString:@"ProductVersion"]) {
        return [s rangeOfString:@"."].location != NSNotFound && s.length < 16;
    }
    if ([key isEqualToString:@"SSID"] || [key isEqualToString:@"Name"] || [key isEqualToString:@"Build"] || [key isEqualToString:@"BuildVersion"]) {
        // Reject typical AES-ciphertext Base64 (high density of +/)
        if ([self NDStringLooksBase64:s] && s.length >= 16 && ![s containsString:@" "] && ![s containsString:@"-"]) {
            NSData *raw = [[NSData alloc] initWithBase64EncodedString:[s stringByReplacingOccurrencesOfString:@" " withString:@""] options:0];
            if (raw.length >= 16 && (raw.length % 16) == 0) {
                // If not printable UTF-8 short string, treat as cipher
                NSString *decoded = [[NSString alloc] initWithData:raw encoding:NSUTF8StringEncoding];
                if (!decoded.length) return NO;
            }
        }
        return s.length < 64;
    }
    return YES;
}

+ (BOOL)dictionaryLooksLikeEncryptedAMGFaker:(NSDictionary *)dict {
    if (![dict isKindOfClass:[NSDictionary class]] || !dict.count) return NO;
    NSArray *probeKeys = @[@"IDFA", @"IDFV", @"UDID", @"WifiAddress", @"BlueAddress", @"SerialNumber", @"SystemVer", @"SSID"];
    NSInteger cipherHits = 0;
    NSInteger considered = 0;
    for (NSString *key in probeKeys) {
        id v = dict[key];
        if (![v isKindOfClass:[NSString class]] || ![v length]) continue;
        considered++;
        NSString *s = v;
        NSString *compact = [[s stringByReplacingOccurrencesOfString:@" " withString:@""]
                             stringByReplacingOccurrencesOfString:@"\n" withString:@""];
        NSData *raw = [[NSData alloc] initWithBase64EncodedString:compact options:0];
        BOOL sizedLikeAES = raw.length >= 16 && (raw.length % 16) == 0;
        BOOL notPlain = ![self NDStringLooksPlaintextIdentity:s forKey:key];
        if (sizedLikeAES && notPlain) cipherHits++;
    }
    return considered >= 3 && cipherHits >= 2;
}

+ (BOOL)dictionaryHasImportableIdentity:(NSDictionary *)dict {
    if (![dict isKindOfClass:[NSDictionary class]]) return NO;
    if ([self dictionaryLooksLikeEncryptedAMGFaker:dict]) return NO;
    NSDictionary *n = [self normalizedImportDictionary:dict];
    NSArray *keys = @[@"IDFA", @"IDFV", @"UDID", @"Serial", @"WiFiMAC", @"BTMAC", @"IMEI", @"DeviceToken", @"SSID"];
    for (NSString *k in keys) {
        NSString *v = n[k];
        if ([v isKindOfClass:[NSString class]] && v.length && [self NDStringLooksPlaintextIdentity:v forKey:k]) {
            return YES;
        }
    }
    // Numeric geo / version alone is not enough
    return NO;
}

+ (NSDictionary *)normalizedImportDictionary:(NSDictionary *)dict {
    if (![dict isKindOfClass:[NSDictionary class]]) return @{};
    NSMutableDictionary *d = [dict mutableCopy];

    // Record name — prefer explicit record title fields, NOT AMG device Name
    if (!d[@"name"] && d[@"RecordName"]) d[@"name"] = d[@"RecordName"];
    if (!d[@"name"] && d[@"RecordID"]) d[@"name"] = d[@"RecordID"];
    if (!d[@"name"] && d[@"title"]) d[@"name"] = d[@"title"];
    if (!d[@"remark"] && d[@"Remark"]) d[@"remark"] = d[@"Remark"];
    if (!d[@"remark"] && d[@"note"]) d[@"remark"] = d[@"note"];
    if (!d[@"remark"] && d[@"Note"]) d[@"remark"] = d[@"Note"];
    if (!d[@"remark"] && d[@"comment"]) d[@"remark"] = d[@"comment"];
    if (!d[@"remark"] && d[@"memo"]) d[@"remark"] = d[@"memo"];

    // AMG faker "Name" is the user-assigned device name (UIDevice.name), not record title
    if (!d[@"DeviceName"] && d[@"Name"] && [self NDStringLooksPlaintextIdentity:d[@"Name"] forKey:@"Name"]) {
        d[@"DeviceName"] = d[@"Name"];
    }
    if (!d[@"DeviceName"] && d[@"UserAssignedDeviceName"]) d[@"DeviceName"] = d[@"UserAssignedDeviceName"];

    // Identity aliases used by AMG / AWZ / CTW / Gestalt-style exports
    if (!d[@"UDID"] && d[@"UniqueDeviceID"]) d[@"UDID"] = d[@"UniqueDeviceID"];
    if (!d[@"IDFA"] && d[@"AdvertisingIdentifier"]) d[@"IDFA"] = d[@"AdvertisingIdentifier"];
    if (!d[@"IDFV"] && d[@"IdentifierForVendor"]) d[@"IDFV"] = d[@"IdentifierForVendor"];
    if (!d[@"Serial"] && d[@"SerialNum"]) d[@"Serial"] = d[@"SerialNum"];
    if (!d[@"Serial"] && d[@"SerialNumber"]) d[@"Serial"] = d[@"SerialNumber"];
    if (!d[@"WiFiMAC"] && d[@"MAC"]) d[@"WiFiMAC"] = d[@"MAC"];
    if (!d[@"WiFiMAC"] && d[@"WifiAddress"]) d[@"WiFiMAC"] = d[@"WifiAddress"];
    if (!d[@"WiFiMAC"] && d[@"WiFiAddress"]) d[@"WiFiMAC"] = d[@"WiFiAddress"];
    if (!d[@"BTMAC"] && d[@"BluetoothAddress"]) d[@"BTMAC"] = d[@"BluetoothAddress"];
    if (!d[@"BTMAC"] && d[@"BTAddress"]) d[@"BTMAC"] = d[@"BTAddress"];
    if (!d[@"BTMAC"] && d[@"BlueAddress"]) d[@"BTMAC"] = d[@"BlueAddress"];
    if (!d[@"SystemVer"] && d[@"SystemVersion"]) d[@"SystemVer"] = d[@"SystemVersion"];
    if (!d[@"SystemVer"] && d[@"ProductVersion"]) d[@"SystemVer"] = d[@"ProductVersion"];
    if (!d[@"Build"] && d[@"BuildVersion"]) d[@"Build"] = d[@"BuildVersion"];
    // Marketing model — do NOT map DeviceName (user phone name) onto Model
    if (!d[@"Model"] && d[@"DeviceModel"]) d[@"Model"] = d[@"DeviceModel"];
    if (!d[@"Model"] && d[@"MarketingProductName"]) d[@"Model"] = d[@"MarketingProductName"];
    if (!d[@"ProductType"] && d[@"HardwareMachine"]) d[@"ProductType"] = d[@"HardwareMachine"];
    if (!d[@"HardwareMachine"] && d[@"ProductType"]) d[@"HardwareMachine"] = d[@"ProductType"];
    if (!d[@"IMEI"] && d[@"InternationalMobileEquipmentIdentity"]) d[@"IMEI"] = d[@"InternationalMobileEquipmentIdentity"];
    if (!d[@"IMEI2"] && d[@"InternationalMobileEquipmentIdentity2"]) d[@"IMEI2"] = d[@"InternationalMobileEquipmentIdentity2"];
    if (!d[@"Carrier"] && d[@"CarrierName"]) d[@"Carrier"] = d[@"CarrierName"];
    if (!d[@"MCC"] && d[@"MobileCountryCode"]) d[@"MCC"] = d[@"MobileCountryCode"];
    if (!d[@"MNC"] && d[@"MobileNetworkCode"]) d[@"MNC"] = d[@"MobileNetworkCode"];
    if (!d[@"RadioAccess"] && d[@"CurrentRadioAccessTechnology"]) d[@"RadioAccess"] = d[@"CurrentRadioAccessTechnology"];
    if (!d[@"DeviceClass"] && d[@"DeviceClassNumber"]) d[@"DeviceClass"] = d[@"DeviceClassNumber"];

    // Disk / RAM / brightness / uptime (AMG faker.plist)
    if (!d[@"DiskCapacity"] && d[@"DiskSpace"]) d[@"DiskCapacity"] = d[@"DiskSpace"];
    if (!d[@"DiskCapacity"] && d[@"TotalDiskCapacity"]) d[@"DiskCapacity"] = d[@"TotalDiskCapacity"];
    if (!d[@"PhysicalMemory"] && d[@"Memory"]) d[@"PhysicalMemory"] = d[@"Memory"];
    if (!d[@"PhysicalMemory"] && d[@"PhysicalMemorySize"]) d[@"PhysicalMemory"] = d[@"PhysicalMemorySize"];
    // Coerce string disk/RAM to NSNumber so profileFromDictionary never messages NSString with unsignedLongLongValue
    if (d[@"DiskCapacity"] && ![d[@"DiskCapacity"] isKindOfClass:[NSNumber class]]) {
        d[@"DiskCapacity"] = @(NDUnsignedLongLongFrom(d[@"DiskCapacity"]));
    }
    if (d[@"PhysicalMemory"] && ![d[@"PhysicalMemory"] isKindOfClass:[NSNumber class]]) {
        d[@"PhysicalMemory"] = @(NDUnsignedLongLongFrom(d[@"PhysicalMemory"]));
    }
    if (!d[@"Brightness"] && d[@"ScreenBrightness"]) d[@"Brightness"] = d[@"ScreenBrightness"];
    // AMG may store brightness as 0..100 percent
    if (d[@"Brightness"] != nil) {
        double b = [d[@"Brightness"] doubleValue];
        if (b > 1.0 && b <= 100.0) d[@"Brightness"] = @(b / 100.0);
    }
    if (!d[@"ICCID"] && d[@"IntegratedCircuitCardIdentifier"]) d[@"ICCID"] = d[@"IntegratedCircuitCardIdentifier"];
    if (!d[@"ICCID"] && d[@"SimICCID"]) d[@"ICCID"] = d[@"SimICCID"];
    if (!d[@"BatteryLevel"] && d[@"Battery"]) d[@"BatteryLevel"] = d[@"Battery"];
    if (d[@"BatteryLevel"] != nil) {
        double b = [d[@"BatteryLevel"] doubleValue];
        if (b > 1.0 && b <= 100.0) d[@"BatteryLevel"] = @(b / 100.0);
    }

    // SystemUptime: either unix boot time or uptime seconds
    if (!d[@"BootTime"] && d[@"SystemUptime"]) {
        double v = [d[@"SystemUptime"] doubleValue];
        if (v > 1000000000.0) {
            d[@"BootTime"] = @(v);
        } else if (v > 0 && v < 1000000000.0 && ![d[@"SystemUptime"] isKindOfClass:[NSString class]]) {
            d[@"BootTime"] = @([[NSDate date] timeIntervalSince1970] - v);
        } else if ([d[@"SystemUptime"] isKindOfClass:[NSString class]] && [self NDStringLooksPlaintextIdentity:d[@"SystemUptime"] forKey:@"Build"]) {
            // numeric string
            double sv = [d[@"SystemUptime"] doubleValue];
            if (sv > 1000000000.0) d[@"BootTime"] = @(sv);
            else if (sv > 0) d[@"BootTime"] = @([[NSDate date] timeIntervalSince1970] - sv);
        }
    }
    if (!d[@"BootTime"] && d[@"kern.boottime"]) d[@"BootTime"] = d[@"kern.boottime"];

    // Nested profile dict (some backups wrap under "profile")
    if (d[@"profile"] && [d[@"profile"] isKindOfClass:[NSDictionary class]] && !d[@"IDFA"] && !d[@"UDID"]) {
        NSMutableDictionary *merged = [d[@"profile"] mutableCopy];
        for (NSString *k in d) {
            if ([k isEqualToString:@"profile"]) continue;
            if (!merged[k]) merged[k] = d[k];
        }
        return [self normalizedImportDictionary:merged];
    }
    return d;
}

+ (instancetype)profileFromDictionary:(NSDictionary *)dict {
    if (![dict isKindOfClass:[NSDictionary class]]) return nil;
    dict = [self normalizedImportDictionary:dict];
    NDDeviceProfile *p = [NDDeviceProfile new];
    p.name = dict[@"name"] ?: @"unnamed";
    p.remark = dict[@"remark"] ?: dict[@"Remark"] ?: dict[@"note"] ?: dict[@"Note"] ?: @"";
    p.enabled = dict[@"enabled"] ? [dict[@"enabled"] boolValue] : YES;
    p.spoofDeviceIdentity = dict[@"spoofDeviceIdentity"] ? [dict[@"spoofDeviceIdentity"] boolValue] : YES;
    id created = dict[@"createdAt"];
    if ([created isKindOfClass:[NSDate class]]) {
        p.createdAt = created;
    } else if ([created isKindOfClass:[NSString class]]) {
        NSDateFormatter *f = [NSDateFormatter new];
        f.dateFormat = @"yyyy-MM-dd'T'HH:mm:ssZ";
        p.createdAt = [f dateFromString:created] ?: [NSDate date];
    } else {
        p.createdAt = [NSDate date];
    }

    p.IDFA = dict[@"IDFA"] ?: @"";
    p.IDFV = dict[@"IDFV"] ?: @"";
    p.UUID = dict[@"UUID"] ?: @"";
    p.Serial = dict[@"Serial"] ?: @"";
    p.UDID = dict[@"UDID"] ?: @"";
    p.WiFiMAC = dict[@"WiFiMAC"] ?: @"";
    p.BTMAC = dict[@"BTMAC"] ?: @"";
    p.DeviceToken = dict[@"DeviceToken"] ?: @"";
    p.IMEI = dict[@"IMEI"] ?: @"";
    p.IMEI2 = dict[@"IMEI2"] ?: @"";
    p.SSID = dict[@"SSID"] ?: @"";
    p.BSSID = dict[@"BSSID"] ?: @"";
    p.OpenUDID = dict[@"OpenUDID"] ?: @"";
    p.TimeZone = dict[@"TimeZone"] ?: @"";
    p.BootTime = dict[@"BootTime"] ? [dict[@"BootTime"] doubleValue] : 0;
    p.DeviceColor = dict[@"DeviceColor"] ?: @"";
    p.DiskCapacity = NDUnsignedLongLongFrom(dict[@"DiskCapacity"]);
    p.PhysicalMemory = NDUnsignedLongLongFrom(dict[@"PhysicalMemory"]);
    if (dict[@"Brightness"] != nil) {
        p.Brightness = [dict[@"Brightness"] floatValue];
    } else {
        p.Brightness = -1;
    }
    if (dict[@"BatteryLevel"] != nil) {
        p.BatteryLevel = [dict[@"BatteryLevel"] floatValue];
    } else {
        p.BatteryLevel = -1;
    }
    p.ICCID = dict[@"ICCID"] ?: @"";
    p.AdvertisingTrackingEnabled = dict[@"AdvertisingTrackingEnabled"] ? [dict[@"AdvertisingTrackingEnabled"] boolValue] : YES;

    p.Model = dict[@"Model"] ?: @"";
    p.DeviceName = dict[@"DeviceName"] ?: @"";
    p.ProductType = dict[@"ProductType"] ?: @"";
    p.HardwareMachine = dict[@"HardwareMachine"] ?: @"";
    p.SystemVer = dict[@"SystemVer"] ?: @"";
    p.Build = dict[@"Build"] ?: @"";

    p.Carrier = dict[@"Carrier"] ?: @"";
    p.MCC = dict[@"MCC"] ?: @"";
    p.MNC = dict[@"MNC"] ?: @"";
    p.RadioAccess = dict[@"RadioAccess"] ?: @"";

    p.Latitude = [dict[@"Latitude"] doubleValue];
    p.Longitude = [dict[@"Longitude"] doubleValue];
    p.Altitude = dict[@"Altitude"] ? [dict[@"Altitude"] doubleValue] : 10;

    // Fill ProductType from catalog Model name when AMG only stored Model string
    if (!p.ProductType.length && p.Model.length) {
        for (NSDictionary *m in [NDDeviceCatalog deviceModels]) {
            if ([m[@"Model"] isEqualToString:p.Model]) {
                p.ProductType = m[@"ProductType"];
                p.HardwareMachine = m[@"HardwareMachine"];
                break;
            }
        }
    }
    if (!p.HardwareMachine.length && p.ProductType.length) {
        p.HardwareMachine = p.ProductType;
    }
    if (!p.DeviceName.length && p.Model.length && !NDLooksLikeProductType(p.Model)) {
        p.DeviceName = p.Model;
    }
    // Brightness already normalized in import dict; clamp
    if (p.Brightness > 1.0f) p.Brightness = p.Brightness / 100.0f;
    if (p.Brightness > 1.0f) p.Brightness = 1.0f;
    if (![p.name isEqualToString:@"原始机器"]) {
        [p alignConsistency];
    }
    return p;
}

+ (instancetype)profileAtPath:(NSString *)path {
    NSDictionary *dict = [NSDictionary dictionaryWithContentsOfFile:path];
    return [self profileFromDictionary:dict];
}

- (NSDictionary *)toDictionary {
    NSDateFormatter *f = [NSDateFormatter new];
    f.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
    f.dateFormat = @"yyyy-MM-dd'T'HH:mm:ssZ";
    return @{
        @"name": self.name ?: @"",
        @"remark": self.remark ?: @"",
        @"enabled": @(self.enabled),
        @"spoofDeviceIdentity": @(self.spoofDeviceIdentity),
        @"createdAt": [f stringFromDate:self.createdAt ?: [NSDate date]],
        @"IDFA": self.IDFA ?: @"",
        @"IDFV": self.IDFV ?: @"",
        @"UUID": self.UUID ?: @"",
        @"Serial": self.Serial ?: @"",
        @"UDID": self.UDID ?: @"",
        @"WiFiMAC": self.WiFiMAC ?: @"",
        @"BTMAC": self.BTMAC ?: @"",
        @"DeviceToken": self.DeviceToken ?: @"",
        @"IMEI": self.IMEI ?: @"",
        @"IMEI2": self.IMEI2 ?: @"",
        @"SSID": self.SSID ?: @"",
        @"BSSID": self.BSSID ?: @"",
        @"OpenUDID": self.OpenUDID ?: @"",
        @"TimeZone": self.TimeZone ?: @"",
        @"BootTime": @(self.BootTime),
        @"DeviceColor": self.DeviceColor ?: @"",
        @"DiskCapacity": @(self.DiskCapacity),
        @"PhysicalMemory": @(self.PhysicalMemory),
        @"Brightness": @(self.Brightness),
        @"BatteryLevel": @(self.BatteryLevel),
        @"ICCID": self.ICCID ?: @"",
        @"AdvertisingTrackingEnabled": @(self.AdvertisingTrackingEnabled),
        @"Model": self.Model ?: @"",
        @"DeviceName": self.DeviceName ?: @"",
        @"ProductType": self.ProductType ?: @"",
        @"HardwareMachine": self.HardwareMachine ?: @"",
        @"SystemVer": self.SystemVer ?: @"",
        @"Build": self.Build ?: @"",
        @"Carrier": self.Carrier ?: @"",
        @"MCC": self.MCC ?: @"",
        @"MNC": self.MNC ?: @"",
        @"RadioAccess": self.RadioAccess ?: @"",
        @"Latitude": @(self.Latitude),
        @"Longitude": @(self.Longitude),
        @"Altitude": @(self.Altitude),
    };
}

- (NSDictionary *)toAMGFakerDictionary {
    // Plaintext AMG faker.plist key names (importable by NewDevice + readable by humans)
    NSMutableDictionary *d = [@{
        @"IDFA": self.IDFA ?: @"",
        @"IDFV": self.IDFV ?: @"",
        @"UDID": self.UDID ?: @"",
        @"SerialNumber": self.Serial ?: @"",
        @"WifiAddress": self.WiFiMAC ?: @"",
        @"BlueAddress": self.BTMAC ?: @"",
        @"SSID": self.SSID ?: @"",
        @"BSSID": self.BSSID ?: @"",
        @"DeviceToken": self.DeviceToken ?: @"",
        @"SystemVer": self.SystemVer ?: @"",
        @"BuildVersion": self.Build ?: @"",
        @"Name": self.DeviceName.length ? self.DeviceName : (self.Model ?: @""),
        @"DiskSpace": @(self.DiskCapacity),
        @"Memory": @(self.PhysicalMemory),
        @"Brightness": @(self.Brightness >= 0 ? self.Brightness : 0.5),
        @"BatteryLevel": @(self.BatteryLevel >= 0 ? self.BatteryLevel : 0.6),
        @"ICCID": self.ICCID ?: @"",
        @"SystemUptime": @(self.BootTime),
        @"Latitude": @(self.Latitude),
        @"Longitude": @(self.Longitude),
        @"IMEI": self.IMEI ?: @"",
        @"IMEI2": self.IMEI2 ?: @"",
        @"OpenUDID": self.OpenUDID ?: @"",
        @"UUID": self.UUID ?: @"",
        @"DeviceModel": self.Model ?: @"",
        @"ProductType": self.ProductType ?: @"",
        @"TimeZone": self.TimeZone ?: @"",
        @"Carrier": self.Carrier ?: @"",
        @"MCC": self.MCC ?: @"",
        @"MNC": self.MNC ?: @"",
    } mutableCopy];
    return d;
}

- (NSString *)alignConsistency {
    if ([self.name isEqualToString:@"原始机器"]) return @"";
    NSMutableArray<NSString *> *fixes = [NSMutableArray array];

    // Deterministic fills from UDID/name so reloads do not reshuffle empty fields.
    NSString *seedStr = self.UDID.length ? self.UDID : (self.name ?: @"nd");
    uint32_t seed = 2166136261u;
    const char *cs = seedStr.UTF8String ?: "nd";
    while (*cs) { seed ^= (uint8_t)(*cs++); seed *= 16777619u; }

    // --- Machine identity triad: ProductType / HardwareMachine / marketing Model ---
    if (!self.ProductType.length && NDLooksLikeProductType(self.HardwareMachine)) {
        self.ProductType = self.HardwareMachine;
        [fixes addObject:@"ProductType←HardwareMachine"];
    }
    if (!self.ProductType.length && NDLooksLikeProductType(self.Model)) {
        self.ProductType = self.Model;
        [fixes addObject:@"ProductType←Model"];
    }
    if (!self.HardwareMachine.length && self.ProductType.length) {
        self.HardwareMachine = self.ProductType;
        [fixes addObject:@"HardwareMachine←ProductType"];
    } else if (self.ProductType.length && NDLooksLikeProductType(self.HardwareMachine) == NO) {
        self.HardwareMachine = self.ProductType;
        [fixes addObject:@"HardwareMachine=ProductType"];
    }

    NSString *marketing = [NDDeviceCatalog marketingNameForProductType:self.ProductType];
    if (marketing.length && (![self.Model isEqualToString:marketing] || NDLooksLikeProductType(self.Model))) {
        self.Model = marketing;
        [fixes addObject:[NSString stringWithFormat:@"Model=%@", marketing]];
    }

    BOOL nameIsMachine = NDLooksLikeProductType(self.DeviceName)
        || (self.ProductType.length && [self.DeviceName isEqualToString:self.ProductType])
        || (self.HardwareMachine.length && [self.DeviceName isEqualToString:self.HardwareMachine])
        || (self.Model.length && [self.DeviceName isEqualToString:self.Model] && [self.Model hasPrefix:@"iPhone"]);
    // "iPhone" alone is OK as DeviceName on real units; prefer personalized like AMG.
    if (!self.DeviceName.length || nameIsMachine || [self.DeviceName isEqualToString:@"iPhone"] || [self.DeviceName isEqualToString:@"iPad"]) {
        static NSArray<NSString *> *prefixes;
        static dispatch_once_t onceToken;
        dispatch_once(&onceToken, ^{
            prefixes = @[@"Alex", @"Jordan", @"Sam", @"Taylor", @"Chris", @"Jamie", @"Casey", @"Morgan", @"Riley", @"Avery"];
        });
        NSString *who = prefixes[seed % prefixes.count];
        BOOL isPad = [self.ProductType hasPrefix:@"iPad"];
        self.DeviceName = [NSString stringWithFormat:@"%@'s %@", who, isPad ? @"iPad" : @"iPhone"];
        [fixes addObject:[NSString stringWithFormat:@"DeviceName=%@", self.DeviceName]];
    }

    // --- Capacity matches ProductType (real Gestalt values) ---
    if (self.ProductType.length) {
        uint64_t expectMem = [NDDeviceCatalog memoryBytesForProductType:self.ProductType];
        if (expectMem > 0 && self.PhysicalMemory != expectMem) {
            self.PhysicalMemory = expectMem;
            [fixes addObject:[NSString stringWithFormat:@"PhysicalMemory=%llu", (unsigned long long)expectMem]];
        }
        if (self.DiskCapacity == 0) {
            static uint64_t options[] = {
                128ULL * 1000 * 1000 * 1000,
                256ULL * 1000 * 1000 * 1000,
                256ULL * 1000 * 1000 * 1000,
                512ULL * 1000 * 1000 * 1000,
            };
            self.DiskCapacity = options[seed % 4];
            [fixes addObject:[NSString stringWithFormat:@"DiskCapacity=%llu", (unsigned long long)self.DiskCapacity]];
        }
    }

    // --- SystemVer must be iOS 18+; keep Build aligned ---
    if (!self.SystemVer.length || [NDDeviceCatalog majorSystemVersion:self.SystemVer] < 18) {
        NSArray *pool = [NDDeviceCatalog systemVersions];
        NSString *pick = pool.count ? pool[seed % pool.count] : @"18.5";
        self.SystemVer = pick;
        self.Build = [NDDeviceCatalog buildForSystemVersion:pick] ?: NDRandomBuild(pick);
        [fixes addObject:[NSString stringWithFormat:@"SystemVer=%@ (≥18)", pick]];
    } else {
        NSString *known = NDKnownBuilds()[self.SystemVer];
        if (known.length && (![self.Build isEqualToString:known] || !self.Build.length)) {
            self.Build = known;
            [fixes addObject:[NSString stringWithFormat:@"Build=%@↔%@", known, self.SystemVer]];
        } else if (!self.Build.length) {
            self.Build = NDRandomBuild(self.SystemVer);
            [fixes addObject:[NSString stringWithFormat:@"Build=%@", self.Build]];
        }
    }

    // --- Serial / IMEI look like Apple equipment ---
    if (!NDLooksLikeAppleSerial(self.Serial)) {
        self.Serial = NDSeededSerial(seed ^ 0xA5A5A5A5u);
        [fixes addObject:[NSString stringWithFormat:@"Serial=%@", self.Serial]];
    }
    if (self.IMEI.length != 15) {
        self.IMEI = NDSeededIMEI(seed);
        [fixes addObject:@"IMEI=filled"];
    }
    if (self.IMEI2.length != 15) {
        self.IMEI2 = NDSeededIMEI(seed ^ 0x11111111u);
        [fixes addObject:@"IMEI2=filled"];
    }
    if (self.ICCID.length < 18) {
        self.ICCID = [NSString stringWithFormat:@"8901%016llu", ((unsigned long long)seed << 16) | (seed ^ 0xABCDEF)];
        if (self.ICCID.length > 20) self.ICCID = [self.ICCID substringToIndex:20];
        [fixes addObject:@"ICCID=filled"];
    }

    // --- Wi‑Fi / BT: Apple OUI + same family (real phones share OUI) ---
    if (!self.WiFiMAC.length || !NDAppleOUIKnown(self.WiFiMAC)) {
        NSArray *ouis = NDAppleOUIs();
        NSString *oui = ouis[seed % ouis.count];
        self.WiFiMAC = [NSString stringWithFormat:@"%@:%02X:%02X:%02X",
                        oui, (seed >> 8) & 0xff, (seed >> 16) & 0xff, (seed >> 24) & 0xff];
        [fixes addObject:[NSString stringWithFormat:@"WiFiMAC=%@", self.WiFiMAC]];
    }
    NSString *wantBT = NDPairedBTMAC(self.WiFiMAC, seed ^ 0x5a5a5a5au);
    BOOL btOUIMatch = NO;
    if (self.BTMAC.length >= 8 && self.WiFiMAC.length >= 8) {
        btOUIMatch = [[[self.BTMAC substringToIndex:8] uppercaseString]
                      isEqualToString:[[self.WiFiMAC substringToIndex:8] uppercaseString]];
    }
    BOOL btBad = !self.BTMAC.length || !NDAppleOUIKnown(self.BTMAC) || !btOUIMatch;
    if (btBad) {
        self.BTMAC = wantBT;
        [fixes addObject:[NSString stringWithFormat:@"BTMAC=%@", self.BTMAC]];
    }

    // --- US carrier + radio ---
    if (!self.Carrier.length || !self.MCC.length || !self.MNC.length) {
        NSArray *carriers = [NDDeviceCatalog carriers];
        NSDictionary *c = carriers[(seed / 7) % carriers.count];
        if (!self.Carrier.length) self.Carrier = c[@"Carrier"] ?: @"";
        if (!self.MCC.length) self.MCC = c[@"MCC"] ?: @"";
        if (!self.MNC.length) self.MNC = c[@"MNC"] ?: @"";
        [fixes addObject:[NSString stringWithFormat:@"Carrier=%@ %@/%@", self.Carrier, self.MCC, self.MNC]];
    }
    if (!self.RadioAccess.length) {
        NSArray *rats = [NDDeviceCatalog radioAccessTypes];
        self.RadioAccess = rats[(seed / 11) % rats.count];
        [fixes addObject:[NSString stringWithFormat:@"RadioAccess=%@", self.RadioAccess]];
    }
    if (!self.SSID.length || !self.BSSID.length) {
        NSArray *ssids = [NDDeviceCatalog wifiSSIDs];
        if (!self.SSID.length) {
            self.SSID = ssids.count ? ssids[(seed / 13) % ssids.count] : @"HomeWiFi";
        }
        if (!self.BSSID.length) {
            // Router BSSID — not Apple OUI; private locally administered
            self.BSSID = [NSString stringWithFormat:@"%02x:%02x:%02x:%02x:%02x:%02x",
                          ((seed >> 16) & 0xfe) | 0x02, (seed >> 8) & 0xff, seed & 0xff,
                          (seed >> 24) & 0xff, (seed >> 4) & 0xff, (seed >> 12) & 0xff];
        }
        [fixes addObject:[NSString stringWithFormat:@"SSID=%@", self.SSID]];
    }

    // --- TimeZone must match GPS (真机一致) ---
    if (fabs(self.Latitude) > 0.01 || fabs(self.Longitude) > 0.01) {
        NSDictionary *best = nil;
        double bestD = DBL_MAX;
        for (NSDictionary *c in [NDDeviceCatalog usCityCoordinates]) {
            double dlat = [c[@"lat"] doubleValue] - self.Latitude;
            double dlon = [c[@"lon"] doubleValue] - self.Longitude;
            double d = dlat * dlat + dlon * dlon;
            if (d < bestD) { bestD = d; best = c; }
        }
        NSString *tz = best[@"timezone"] ?: @"America/New_York";
        if (![self.TimeZone isEqualToString:tz]) {
            self.TimeZone = tz;
            [fixes addObject:[NSString stringWithFormat:@"TimeZone=%@ (GPS)", tz]];
        }
    } else if (!self.TimeZone.length) {
        NSArray *cities = [NDDeviceCatalog usCityCoordinates];
        NSDictionary *coord = cities[(seed / 17) % cities.count];
        self.TimeZone = coord[@"timezone"] ?: @"America/New_York";
        self.Latitude = [coord[@"lat"] doubleValue];
        self.Longitude = [coord[@"lon"] doubleValue];
        [fixes addObject:[NSString stringWithFormat:@"TimeZone=%@", self.TimeZone]];
    }

    if (!self.OpenUDID.length) {
        self.OpenUDID = [NSString stringWithFormat:@"%08x%08x%08x%08x%08x",
                         seed, seed ^ 0x9e3779b9u, seed * 2654435761u, ~seed, seed ^ 0x85ebca6bu];
        [fixes addObject:@"OpenUDID=filled"];
    }
    if (self.BootTime <= 0) {
        NSTimeInterval now = [[NSDate date] timeIntervalSince1970];
        self.BootTime = now - (3600.0 + (seed % (10 * 24 * 3600)));
        [fixes addObject:@"BootTime=filled"];
    }
    if (!self.DeviceColor.length) {
        // Colors plausible for the generation (avoid Titanium on iPhone 14)
        NSArray *colors = @[@"Black", @"White", @"Blue", @"Purple", @"Yellow", @"Starlight", @"Midnight"];
        self.DeviceColor = colors[(seed / 19) % colors.count];
        [fixes addObject:[NSString stringWithFormat:@"DeviceColor=%@", self.DeviceColor]];
    }
    if (self.Brightness < 0) {
        self.Brightness = 0.35f + ((seed % 50) / 100.0f);
        [fixes addObject:@"Brightness=filled"];
    }
    if (self.BatteryLevel < 0) {
        self.BatteryLevel = 0.25f + ((seed % 70) / 100.0f);
        [fixes addObject:@"BatteryLevel=filled"];
    }
    if (self.Altitude < 1.0) {
        self.Altitude = 8.0 + (seed % 120);
        [fixes addObject:@"Altitude=filled"];
    }

    return fixes.count ? [fixes componentsJoinedByString:@"; "] : @"";
}

- (NSString *)applyGeolocation:(NSDictionary *)geo jitter:(BOOL)jitter {
    if (![geo isKindOfClass:[NSDictionary class]]) return @"";
    double lat = [geo[@"lat"] doubleValue];
    double lon = [geo[@"lon"] doubleValue];
    if (fabs(lat) < 0.01 && fabs(lon) < 0.01) return @"";
    if (jitter) {
        lat += ((double)arc4random_uniform(8000) / 100000.0) - 0.04;
        lon += ((double)arc4random_uniform(8000) / 100000.0) - 0.04;
    }
    self.Latitude = lat;
    self.Longitude = lon;
    NSString *tz = geo[@"timezone"];
    if ([tz isKindOfClass:[NSString class]] && tz.length) self.TimeZone = tz;
    NSString *cc = [geo[@"countryCode"] isKindOfClass:[NSString class]] ? geo[@"countryCode"] : @"";
    // Keep US carrier pool only when egress IP is US; otherwise avoid NY GPS + AT&T mismatch.
    if (cc.length && ![cc.uppercaseString isEqualToString:@"US"]) {
        NSString *isp = [geo[@"isp"] isKindOfClass:[NSString class]] ? geo[@"isp"] : @"";
        if (isp.length > 28) isp = [isp substringToIndex:28];
        if (isp.length) self.Carrier = isp;
        // Leave MCC/MNC empty so we don't claim a US PLMN abroad.
        self.MCC = @"";
        self.MNC = @"";
    }
    NSString *city = [geo[@"city"] isKindOfClass:[NSString class]] ? geo[@"city"] : @"";
    NSString *ip = [geo[@"ip"] isKindOfClass:[NSString class]] ? geo[@"ip"] : @"";
    return [NSString stringWithFormat:@"geo %@ %@ (%.4f,%.4f) tz=%@",
            ip.length ? ip : @"?", city.length ? city : cc, lat, lon, self.TimeZone ?: @"?"];
}

- (BOOL)writeToPath:(NSString *)path error:(NSError **)error {
    NSDictionary *dict = [self toDictionary];
    NSString *dir = [path stringByDeletingLastPathComponent];
    NSFileManager *fm = [NSFileManager defaultManager];
    if (![fm fileExistsAtPath:dir]) {
        if (![fm createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:error]) {
            return NO;
        }
    }
    if (![dict writeToFile:path atomically:YES]) {
        if (error) {
            *error = [NSError errorWithDomain:@"NDDeviceProfile" code:1 userInfo:@{NSLocalizedDescriptionKey: @"Failed to write profile plist"}];
        }
        return NO;
    }
    return YES;
}

- (BOOL)writeAMGFakerToDirectory:(NSString *)dir error:(NSError **)error {
    if (!dir.length) {
        if (error) *error = [NSError errorWithDomain:@"NDDeviceProfile" code:2 userInfo:@{NSLocalizedDescriptionKey: @"Empty directory"}];
        return NO;
    }
    NSFileManager *fm = [NSFileManager defaultManager];
    if (![fm createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:error]) return NO;
    NSDictionary *faker = [self toAMGFakerDictionary];
    if (![faker writeToFile:[dir stringByAppendingPathComponent:@"faker.plist"] atomically:YES]) {
        if (error) *error = [NSError errorWithDomain:@"NDDeviceProfile" code:3 userInfo:@{NSLocalizedDescriptionKey: @"Failed to write faker.plist"}];
        return NO;
    }
    NSDictionary *desc = @{
        @"title": self.name ?: @"export",
        @"appName": @[],
    };
    [desc writeToFile:[dir stringByAppendingPathComponent:@"description.plist"] atomically:YES];
    return YES;
}

- (id)copyWithZone:(NSZone *)zone {
    return [NDDeviceProfile profileFromDictionary:[self toDictionary]];
}

@end
