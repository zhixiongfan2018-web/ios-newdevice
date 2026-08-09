#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

FOUNDATION_EXPORT NSString * const NDBundleID;
FOUNDATION_EXPORT NSString * const NDNotifyReload;
FOUNDATION_EXPORT NSString * const NDHTTPHost;
FOUNDATION_EXPORT NSInteger const NDHTTPPort;

@interface NDPaths : NSObject
+ (NSString *)jbPrefix;
+ (NSString *)preferencesDir;
+ (NSString *)configPlistPath;
+ (NSString *)recordsRoot;
+ (NSString *)recordDir:(NSString *)name;
+ (NSString *)profilePathForRecord:(NSString *)name;
+ (NSString *)appsBackupDirForRecord:(NSString *)name bundleId:(NSString *)bundleId;
+ (NSString *)resultFilePath;
+ (NSString *)currentRecordPointerPath;
+ (void)ensureDirectories;
@end

NS_ASSUME_NONNULL_END
