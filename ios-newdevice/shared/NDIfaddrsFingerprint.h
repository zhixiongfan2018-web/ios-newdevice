#import <Foundation/Foundation.h>
#import <arpa/inet.h>
#import <netinet/in.h>
#import <netinet6/in6.h>
#import <string.h>
#import <stdlib.h>

NS_ASSUME_NONNULL_BEGIN

/// Helpers to apply AMG-style ifaddrs.plist fingerprints onto getifaddrs results.
@interface NDIfaddrsFingerprint : NSObject
+ (nullable NSDictionary *)loadForRecord:(NSString *)recordName;
+ (nullable NSDictionary *)synthesizeFromProfileWiFiMAC:(NSString *)mac;
+ (BOOL)applyIPv4:(NSString *)ip mask:(NSString *)mask toSockaddr:(struct sockaddr *_Nullable)addr netmask:(struct sockaddr *_Nullable)netmask;
+ (BOOL)applyIPv6:(NSString *)ip toSockaddr:(struct sockaddr *_Nullable)addr;
@end

NS_ASSUME_NONNULL_END
