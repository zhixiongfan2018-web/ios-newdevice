#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface NDDeviceProfile : NSObject <NSCopying>

@property (nonatomic, copy) NSString *name;
/// User-facing note / alias (does not change record folder name).
@property (nonatomic, copy) NSString *remark;
@property (nonatomic, assign) BOOL enabled;
/// When NO, tweak will not spoof IDFA/UDID/etc (used when AMG faker is ciphertext).
@property (nonatomic, assign) BOOL spoofDeviceIdentity;
@property (nonatomic, copy) NSDate *createdAt;

@property (nonatomic, copy) NSString *IDFA;
@property (nonatomic, copy) NSString *IDFV;
@property (nonatomic, copy) NSString *UUID;
@property (nonatomic, copy) NSString *Serial;
@property (nonatomic, copy) NSString *UDID;
@property (nonatomic, copy) NSString *WiFiMAC;
@property (nonatomic, copy) NSString *BTMAC;
@property (nonatomic, copy) NSString *DeviceToken;
@property (nonatomic, copy) NSString *IMEI;
@property (nonatomic, copy) NSString *IMEI2;
@property (nonatomic, copy) NSString *SSID;
@property (nonatomic, copy) NSString *BSSID;
@property (nonatomic, copy) NSString *OpenUDID;
@property (nonatomic, copy) NSString *TimeZone; // e.g. America/New_York
@property (nonatomic, assign) NSTimeInterval BootTime; // unix seconds
@property (nonatomic, copy) NSString *DeviceColor; // e.g. Black / White / Blue
@property (nonatomic, assign) uint64_t DiskCapacity; // bytes
@property (nonatomic, assign) uint64_t PhysicalMemory; // bytes; 0 = derive from ProductType
@property (nonatomic, assign) float Brightness; // 0..1; <0 = do not spoof
@property (nonatomic, assign) float BatteryLevel; // 0..1; <0 = do not spoof
@property (nonatomic, copy) NSString *ICCID;
@property (nonatomic, assign) BOOL AdvertisingTrackingEnabled;

@property (nonatomic, copy) NSString *Model;
@property (nonatomic, copy) NSString *DeviceName; // UIDevice.name / UserAssignedDeviceName (AMG Name)
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
/// Normalize AMG / AWZ / CTW-style keys into NewDevice profile keys.
+ (NSDictionary *)normalizedImportDictionary:(NSDictionary *)dict;
/// YES when values look like AMG on-disk AES ciphertext (Base64 blobs), not plaintext identity.
+ (BOOL)dictionaryLooksLikeEncryptedAMGFaker:(NSDictionary *)dict;
/// YES when dict has at least one usable plaintext identity field after normalization.
+ (BOOL)dictionaryHasImportableIdentity:(NSDictionary *)dict;

- (NSDictionary *)toDictionary;
/// Plaintext AMG-compatible faker.plist dictionary (WifiAddress/BlueAddress/…).
- (NSDictionary *)toAMGFakerDictionary;
- (BOOL)writeToPath:(NSString *)path error:(NSError * _Nullable * _Nullable)error;
- (BOOL)writeAMGFakerToDirectory:(NSString *)dir error:(NSError * _Nullable * _Nullable)error;

/// Fill/normalize inconsistent fields (Model vs ProductType, RAM/disk, Build↔SystemVer, empty carrier/Wi‑Fi…).
/// Returns a short human-readable fix report (empty if nothing changed).
- (NSString *)alignConsistency;

/// Apply public-IP geolocation (lat/lon/timezone). Optional small urban jitter.
- (NSString *)applyGeolocation:(NSDictionary *)geo jitter:(BOOL)jitter;

@end

NS_ASSUME_NONNULL_END
