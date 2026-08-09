#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface NDDeviceProfile : NSObject <NSCopying>

@property (nonatomic, copy) NSString *name;
@property (nonatomic, assign) BOOL enabled;
@property (nonatomic, copy) NSDate *createdAt;

@property (nonatomic, copy) NSString *IDFA;
@property (nonatomic, copy) NSString *IDFV;
@property (nonatomic, copy) NSString *UUID;
@property (nonatomic, copy) NSString *Serial;
@property (nonatomic, copy) NSString *UDID;
@property (nonatomic, copy) NSString *WiFiMAC;
@property (nonatomic, copy) NSString *BTMAC;
@property (nonatomic, copy) NSString *DeviceToken;

@property (nonatomic, copy) NSString *Model;
@property (nonatomic, copy) NSString *ProductType;
@property (nonatomic, copy) NSString *HardwareMachine;
@property (nonatomic, copy) NSString *SystemVer;
@property (nonatomic, copy) NSString *Build;

@property (nonatomic, copy) NSString *Carrier;
@property (nonatomic, copy) NSString *MCC;
@property (nonatomic, copy) NSString *MNC;
@property (nonatomic, copy) NSString *RadioAccess;

@property (nonatomic, assign) double Latitude;
@property (nonatomic, assign) double Longitude;
@property (nonatomic, assign) double Altitude;

+ (instancetype)originalProfile;
+ (instancetype)randomProfileWithName:(NSString *)name
                          preferredModel:(nullable NSString *)model
                          preferredSystem:(nullable NSString *)systemVer;
+ (nullable instancetype)profileFromDictionary:(NSDictionary *)dict;
+ (nullable instancetype)profileAtPath:(NSString *)path;

- (NSDictionary *)toDictionary;
- (BOOL)writeToPath:(NSString *)path error:(NSError * _Nullable * _Nullable)error;

@end

NS_ASSUME_NONNULL_END
