#import "NDTheme.h"
#import <QuartzCore/QuartzCore.h>

@interface NDBackdropLayoutView : UIView
@property (nonatomic, weak) CAGradientLayer *grad;
@property (nonatomic, weak) CAGradientLayer *wash;
@property (nonatomic, weak) CAShapeLayer *grid;
@end

@implementation NDBackdropLayoutView
- (void)layoutSubviews {
    [super layoutSubviews];
    CGRect b = self.bounds;
    self.grad.frame = b;
    CGFloat s = MAX(b.size.width, b.size.height) * 0.85;
    self.wash.frame = CGRectMake(b.size.width - s * 0.55, -s * 0.25, s, s);

    UIBezierPath *path = [UIBezierPath bezierPath];
    CGFloat step = 28.0;
    for (CGFloat x = 0; x <= b.size.width; x += step) {
        [path moveToPoint:CGPointMake(x, 0)];
        [path addLineToPoint:CGPointMake(x, b.size.height)];
    }
    for (CGFloat y = 0; y <= b.size.height; y += step) {
        [path moveToPoint:CGPointMake(0, y)];
        [path addLineToPoint:CGPointMake(b.size.width, y)];
    }
    self.grid.path = path.CGPath;
    self.grid.frame = b;
}
@end

@implementation NDTheme

+ (UIColor *)accent {
    return [UIColor colorWithRed:0.04 green:0.55 blue:0.72 alpha:1.0];
}

+ (UIColor *)accentStrong {
    return [UIColor colorWithRed:0.02 green:0.38 blue:0.52 alpha:1.0];
}

+ (UIColor *)accentMuted {
    return [[self accent] colorWithAlphaComponent:0.10];
}

+ (UIColor *)ink {
    return [UIColor colorWithRed:0.07 green:0.10 blue:0.16 alpha:1.0];
}

+ (UIColor *)muted {
    return [UIColor colorWithRed:0.39 green:0.45 blue:0.53 alpha:1.0];
}

+ (UIColor *)danger {
    return [UIColor colorWithRed:0.86 green:0.15 blue:0.30 alpha:1.0];
}

+ (UIColor *)success {
    return [UIColor colorWithRed:0.05 green:0.62 blue:0.45 alpha:1.0];
}

+ (UIColor *)warning {
    return [UIColor colorWithRed:0.85 green:0.47 blue:0.05 alpha:1.0];
}

+ (UIColor *)canvas {
    return [UIColor colorWithRed:0.96 green:0.97 blue:0.99 alpha:1.0];
}

+ (UIColor *)canvasSecondary {
    return [UIColor colorWithRed:0.93 green:0.96 blue:0.99 alpha:1.0];
}

+ (UIColor *)card {
    return [UIColor whiteColor];
}

+ (UIColor *)hairline {
    return [UIColor colorWithRed:0.86 green:0.90 blue:0.94 alpha:1.0];
}

+ (UIFont *)ndFont:(CGFloat)size weight:(UIFontWeight)weight design:(UIFontDescriptorSystemDesign)design {
    if (@available(iOS 13.0, *)) {
        UIFontDescriptor *base = [UIFont systemFontOfSize:size weight:weight].fontDescriptor;
        UIFontDescriptor *desc = [base fontDescriptorWithDesign:design] ?: base;
        return [UIFont fontWithDescriptor:desc size:size];
    }
    return [UIFont systemFontOfSize:size weight:weight];
}

+ (UIFont *)brandFont {
    return [self ndFont:34 weight:UIFontWeightBold design:UIFontDescriptorSystemDesignRounded];
}

+ (UIFont *)titleFont {
    return [self ndFont:28 weight:UIFontWeightBold design:UIFontDescriptorSystemDesignRounded];
}

+ (UIFont *)headlineFont {
    return [self ndFont:16 weight:UIFontWeightSemibold design:UIFontDescriptorSystemDesignDefault];
}

+ (UIFont *)bodyFont {
    return [self ndFont:15 weight:UIFontWeightRegular design:UIFontDescriptorSystemDesignDefault];
}

+ (UIFont *)captionFont {
    return [self ndFont:12 weight:UIFontWeightMedium design:UIFontDescriptorSystemDesignDefault];
}

+ (UIFont *)monoFont:(CGFloat)size {
    if (@available(iOS 13.0, *)) {
        return [UIFont monospacedSystemFontOfSize:size weight:UIFontWeightMedium];
    }
    return [UIFont fontWithName:@"Menlo-Bold" size:size] ?: [UIFont systemFontOfSize:size];
}

+ (void)applyGlobalAppearance {
    UIColor *accent = [self accent];
    UIColor *ink = [self ink];
    if (@available(iOS 15.0, *)) {
        UINavigationBarAppearance *nav = [UINavigationBarAppearance new];
        [nav configureWithOpaqueBackground];
        nav.backgroundColor = [self canvas];
        nav.shadowColor = [UIColor clearColor];
        nav.titleTextAttributes = @{
            NSFontAttributeName: [self ndFont:17 weight:UIFontWeightSemibold design:UIFontDescriptorSystemDesignRounded],
            NSForegroundColorAttributeName: ink
        };
        nav.largeTitleTextAttributes = @{
            NSFontAttributeName: [self ndFont:30 weight:UIFontWeightBold design:UIFontDescriptorSystemDesignRounded],
            NSForegroundColorAttributeName: ink
        };
        [UINavigationBar appearance].standardAppearance = nav;
        [UINavigationBar appearance].scrollEdgeAppearance = nav;
        [UINavigationBar appearance].compactAppearance = nav;
        [UINavigationBar appearance].tintColor = accent;

        UITabBarAppearance *tab = [UITabBarAppearance new];
        [tab configureWithOpaqueBackground];
        tab.backgroundColor = [UIColor whiteColor];
        tab.shadowColor = [self hairline];
        [UITabBar appearance].standardAppearance = tab;
        [UITabBar appearance].scrollEdgeAppearance = tab;
        [UITabBar appearance].tintColor = accent;
        [UITabBar appearance].unselectedItemTintColor = [self muted];
    } else {
        [UINavigationBar appearance].tintColor = accent;
        [UITabBar appearance].tintColor = accent;
        [UINavigationBar appearance].barTintColor = [self canvas];
        [UITabBar appearance].barTintColor = [UIColor whiteColor];
    }
    [UISwitch appearance].onTintColor = accent;
    [UITableView appearance].backgroundColor = [self canvas];
    [UITableView appearance].separatorColor = [self hairline];
}

+ (void)styleNavigationBar:(UINavigationBar *)bar {
    bar.prefersLargeTitles = YES;
    bar.tintColor = [self accent];
}

+ (void)styleCard:(UIView *)view {
    [self stylePanel:view];
}

+ (void)stylePanel:(UIView *)view {
    view.backgroundColor = [self card];
    view.layer.cornerRadius = 16;
    view.layer.cornerCurve = kCACornerCurveContinuous;
    view.layer.borderWidth = 1.0 / UIScreen.mainScreen.scale;
    view.layer.borderColor = [self hairline].CGColor;
    view.layer.shadowColor = [UIColor colorWithRed:0.10 green:0.20 blue:0.35 alpha:1].CGColor;
    view.layer.shadowOpacity = 0.06;
    view.layer.shadowRadius = 14;
    view.layer.shadowOffset = CGSizeMake(0, 6);
    view.layer.masksToBounds = NO;
}

+ (UIView *)canvasBackdropIn:(UIView *)host {
    UIView *wrap = [UIView new];
    wrap.userInteractionEnabled = NO;
    wrap.translatesAutoresizingMaskIntoConstraints = NO;
    [host insertSubview:wrap atIndex:0];
    [NSLayoutConstraint activateConstraints:@[
        [wrap.topAnchor constraintEqualToAnchor:host.topAnchor],
        [wrap.leadingAnchor constraintEqualToAnchor:host.leadingAnchor],
        [wrap.trailingAnchor constraintEqualToAnchor:host.trailingAnchor],
        [wrap.bottomAnchor constraintEqualToAnchor:host.bottomAnchor],
    ]];

    CAGradientLayer *grad = [CAGradientLayer layer];
    grad.colors = @[
        (id)[UIColor whiteColor].CGColor,
        (id)[self canvasSecondary].CGColor,
        (id)[self canvas].CGColor,
    ];
    grad.locations = @[@0.0, @0.45, @1.0];
    grad.startPoint = CGPointMake(0.15, 0.0);
    grad.endPoint = CGPointMake(0.85, 1.0);
    [wrap.layer addSublayer:grad];

    CAGradientLayer *wash = [CAGradientLayer layer];
    wash.type = kCAGradientLayerRadial;
    wash.colors = @[
        (id)[[self accent] colorWithAlphaComponent:0.12].CGColor,
        (id)[[self accent] colorWithAlphaComponent:0.0].CGColor,
    ];
    wash.startPoint = CGPointMake(0.5, 0.5);
    wash.endPoint = CGPointMake(1.0, 1.0);
    [wrap.layer addSublayer:wash];

    CAShapeLayer *grid = [CAShapeLayer layer];
    grid.strokeColor = [[self accent] colorWithAlphaComponent:0.06].CGColor;
    grid.fillColor = UIColor.clearColor.CGColor;
    grid.lineWidth = 1.0 / UIScreen.mainScreen.scale;
    [wrap.layer addSublayer:grid];

    NDBackdropLayoutView *layout = [NDBackdropLayoutView new];
    layout.grad = grad;
    layout.wash = wash;
    layout.grid = grid;
    layout.translatesAutoresizingMaskIntoConstraints = NO;
    [wrap addSubview:layout];
    [NSLayoutConstraint activateConstraints:@[
        [layout.topAnchor constraintEqualToAnchor:wrap.topAnchor],
        [layout.leadingAnchor constraintEqualToAnchor:wrap.leadingAnchor],
        [layout.trailingAnchor constraintEqualToAnchor:wrap.trailingAnchor],
        [layout.bottomAnchor constraintEqualToAnchor:wrap.bottomAnchor],
    ]];
    return wrap;
}

+ (UIButton *)primaryButton:(NSString *)title target:(id)target action:(SEL)action {
    UIButton *b = [UIButton buttonWithType:UIButtonTypeSystem];
    [b setTitle:title forState:UIControlStateNormal];
    [b setTitleColor:UIColor.whiteColor forState:UIControlStateNormal];
    b.backgroundColor = [self accent];
    b.titleLabel.font = [self ndFont:17 weight:UIFontWeightSemibold design:UIFontDescriptorSystemDesignRounded];
    b.layer.cornerRadius = 14;
    b.layer.cornerCurve = kCACornerCurveContinuous;
    b.layer.shadowColor = [self accent].CGColor;
    b.layer.shadowOpacity = 0.28;
    b.layer.shadowRadius = 10;
    b.layer.shadowOffset = CGSizeMake(0, 5);
    [b.heightAnchor constraintEqualToConstant:52].active = YES;
    [b addTarget:target action:action forControlEvents:UIControlEventTouchUpInside];
    return b;
}

+ (UIButton *)secondaryButton:(NSString *)title target:(id)target action:(SEL)action {
    UIButton *b = [UIButton buttonWithType:UIButtonTypeSystem];
    [b setTitle:title forState:UIControlStateNormal];
    [b setTitleColor:[self accentStrong] forState:UIControlStateNormal];
    b.backgroundColor = [UIColor whiteColor];
    b.titleLabel.font = [self ndFont:15 weight:UIFontWeightSemibold design:UIFontDescriptorSystemDesignRounded];
    b.layer.cornerRadius = 12;
    b.layer.cornerCurve = kCACornerCurveContinuous;
    b.layer.borderWidth = 1.0 / UIScreen.mainScreen.scale;
    b.layer.borderColor = [self hairline].CGColor;
    [b.heightAnchor constraintEqualToConstant:44].active = YES;
    [b addTarget:target action:action forControlEvents:UIControlEventTouchUpInside];
    return b;
}

+ (UILabel *)captionLabel:(NSString *)text {
    UILabel *l = [UILabel new];
    l.text = text;
    l.font = [self captionFont];
    l.textColor = [self muted];
    return l;
}

+ (UILabel *)sectionTitle:(NSString *)text {
    UILabel *l = [UILabel new];
    l.text = text;
    l.font = [self headlineFont];
    l.textColor = [self ink];
    return l;
}

+ (UIView *)statusChip:(NSString *)text color:(UIColor *)color {
    UIView *chip = [UIView new];
    chip.backgroundColor = [color colorWithAlphaComponent:0.10];
    chip.layer.cornerRadius = 10;
    chip.layer.cornerCurve = kCACornerCurveContinuous;
    chip.layer.borderWidth = 1.0 / UIScreen.mainScreen.scale;
    chip.layer.borderColor = [color colorWithAlphaComponent:0.22].CGColor;

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
        [label.topAnchor constraintEqualToAnchor:chip.topAnchor constant:7],
        [label.bottomAnchor constraintEqualToAnchor:chip.bottomAnchor constant:-7],
    ]];
    return chip;
}

+ (UIView *)metricPill:(NSString *)title value:(NSString *)value tone:(UIColor *)tone {
    UIView *pill = [UIView new];
    pill.backgroundColor = [UIColor whiteColor];
    pill.layer.cornerRadius = 14;
    pill.layer.cornerCurve = kCACornerCurveContinuous;
    pill.layer.borderWidth = 1.0 / UIScreen.mainScreen.scale;
    pill.layer.borderColor = [self hairline].CGColor;

    UILabel *t = [UILabel new];
    t.text = title.uppercaseString;
    t.font = [UIFont systemFontOfSize:10 weight:UIFontWeightBold];
    t.textColor = [self muted];
    t.translatesAutoresizingMaskIntoConstraints = NO;

    UILabel *v = [UILabel new];
    v.text = value;
    v.font = [self monoFont:13];
    v.textColor = tone ?: [self ink];
    v.translatesAutoresizingMaskIntoConstraints = NO;
    v.adjustsFontSizeToFitWidth = YES;
    v.minimumScaleFactor = 0.8;

    UIView *bar = [UIView new];
    bar.backgroundColor = tone ?: [self accent];
    bar.layer.cornerRadius = 1.5;
    bar.translatesAutoresizingMaskIntoConstraints = NO;

    [pill addSubview:bar];
    [pill addSubview:t];
    [pill addSubview:v];
    [NSLayoutConstraint activateConstraints:@[
        [bar.leadingAnchor constraintEqualToAnchor:pill.leadingAnchor constant:12],
        [bar.topAnchor constraintEqualToAnchor:pill.topAnchor constant:14],
        [bar.widthAnchor constraintEqualToConstant:14],
        [bar.heightAnchor constraintEqualToConstant:3],
        [t.topAnchor constraintEqualToAnchor:bar.bottomAnchor constant:8],
        [t.leadingAnchor constraintEqualToAnchor:pill.leadingAnchor constant:12],
        [t.trailingAnchor constraintEqualToAnchor:pill.trailingAnchor constant:-12],
        [v.topAnchor constraintEqualToAnchor:t.bottomAnchor constant:4],
        [v.leadingAnchor constraintEqualToAnchor:pill.leadingAnchor constant:12],
        [v.trailingAnchor constraintEqualToAnchor:pill.trailingAnchor constant:-12],
        [v.bottomAnchor constraintEqualToAnchor:pill.bottomAnchor constant:-12],
    ]];
    return pill;
}

@end
