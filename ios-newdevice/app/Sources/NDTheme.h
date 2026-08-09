#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

@interface NDTheme : NSObject

+ (UIColor *)accent;
+ (UIColor *)accentMuted;
+ (UIColor *)danger;
+ (UIColor *)success;
+ (UIColor *)warning;
+ (UIColor *)canvas;
+ (UIColor *)card;
+ (UIColor *)hairline;

+ (UIFont *)titleFont;
+ (UIFont *)headlineFont;
+ (UIFont *)bodyFont;
+ (UIFont *)captionFont;
+ (UIFont *)monoFont:(CGFloat)size;

+ (void)applyGlobalAppearance;
+ (void)styleNavigationBar:(UINavigationBar *)bar;
+ (void)styleCard:(UIView *)view;
+ (UIButton *)primaryButton:(NSString *)title target:(id)target action:(SEL)action;
+ (UIButton *)secondaryButton:(NSString *)title target:(id)target action:(SEL)action;
+ (UILabel *)captionLabel:(NSString *)text;
+ (UIView *)statusChip:(NSString *)text color:(UIColor *)color;

@end

NS_ASSUME_NONNULL_END
