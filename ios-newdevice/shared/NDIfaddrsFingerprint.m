#import "NDIfaddrsFingerprint.h"
#import "NDPaths.h"

@implementation NDIfaddrsFingerprint

+ (NSDictionary *)loadForRecord:(NSString *)recordName {
    if (!recordName.length || [recordName isEqualToString:@"原始机器"]) return nil;
    NSDictionary *dict = [NSDictionary dictionaryWithContentsOfFile:[NDPaths ifaddrsPathForRecord:recordName]];
    return [dict isKindOfClass:[NSDictionary class]] ? dict : nil;
}

+ (NSDictionary *)synthesizeFromProfileWiFiMAC:(NSString *)mac {
    // Minimal AMG-compatible en0 fingerprint so imported/random records still differ from host LAN.
    uint32_t host = 2 + (arc4random_uniform(250));
    NSString *ipv4 = [NSString stringWithFormat:@"192.168.%u.%u", (unsigned)(1 + arc4random_uniform(200)), (unsigned)host];
    NSMutableDictionary *en0 = [@{
        @"ipv4": ipv4,
        @"submask": @"255.255.255.0",
        @"ipv6": @"fe80::1",
        @"submask_v6": @"ffff:ffff:ffff:ffff::",
        @"dst": @"169.254.0.1",
        @"dst_v6": @"::1",
    } mutableCopy];
    if (mac.length) en0[@"mac"] = mac;
    return @{
        @"en0": en0,
        @"dns": @[@"8.8.8.8", @"1.1.1.1"],
    };
}

+ (BOOL)applyIPv4:(NSString *)ip mask:(NSString *)mask toSockaddr:(struct sockaddr *)addr netmask:(struct sockaddr *)netmask {
    if (!ip.length || !addr || addr->sa_family != AF_INET) return NO;
    struct sockaddr_in *sin = (struct sockaddr_in *)addr;
    struct in_addr parsed;
    if (inet_pton(AF_INET, ip.UTF8String, &parsed) != 1) return NO;
    sin->sin_addr = parsed;
    if (netmask && netmask->sa_family == AF_INET && mask.length) {
        struct sockaddr_in *n = (struct sockaddr_in *)netmask;
        struct in_addr m;
        if (inet_pton(AF_INET, mask.UTF8String, &m) == 1) {
            n->sin_addr = m;
        }
    }
    return YES;
}

+ (BOOL)applyIPv6:(NSString *)ip toSockaddr:(struct sockaddr *)addr {
    if (!ip.length || !addr || addr->sa_family != AF_INET6) return NO;
    struct sockaddr_in6 *sin6 = (struct sockaddr_in6 *)addr;
    struct in6_addr parsed;
    if (inet_pton(AF_INET6, ip.UTF8String, &parsed) != 1) return NO;
    sin6->sin6_addr = parsed;
    return YES;
}

@end
