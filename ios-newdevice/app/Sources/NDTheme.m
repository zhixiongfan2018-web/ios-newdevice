#import "NDTheme.h"

@implementation NDTheme

+ (UIColor *)accent {
    return [UIColor colorWithRed:0.05 green:0.52 blue:0.48 alpha:1.0];
}

+ (UIColor *)accentMuted {
    return [[self accent] colorWithAlphaComponent:0.14];
}

+ (UIColor *)danger { return [UIColor systemRedColor]; }
+ (UIColor *)success { return [UIColor systemGreenColor]; }
+ (UIColor *)warning { return [UIColor systemOrangeColor]; }

+ (UIColor *)canvas {
    if (@available(iOS 13.0, *)) return [UIColor systemGroupedBackgroundColor];
    return [UIColor colorWithWhite:0.95 alpha:1];
}

+ (UIColor *)card {
    if (@available(iOS 13.0, *)) return [UIColor secondarySystemGroupedBackgroundColor];
    return [UIColor whiteColor];
}

+ (UIColor *)hairline {
    if (@available(iOS 13.0, *)) return [UIColor separatorColor];
    return [UIColor colorWithWhite:0.85 alpha:1];
}

+ (UIFont *)titleFont {
    if (@available(iOS 13.0, *)) {
        return [UIFont systemFontOfSize:28 weight:UIFontWeightBold];
    }
    return [UIFont boldSystemFontOfSize:28];
}

+ (UIFont *)headlineFont {
    return [UIFont systemFontOfSize:17 weight:UIFontWeightSemibold];
}

+ (UIFont *)bodyFont {
    return [UIFont systemFontOfSize:15 weight:UIFontWeightRegular];
}

+ (UIFont *)captionFont {
    return [UIFont systemFontOfSize:12 weight:UIFontWeightMedium];
}

+ (UIFont *)monoFont:(CGFloat)size {
    if (@available(iOS 13.0, *)) {
        return [UIFont monospacedSystemFontOfSize:size weight:UIFontWeightRegular];
    }
    return [UIFont fontWithName:@"Menlo" size:size] ?: [UIFont systemFontOfSize:size];
}

+ (void)applyGlobalAppearance {
    UIColor *accent = [self accent];
    if (@available(iOS 15.0, *)) {
        UINavigationBarAppearance *nav = [UINavigationBarAppearance new];
        [nav configureWithDefaultBackground];
        nav.titleTextAttributes = @{NSFontAttributeName: [UIFont systemFontOfSize:17 weight:UIFontWeightSemibold]};
        nav.largeTitleTextAttributes = @{NSFontAttributeName: [UIFont systemFontOfSize:32 weight:UIFontWeightBold]};
        [UINavigationBar appearance].standardAppearance = nav;
        [UINavigationBar appearance].scrollEdgeAppearance = nav;
        [UINavigationBar appearance].compactAppearance = nav;
        [UINavigationBar appearance].tintColor = accent;

        UITabBarAppearance *tab = [UITabBarAppearance new];
        [tab configureWithDefaultBackground];
        [UITabBar appearance].standardAppearance = tab;
        [UITabBar appearance].scrollEdgeAppearance = tab;
        [UITabBar appearance].tintColor = accent;
    } else {
        [UINavigationBar appearance].tintColor = accent;
        [UITabBar appearance].tintColor = accent;
    }
    [UISwitch appearance].onTintColor = accent;
    [UITableView appearance].backgroundColor = [self canvas];
}

+ (void)styleNavigationBar:(UINavigationBar *)bar {
    bar.prefersLargeTitles = YES;
    bar.tintColor = [self accent];
}

+ (void)styleCard:(UIView *)view {
    view.backgroundColor = [self card];
    view.layer.cornerRadius = 18;
    view.layer.cornerCurve = kCACornerCurveContinuous;
    view.layer.masksToBounds = YES;
}

+ (UIButton *)primaryButton:(NSString *)title target:(id)target action:(SEL)action {
    UIButton *b = [UIButton buttonWithType:UIButtonTypeSystem];
    [b setTitle:title forState:UIControlStateNormal];
    [b setTitleColor:UIColor.whiteColor forState:UIControlStateNormal];
    b.backgroundColor = [self accent];
    b.titleLabel.font = [UIFont systemFontOfSize:17 weight:UIFontWeightSemibold];
    b.layer.cornerRadius = 14;
    b.layer.cornerCurve = kCACornerCurveContinuous;
    [b.heightAnchor constraintEqualToConstant:52].active = YES;
    [b addTarget:target action:action forControlEvents:UIControlEventTouchUpInside];
    return b;
}

+ (UIButton *)secondaryButton:(NSString *)title target:(id)target action:(SEL)action {
    UIButton *b = [UIButton buttonWithType:UIButtonTypeSystem];
    [b setTitle:title forState:UIControlStateNormal];
    [b setTitleColor:[self accent] forState:UIControlStateNormal];
    b.backgroundColor = [self accentMuted];
    b.titleLabel.font = [UIFont systemFontOfSize:15 weight:UIFontWeightSemibold];
    b.layer.cornerRadius = 12;
    b.layer.cornerCurve = kCACornerCurveContinuous;
    [b.heightAnchor constraintEqualToConstant:44].active = YES;
    [b addTarget:target action:action forControlEvents:UIControlEventTouchUpInside];
    return b;
}

+ (UILabel *)captionLabel:(NSString *)text {
    UILabel *l = [UILabel new];
    l.text = text;
    l.font = [self captionFont];
    l.textColor = [UIColor secondaryLabelColor];
    return l;
}

+ (UIView *)statusChip:(NSString *)text color:(UIColor *)color {
    UIView *chip = [UIView new];
    chip.backgroundColor = [color colorWithAlphaComponent:0.12];
    chip.layer.cornerRadius = 12;
    chip.layer.cornerCurve = kCACornerCurveContinuous;

    UIView *dot = [UIView new];
    dot.backgroundColor = color;
    dot.layer.cornerRadius = 3.5;
    dot.translatesAutoresizingMaskIntoConstraints = NO;

    UILabel *label = [UILabel new];
    label.text = text;
    label.font = [UIFont systemFontOfSize:12 weight:UIFontWeightSemibold];
    label.textColor = color;
    label.translatesAutoresizingMaskIntoConstraints = NO;

    [chip addSubview:dot];
    [chip addSubview:label];
    [NSLayoutConstraint activateConstraints:@[
        [dot.widthAnchor constraintEqualToConstant:7],
        [dot.heightAnchor constraintEqualToConstant:7],
        [dot.leadingAnchor constraintEqualToAnchor:chip.leadingAnchor constant:10],
        [dot.centerYAnchor constraintEqualToAnchor:chip.centerYAnchor],
        [label.leadingAnchor constraintEqualToAnchor:dot.trailingAnchor constant:6],
        [label.trailingAnchor constraintEqualToAnchor:chip.trailingAnchor constant:-10],
        [label.topAnchor constraintEqualToAnchor:chip.topAnchor constant:6],
        [label.bottomAnchor constraintEqualToAnchor:chip.bottomAnchor constant:-6],
    ]];
    return chip;
}

@end
