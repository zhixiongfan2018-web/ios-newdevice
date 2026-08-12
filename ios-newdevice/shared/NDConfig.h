#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface NDConfig : NSObject

@property (nonatomic, assign) BOOL fakeDeviceModel;
@property (nonatomic, assign) BOOL fakeSystemVer;
@property (nonatomic, assign) BOOL fakeCarrier;
@property (nonatomic, assign) BOOL spoofLocation;
@property (nonatomic, assign) BOOL randomLocation;
@property (nonatomic, assign) BOOL smartLocationOffset;
@property (nonatomic, assign) BOOL smartAirplane;
@property (nonatomic, assign) BOOL jailbreakHideBasic;
@property (nonatomic, assign) BOOL jailbreakHideDeep;
@property (nonatomic, assign) BOOL holographicBackup;
@property (nonatomic, assign) BOOL allowIPadSpoof; // AMG-style: include iPad in random pool
@property (nonatomic, assign) BOOL clearPasteboardOnSwitch;
@property (nonatomic, assign) BOOL importKeychainWithData; // AMG: 同时导入 Keychain
@property (nonatomic, assign) BOOL slimExportStripMedia;   // AMG: 瘦身（清除图片、视频）
@property (nonatomic, copy) NSArray<NSString *> *targetApps;
@property (nonatomic, copy) NSArray<NSString *> *preferredModels;
@property (nonatomic, copy) NSArray<NSString *> *preferredSystems;

+ (instancetype)shared;
- (void)reload;
- (BOOL)save;
- (BOOL)isTargetApp:(NSString *)bundleId;

@end

NS_ASSUME_NONNULL_END
