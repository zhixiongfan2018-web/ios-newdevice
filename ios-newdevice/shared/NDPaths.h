#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

FOUNDATION_EXPORT NSString * const NDBundleID;
FOUNDATION_EXPORT NSString * const NDNotifyReload;
FOUNDATION_EXPORT NSString * const NDHTTPHost;
FOUNDATION_EXPORT NSInteger const NDHTTPPort;

@interface NDPaths : NSObject
+ (NSString *)jbPrefix;
/// Prefixed path when /var/jb exists (rootless), else absolutePath unchanged.
+ (NSString *)jbPath:(NSString *)absolutePath;
+ (NSString *)preferencesDir;
+ (NSString *)configPlistPath;
+ (NSString *)recordsRoot;
+ (NSString *)recordDir:(NSString *)name;
+ (NSString *)profilePathForRecord:(NSString *)name;
+ (NSString *)appsBackupDirForRecord:(NSString *)name bundleId:(NSString *)bundleId;
+ (NSString *)ifaddrsPathForRecord:(NSString *)name;
+ (NSString *)pasteboardDirForRecord:(NSString *)name;
+ (NSString *)resultFilePath;
+ (NSString *)currentRecordPointerPath;
+ (NSString *)lastSessionRecordPath;
/// World-readable snapshot for sandboxed target apps (tweak injection).
+ (NSString *)runtimeStatePath;
+ (NSString *)runtimeStateDir;
/// Aisi/爱思「文件管理」可见目录（= /var/mobile/Media/NewDevice）
+ (NSString *)mediaHomeDir;
+ (NSString *)mediaImportDir;
+ (NSString *)mediaExportDir;

+ (void)ensureDirectories;
+ (void)makePathWorldReadable:(NSString *)path;
@end

NS_ASSUME_NONNULL_END
