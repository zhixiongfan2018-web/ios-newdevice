#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

@interface NDTheme : NSObject

+ (UIColor *)accent;
+ (UIColor *)accentStrong;
+ (UIColor *)accentMuted;
+ (UIColor *)ink;
+ (UIColor *)muted;
+ (UIColor *)danger;
+ (UIColor *)success;
+ (UIColor *)warning;
+ (UIColor *)canvas;
+ (UIColor *)canvasSecondary;
+ (UIColor *)card;
+ (UIColor *)hairline;

+ (UIFont *)brandFont;
+ (UIFont *)titleFont;
+ (UIFont *)headlineFont;
+ (UIFont *)bodyFont;
+ (UIFont *)captionFont;
+ (UIFont *)monoFont:(CGFloat)size;

+ (void)applyGlobalAppearance;
+ (void)styleNavigationBar:(UINavigationBar *)bar;
+ (void)styleCard:(UIView *)view;
+ (void)stylePanel:(UIView *)view;
+ (UIView *)canvasBackdropIn:(UIView *)host;
+ (UIButton *)primaryButton:(NSString *)title target:(id)target action:(SEL)action;
+ (UIButton *)secondaryButton:(NSString *)title target:(id)target action:(SEL)action;
+ (UILabel *)captionLabel:(NSString *)text;
+ (UILabel *)sectionTitle:(NSString *)text;
+ (UIView *)statusChip:(NSString *)text color:(UIColor *)color;
+ (UIView *)metricPill:(NSString *)title value:(NSString *)value tone:(UIColor *)tone;

@end

NS_ASSUME_NONNULL_END
