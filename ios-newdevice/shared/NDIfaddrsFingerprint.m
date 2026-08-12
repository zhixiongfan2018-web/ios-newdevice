#import "NDIfaddrsFingerprint.h"
#import "NDPaths.h"

@implementation NDIfaddrsFingerprint

+ (NSDictionary *)loadForRecord:(NSString *)recordName {
    if (!recordName.length || [recordName isEqualToString:@"原始机器"]) return nil;
    NSDictionary *dict = [NSDictionary dictionaryWithContentsOfFile:[NDPaths ifaddrsPathForRecord:recordName]];
    return [dict isKindOfClass:[NSDictionary class]] ? dict : nil;
}

+ (NSDictionary *)NDIfaceWithIPv4:(NSString *)ipv4
                              mask:(NSString *)mask
                              ipv6:(NSString *)ipv6
                               mac:(NSString *)mac
                               dst:(NSString *)dst {
    NSMutableDictionary *d = [@{
        @"ipv4": ipv4 ?: @"0.0.0.0",
        @"submask": mask ?: @"255.255.255.0",
        @"ipv6": ipv6 ?: @"fe80::1",
        @"submask_v6": @"ffff:ffff:ffff:ffff::",
        @"dst": dst ?: @"169.254.0.1",
        @"dst_v6": @"::1",
    } mutableCopy];
    if (mac.length) d[@"mac"] = mac;
    return d;
}

+ (NSString *)NDRandomLANHost {
    return [NSString stringWithFormat:@"192.168.%u.%u",
            (unsigned)(1 + arc4random_uniform(220)),
            (unsigned)(2 + arc4random_uniform(250))];
}

+ (NSString *)NDRandomLinkLocal {
    return [NSString stringWithFormat:@"169.254.%u.%u",
            (unsigned)(1 + arc4random_uniform(254)),
            (unsigned)(1 + arc4random_uniform(254))];
}

+ (NSString *)NDRandomFe80 {
    return [NSString stringWithFormat:@"fe80::%x:%x:%x:%x",
            arc4random_uniform(0xffff), arc4random_uniform(0xffff),
            arc4random_uniform(0xffff), arc4random_uniform(0xffff)];
}

+ (NSDictionary *)synthesizeFromProfileWiFiMAC:(NSString *)mac {
    // AMG-like multi-interface fingerprint (en*/pdp/awdl/utun/anpi + dns)
    NSString *wifiMAC = mac.length ? mac : @"02:00:00:00:00:00";
    NSString *en0ip = [self NDRandomLANHost];
    NSString *en0dst = [self NDRandomLinkLocal];
    NSMutableDictionary *map = [NSMutableDictionary dictionary];
    map[@"en0"] = [self NDIfaceWithIPv4:en0ip mask:@"255.255.255.0" ipv6:[self NDRandomFe80] mac:wifiMAC dst:en0dst];
    map[@"en1"] = [self NDIfaceWithIPv4:[self NDRandomLANHost] mask:@"255.255.0.0" ipv6:[self NDRandomFe80] mac:@"02:00:00:00:00:00" dst:en0dst];
    map[@"en2"] = [self NDIfaceWithIPv4:[self NDRandomLinkLocal] mask:@"255.255.0.0" ipv6:[self NDRandomFe80] mac:@"02:00:00:00:00:00" dst:[self NDRandomLinkLocal]];
    map[@"en3"] = [self NDIfaceWithIPv4:[self NDRandomLANHost] mask:@"255.255.0.0" ipv6:[self NDRandomFe80] mac:@"02:00:00:00:00:00" dst:[self NDRandomLinkLocal]];
    map[@"awdl0"] = [self NDIfaceWithIPv4:[self NDRandomLANHost] mask:@"255.255.0.0" ipv6:[self NDRandomFe80] mac:@"02:00:00:00:00:00" dst:[self NDRandomLinkLocal]];
    map[@"llw0"] = map[@"awdl0"];
    map[@"anpi0"] = [self NDIfaceWithIPv4:[self NDRandomLANHost] mask:@"255.255.0.0" ipv6:[self NDRandomFe80] mac:wifiMAC dst:[self NDRandomLinkLocal]];
    map[@"pdp_ip0"] = [self NDIfaceWithIPv4:[NSString stringWithFormat:@"10.%u.%u.%u",
                                            (unsigned)arc4random_uniform(200),
                                            (unsigned)arc4random_uniform(255),
                                            (unsigned)(2 + arc4random_uniform(250))]
                                       mask:@"255.255.255.255"
                                       ipv6:[self NDRandomFe80]
                                        mac:@"02:00:00:00:00:00"
                                        dst:[self NDRandomLinkLocal]];
    map[@"pdp_ip1"] = [self NDIfaceWithIPv4:[self NDRandomLinkLocal] mask:@"255.255.255.255" ipv6:[self NDRandomFe80] mac:@"02:00:00:00:00:00" dst:[self NDRandomLinkLocal]];
    for (int i = 0; i < 5; i++) {
        NSString *name = [NSString stringWithFormat:@"utun%d", i];
        map[name] = [self NDIfaceWithIPv4:[self NDRandomLANHost] mask:@"255.255.0.0" ipv6:[self NDRandomFe80] mac:@"02:00:00:00:00:00" dst:[self NDRandomLinkLocal]];
    }
    // US-leaning public resolvers + occasional ISP-like
    NSArray *dnsPools = @[
        @[@"8.8.8.8", @"8.8.4.4"],
        @[@"1.1.1.1", @"1.0.0.1"],
        @[@"9.9.9.9", @"149.112.112.112"],
        @[@"208.67.222.222", @"208.67.220.220"],
    ];
    map[@"dns"] = dnsPools[arc4random_uniform((uint32_t)dnsPools.count)];
    return map;
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

+ (BOOL)applyIPv4:(NSString *)ip toDstaddr:(struct sockaddr *)dst {
    if (!ip.length || !dst || dst->sa_family != AF_INET) return NO;
    struct sockaddr_in *sin = (struct sockaddr_in *)dst;
    struct in_addr parsed;
    if (inet_pton(AF_INET, ip.UTF8String, &parsed) != 1) return NO;
    sin->sin_addr = parsed;
    return YES;
}

@end
