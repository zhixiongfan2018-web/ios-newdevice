#import "HomeViewController.h"
#import "NDAPIClient.h"
#import "NDRecordStore.h"
#import "NDDeviceProfile.h"
#import "NDAirplane.h"
#import "NDHTTPServer.h"
#import "NDPaths.h"
#import "NDTheme.h"
#import "ProbeViewController.h"
#import "ProfileDetailViewController.h"
#import <QuartzCore/QuartzCore.h>

@interface HomeViewController ()
@property (nonatomic, strong) UIScrollView *scroll;
@property (nonatomic, strong) UIStackView *content;
@property (nonatomic, strong) UILabel *recordNameLabel;
@property (nonatomic, strong) UILabel *modelLabel;
@property (nonatomic, strong) UILabel *summaryLabel;
@property (nonatomic, strong) UILabel *statusDetailLabel;
@property (nonatomic, strong) UIView *apiChip;
@property (nonatomic, strong) UIView *ipChip;
@property (nonatomic, strong) UIStackView *chipRow;
@property (nonatomic, strong) UIView *apiMetric;
@property (nonatomic, strong) UIView *ipMetric;
@property (nonatomic, strong) UIStackView *metricRow;
@property (nonatomic, strong) UIActivityIndicatorView *spinner;
@property (nonatomic, strong) UIView *busyOverlay;
@property (nonatomic, copy) NSString *lastIP;
@property (nonatomic, assign) BOOL busy;
@property (nonatomic, strong) UIView *scanLine;
@end

@implementation HomeViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @" ";
    self.view.backgroundColor = [NDTheme canvas];
    [NDTheme canvasBackdropIn:self.view];
    self.navigationController.navigationBar.prefersLargeTitles = NO;
    self.navigationItem.largeTitleDisplayMode = UINavigationItemLargeTitleDisplayModeNever;
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithImage:[UIImage systemImageNamed:@"waveform.path.ecg"] style:UIBarButtonItemStylePlain target:self action:@selector(openProbe)];
    self.navigationItem.rightBarButtonItem.accessibilityLabel = @"探测";

    self.scroll = [UIScrollView new];
    self.scroll.translatesAutoresizingMaskIntoConstraints = NO;
    self.scroll.alwaysBounceVertical = YES;
    self.scroll.showsVerticalScrollIndicator = NO;
    [self.view addSubview:self.scroll];

    self.content = [UIStackView new];
    self.content.axis = UILayoutConstraintAxisVertical;
    self.content.spacing = 18;
    self.content.translatesAutoresizingMaskIntoConstraints = NO;
    [self.scroll addSubview:self.content];

    [NSLayoutConstraint activateConstraints:@[
        [self.scroll.topAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.topAnchor],
        [self.scroll.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [self.scroll.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [self.scroll.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor],
        [self.content.topAnchor constraintEqualToAnchor:self.scroll.contentLayoutGuide.topAnchor constant:4],
        [self.content.leadingAnchor constraintEqualToAnchor:self.scroll.frameLayoutGuide.leadingAnchor constant:20],
        [self.content.trailingAnchor constraintEqualToAnchor:self.scroll.frameLayoutGuide.trailingAnchor constant:-20],
        [self.content.bottomAnchor constraintEqualToAnchor:self.scroll.contentLayoutGuide.bottomAnchor constant:-32],
        [self.content.widthAnchor constraintEqualToAnchor:self.scroll.frameLayoutGuide.widthAnchor constant:-40],
    ]];

    [self.content addArrangedSubview:[self buildBrandHeader]];
    [self.content addArrangedSubview:[self buildHeroCard]];
    [self.content addArrangedSubview:[self buildMetricsRow]];
    [self.content addArrangedSubview:[self buildIdentityCard]];
    [self.content addArrangedSubview:[self buildActions]];

    self.busyOverlay = [UIView new];
    self.busyOverlay.backgroundColor = [[UIColor whiteColor] colorWithAlphaComponent:0.55];
    self.busyOverlay.hidden = YES;
    self.busyOverlay.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:self.busyOverlay];
    self.spinner = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleLarge];
    self.spinner.translatesAutoresizingMaskIntoConstraints = NO;
    self.spinner.color = [NDTheme accent];
    [self.busyOverlay addSubview:self.spinner];
    [NSLayoutConstraint activateConstraints:@[
        [self.busyOverlay.topAnchor constraintEqualToAnchor:self.view.topAnchor],
        [self.busyOverlay.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [self.busyOverlay.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [self.busyOverlay.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor],
        [self.spinner.centerXAnchor constraintEqualToAnchor:self.busyOverlay.centerXAnchor],
        [self.spinner.centerYAnchor constraintEqualToAnchor:self.busyOverlay.centerYAnchor],
    ]];
}

- (void)viewDidAppear:(BOOL)animated {
    [super viewDidAppear:animated];
    [self startScanMotion];
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        self.content.alpha = 0;
        self.content.transform = CGAffineTransformMakeTranslation(0, 12);
        [UIView animateWithDuration:0.55 delay:0.05 usingSpringWithDamping:0.86 initialSpringVelocity:0.4 options:UIViewAnimationOptionCurveEaseOut animations:^{
            self.content.alpha = 1;
            self.content.transform = CGAffineTransformIdentity;
        } completion:nil];
    });
}

- (UIView *)buildBrandHeader {
    UIView *wrap = [UIView new];

    UILabel *brand = [UILabel new];
    brand.text = @"NewDevice";
    brand.font = [NDTheme brandFont];
    brand.textColor = [NDTheme ink];
    brand.translatesAutoresizingMaskIntoConstraints = NO;

    UILabel *tag = [UILabel new];
    tag.text = @"一键刷新设备身份";
    tag.font = [NDTheme captionFont];
    tag.textColor = [NDTheme muted];
    tag.translatesAutoresizingMaskIntoConstraints = NO;

    UIView *accentBar = [UIView new];
    accentBar.backgroundColor = [NDTheme accent];
    accentBar.layer.cornerRadius = 2;
    accentBar.translatesAutoresizingMaskIntoConstraints = NO;

    [wrap addSubview:accentBar];
    [wrap addSubview:brand];
    [wrap addSubview:tag];

    [NSLayoutConstraint activateConstraints:@[
        [accentBar.leadingAnchor constraintEqualToAnchor:wrap.leadingAnchor],
        [accentBar.topAnchor constraintEqualToAnchor:wrap.topAnchor constant:8],
        [accentBar.widthAnchor constraintEqualToConstant:28],
        [accentBar.heightAnchor constraintEqualToConstant:4],
        [brand.topAnchor constraintEqualToAnchor:accentBar.bottomAnchor constant:10],
        [brand.leadingAnchor constraintEqualToAnchor:wrap.leadingAnchor],
        [brand.trailingAnchor constraintEqualToAnchor:wrap.trailingAnchor],
        [tag.topAnchor constraintEqualToAnchor:brand.bottomAnchor constant:4],
        [tag.leadingAnchor constraintEqualToAnchor:wrap.leadingAnchor],
        [tag.trailingAnchor constraintEqualToAnchor:wrap.trailingAnchor],
        [tag.bottomAnchor constraintEqualToAnchor:wrap.bottomAnchor],
    ]];
    return wrap;
}

- (UIView *)buildHeroCard {
    UIView *card = [UIView new];
    [NDTheme stylePanel:card];
    card.clipsToBounds = NO;

    UIView *inner = [UIView new];
    inner.translatesAutoresizingMaskIntoConstraints = NO;
    inner.layer.cornerRadius = 16;
    inner.layer.cornerCurve = kCACornerCurveContinuous;
    inner.clipsToBounds = YES;
    [card addSubview:inner];

    CAGradientLayer *sheen = [CAGradientLayer layer];
    sheen.colors = @[
        (id)[UIColor whiteColor].CGColor,
        (id)[[NDTheme accent] colorWithAlphaComponent:0.06].CGColor,
    ];
    sheen.startPoint = CGPointMake(0, 0);
    sheen.endPoint = CGPointMake(1, 1);
    sheen.frame = CGRectMake(0, 0, 400, 160);
    [inner.layer insertSublayer:sheen atIndex:0];

    self.scanLine = [UIView new];
    self.scanLine.backgroundColor = [[NDTheme accent] colorWithAlphaComponent:0.35];
    self.scanLine.translatesAutoresizingMaskIntoConstraints = NO;
    [inner addSubview:self.scanLine];

    UILabel *eyebrow = [NDTheme captionLabel:@"ACTIVE PROFILE"];
    eyebrow.textColor = [NDTheme accent];
    eyebrow.font = [UIFont systemFontOfSize:11 weight:UIFontWeightBold];
    eyebrow.translatesAutoresizingMaskIntoConstraints = NO;

    self.recordNameLabel = [UILabel new];
    self.recordNameLabel.font = [UIFont systemFontOfSize:26 weight:UIFontWeightBold];
    self.recordNameLabel.textColor = [NDTheme ink];
    self.recordNameLabel.numberOfLines = 2;
    self.recordNameLabel.translatesAutoresizingMaskIntoConstraints = NO;

    self.modelLabel = [UILabel new];
    self.modelLabel.font = [NDTheme monoFont:13];
    self.modelLabel.textColor = [NDTheme muted];
    self.modelLabel.translatesAutoresizingMaskIntoConstraints = NO;

    UIImageView *icon = [[UIImageView alloc] initWithImage:[UIImage systemImageNamed:@"cpu"]];
    icon.tintColor = [NDTheme accent];
    icon.contentMode = UIViewContentModeScaleAspectFit;
    icon.translatesAutoresizingMaskIntoConstraints = NO;

    UIView *iconWell = [UIView new];
    iconWell.backgroundColor = [NDTheme accentMuted];
    iconWell.layer.cornerRadius = 18;
    iconWell.layer.borderWidth = 1.0 / UIScreen.mainScreen.scale;
    iconWell.layer.borderColor = [[NDTheme accent] colorWithAlphaComponent:0.2].CGColor;
    iconWell.translatesAutoresizingMaskIntoConstraints = NO;
    [iconWell addSubview:icon];

    self.chipRow = [UIStackView new];
    self.chipRow.axis = UILayoutConstraintAxisHorizontal;
    self.chipRow.spacing = 8;
    self.chipRow.alignment = UIStackViewAlignmentCenter;
    self.chipRow.translatesAutoresizingMaskIntoConstraints = NO;
    self.apiChip = [NDTheme statusChip:@"API 检测中" color:[NDTheme muted]];
    self.ipChip = [NDTheme statusChip:@"IP --" color:[NDTheme muted]];
    [self.chipRow addArrangedSubview:self.apiChip];
    [self.chipRow addArrangedSubview:self.ipChip];
    [self.chipRow addArrangedSubview:[UIView new]];

    [inner addSubview:eyebrow];
    [inner addSubview:self.recordNameLabel];
    [inner addSubview:self.modelLabel];
    [inner addSubview:iconWell];
    [inner addSubview:self.chipRow];

    [NSLayoutConstraint activateConstraints:@[
        [inner.topAnchor constraintEqualToAnchor:card.topAnchor],
        [inner.leadingAnchor constraintEqualToAnchor:card.leadingAnchor],
        [inner.trailingAnchor constraintEqualToAnchor:card.trailingAnchor],
        [inner.bottomAnchor constraintEqualToAnchor:card.bottomAnchor],

        [self.scanLine.leadingAnchor constraintEqualToAnchor:inner.leadingAnchor],
        [self.scanLine.trailingAnchor constraintEqualToAnchor:inner.trailingAnchor],
        [self.scanLine.topAnchor constraintEqualToAnchor:inner.topAnchor],
        [self.scanLine.heightAnchor constraintEqualToConstant:1.5],

        [iconWell.topAnchor constraintEqualToAnchor:inner.topAnchor constant:20],
        [iconWell.trailingAnchor constraintEqualToAnchor:inner.trailingAnchor constant:-18],
        [iconWell.widthAnchor constraintEqualToConstant:56],
        [iconWell.heightAnchor constraintEqualToConstant:56],
        [icon.centerXAnchor constraintEqualToAnchor:iconWell.centerXAnchor],
        [icon.centerYAnchor constraintEqualToAnchor:iconWell.centerYAnchor],
        [icon.widthAnchor constraintEqualToConstant:26],
        [icon.heightAnchor constraintEqualToConstant:26],

        [eyebrow.topAnchor constraintEqualToAnchor:inner.topAnchor constant:20],
        [eyebrow.leadingAnchor constraintEqualToAnchor:inner.leadingAnchor constant:18],
        [eyebrow.trailingAnchor constraintLessThanOrEqualToAnchor:iconWell.leadingAnchor constant:-12],

        [self.recordNameLabel.topAnchor constraintEqualToAnchor:eyebrow.bottomAnchor constant:8],
        [self.recordNameLabel.leadingAnchor constraintEqualToAnchor:inner.leadingAnchor constant:18],
        [self.recordNameLabel.trailingAnchor constraintEqualToAnchor:iconWell.leadingAnchor constant:-12],

        [self.modelLabel.topAnchor constraintEqualToAnchor:self.recordNameLabel.bottomAnchor constant:6],
        [self.modelLabel.leadingAnchor constraintEqualToAnchor:inner.leadingAnchor constant:18],
        [self.modelLabel.trailingAnchor constraintEqualToAnchor:inner.trailingAnchor constant:-18],

        [self.chipRow.topAnchor constraintEqualToAnchor:self.modelLabel.bottomAnchor constant:14],
        [self.chipRow.leadingAnchor constraintEqualToAnchor:inner.leadingAnchor constant:18],
        [self.chipRow.trailingAnchor constraintEqualToAnchor:inner.trailingAnchor constant:-18],
        [self.chipRow.bottomAnchor constraintEqualToAnchor:inner.bottomAnchor constant:-18],
    ]];
    return card;
}

- (UIView *)buildMetricsRow {
    self.metricRow = [UIStackView new];
    self.metricRow.axis = UILayoutConstraintAxisHorizontal;
    self.metricRow.spacing = 12;
    self.metricRow.distribution = UIStackViewDistributionFillEqually;

    self.apiMetric = [NDTheme metricPill:@"API" value:@"检测中" tone:[NDTheme muted]];
    self.ipMetric = [NDTheme metricPill:@"PUBLIC IP" value:@"--" tone:[NDTheme muted]];
    [self.metricRow addArrangedSubview:self.apiMetric];
    [self.metricRow addArrangedSubview:self.ipMetric];
    return self.metricRow;
}

- (UIView *)buildIdentityCard {
    UIView *card = [UIView new];
    [NDTheme stylePanel:card];

    UILabel *title = [NDTheme sectionTitle:@"参数摘要"];
    title.translatesAutoresizingMaskIntoConstraints = NO;

    UIView *rail = [UIView new];
    rail.backgroundColor = [NDTheme accent];
    rail.layer.cornerRadius = 1.5;
    rail.translatesAutoresizingMaskIntoConstraints = NO;

    self.summaryLabel = [UILabel new];
    self.summaryLabel.font = [NDTheme monoFont:12.5];
    self.summaryLabel.textColor = [NDTheme muted];
    self.summaryLabel.numberOfLines = 0;
    self.summaryLabel.translatesAutoresizingMaskIntoConstraints = NO;

    self.statusDetailLabel = [UILabel new];
    self.statusDetailLabel.font = [NDTheme monoFont:11.5];
    self.statusDetailLabel.textColor = [[NDTheme muted] colorWithAlphaComponent:0.9];
    self.statusDetailLabel.numberOfLines = 2;
    self.statusDetailLabel.translatesAutoresizingMaskIntoConstraints = NO;

    UIButton *detail = [NDTheme secondaryButton:@"查看 / 编辑参数" target:self action:@selector(openDetail)];
    detail.translatesAutoresizingMaskIntoConstraints = NO;

    [card addSubview:rail];
    [card addSubview:title];
    [card addSubview:self.summaryLabel];
    [card addSubview:self.statusDetailLabel];
    [card addSubview:detail];

    [NSLayoutConstraint activateConstraints:@[
        [rail.leadingAnchor constraintEqualToAnchor:card.leadingAnchor constant:18],
        [rail.topAnchor constraintEqualToAnchor:card.topAnchor constant:22],
        [rail.widthAnchor constraintEqualToConstant:3],
        [rail.heightAnchor constraintEqualToConstant:16],
        [title.centerYAnchor constraintEqualToAnchor:rail.centerYAnchor],
        [title.leadingAnchor constraintEqualToAnchor:rail.trailingAnchor constant:8],
        [title.trailingAnchor constraintEqualToAnchor:card.trailingAnchor constant:-18],
        [self.summaryLabel.topAnchor constraintEqualToAnchor:title.bottomAnchor constant:12],
        [self.summaryLabel.leadingAnchor constraintEqualToAnchor:card.leadingAnchor constant:18],
        [self.summaryLabel.trailingAnchor constraintEqualToAnchor:card.trailingAnchor constant:-18],
        [self.statusDetailLabel.topAnchor constraintEqualToAnchor:self.summaryLabel.bottomAnchor constant:12],
        [self.statusDetailLabel.leadingAnchor constraintEqualToAnchor:card.leadingAnchor constant:18],
        [self.statusDetailLabel.trailingAnchor constraintEqualToAnchor:card.trailingAnchor constant:-18],
        [detail.topAnchor constraintEqualToAnchor:self.statusDetailLabel.bottomAnchor constant:14],
        [detail.leadingAnchor constraintEqualToAnchor:card.leadingAnchor constant:18],
        [detail.trailingAnchor constraintEqualToAnchor:card.trailingAnchor constant:-18],
        [detail.bottomAnchor constraintEqualToAnchor:card.bottomAnchor constant:-16],
    ]];
    return card;
}

- (UIView *)buildActions {
    UIStackView *stack = [UIStackView new];
    stack.axis = UILayoutConstraintAxisVertical;
    stack.spacing = 10;

    UIButton *primary = [NDTheme primaryButton:@"一键新机" target:self action:@selector(newDevice)];
    UIStackView *row = [[UIStackView alloc] initWithArrangedSubviews:@[
        [NDTheme secondaryButton:@"原始机器" target:self action:@selector(original)],
        [NDTheme secondaryButton:@"下一条" target:self action:@selector(nextRecord)],
    ]];
    row.axis = UILayoutConstraintAxisHorizontal;
    row.spacing = 10;
    row.distribution = UIStackViewDistributionFillEqually;

    [stack addArrangedSubview:primary];
    [stack addArrangedSubview:row];
    return stack;
}

- (void)startScanMotion {
    if (!self.scanLine || self.scanLine.layer.animationKeys.count) return;
    CABasicAnimation *move = [CABasicAnimation animationWithKeyPath:@"transform.translation.y"];
    move.fromValue = @0;
    move.toValue = @140;
    move.duration = 2.4;
    move.repeatCount = HUGE_VALF;
    move.autoreverses = YES;
    move.timingFunction = [CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionEaseInEaseOut];
    [self.scanLine.layer addAnimation:move forKey:@"scan"];

    CABasicAnimation *pulse = [CABasicAnimation animationWithKeyPath:@"opacity"];
    pulse.fromValue = @0.25;
    pulse.toValue = @0.85;
    pulse.duration = 1.2;
    pulse.autoreverses = YES;
    pulse.repeatCount = HUGE_VALF;
    [self.scanLine.layer addAnimation:pulse forKey:@"pulse"];
}

- (void)replaceChip:(UIView *)old with:(UIView *)neu inRow:(UIStackView *)row {
    NSUInteger idx = [row.arrangedSubviews indexOfObject:old];
    if (idx == NSNotFound) return;
    [row removeArrangedSubview:old];
    [old removeFromSuperview];
    [row insertArrangedSubview:neu atIndex:idx];
}

- (void)replaceMetric:(UIView *)old with:(UIView *)neu {
    NSUInteger idx = [self.metricRow.arrangedSubviews indexOfObject:old];
    if (idx == NSNotFound) return;
    [self.metricRow removeArrangedSubview:old];
    [old removeFromSuperview];
    [self.metricRow insertArrangedSubview:neu atIndex:idx];
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [[NDRecordStore shared] notifyReload];
    [self refresh];
    [self refreshAPIStatus];
    [self refreshIP:NO];
}

- (void)refreshStatusDetail {
    NSString *ipLine = self.lastIP.length ? [NSString stringWithFormat:@"公网 IP  %@", self.lastIP] : @"公网 IP  获取中…";
    NSString *apiLine = ([NDHTTPServer shared].running)
        ? @"API     http://127.0.0.1:8080/cmd"
        : @"API     未启动，请重启 App";
    self.statusDetailLabel.text = [NSString stringWithFormat:@"%@  ·  %@", ipLine, apiLine];
}

- (void)refreshAPIStatus {
    NSError *err = nil;
    BOOL ok = [[NDHTTPServer shared] ensureRunning:&err];
    BOOL running = (ok || [NDHTTPServer shared].running);
    UIColor *color = running ? [NDTheme success] : [NDTheme danger];
    NSString *text = running ? @"API 已监听" : @"API 未启动";
    UIView *chip = [NDTheme statusChip:text color:color];
    [self replaceChip:self.apiChip with:chip inRow:self.chipRow];
    self.apiChip = chip;

    UIView *metric = [NDTheme metricPill:@"API" value:(running ? @":8080" : @"OFF") tone:color];
    [self replaceMetric:self.apiMetric with:metric];
    self.apiMetric = metric;
    [self refreshStatusDetail];
}

- (void)refresh {
    NDDeviceProfile *p = [[NDRecordStore shared] currentProfile];
    self.recordNameLabel.text = p.name.length ? p.name : @"--";
    self.modelLabel.text = [NSString stringWithFormat:@"%@  ·  iOS %@", p.Model ?: @"未知机型", p.SystemVer ?: @"--"];
    self.summaryLabel.text = [NSString stringWithFormat:
                              @"IDFA    %@\nIDFV    %@\nSerial  %@\nUDID    %@\nWiFi    %@\nCarrier %@ (%@/%@)\nGPS     %.5f, %.5f",
                              p.IDFA ?: @"-", p.IDFV ?: @"-", p.Serial ?: @"-", p.UDID ?: @"-",
                              p.WiFiMAC ?: @"-", p.Carrier ?: @"-", p.MCC ?: @"-", p.MNC ?: @"-",
                              p.Latitude, p.Longitude];
}

- (void)setBusy:(BOOL)busy {
    _busy = busy;
    self.busyOverlay.hidden = !busy;
    if (busy) [self.spinner startAnimating];
    else [self.spinner stopAnimating];
    self.view.userInteractionEnabled = !busy;
}

- (void)run:(NSString *)fun {
    if (self.busy) return;
    self.busy = YES;
    NSString *prevIP = self.lastIP;
    [[NDAPIClient shared] call:fun completion:^(BOOL ok, NSString *body, NSError *error) {
        self.busy = NO;
        [self refresh];
        [self refreshAPIStatus];
        [self refreshIP:YES expectedChangeFrom:prevIP];
        if (!ok) {
            [self alert:error.localizedDescription ?: @"执行失败（请确认 newdeviced 已运行）"];
        }
    }];
}

- (void)newDevice { [self run:@"newRecord"]; }
- (void)original { [self run:@"originRecord"]; }
- (void)nextRecord { [self run:@"nextRecord"]; }

- (void)refreshIP:(BOOL)compare {
    [self refreshIP:compare expectedChangeFrom:self.lastIP];
}

- (void)refreshIP:(BOOL)compare expectedChangeFrom:(NSString *)prev {
    [NDAirplane fetchPublicIPWithCompletion:^(NSString *ip, NSError *error) {
        dispatch_async(dispatch_get_main_queue(), ^{
            UIColor *color = [NDTheme muted];
            NSString *chipText = @"IP --";
            NSString *metricValue = @"--";
            if (!ip) {
                chipText = @"IP 失败";
                metricValue = @"FAIL";
                color = [NDTheme warning];
                self.lastIP = nil;
            } else {
                chipText = @"IP 正常";
                metricValue = ip;
                if (compare && prev.length && [prev isEqualToString:ip]) {
                    chipText = @"IP 未变";
                    color = [NDTheme danger];
                } else {
                    color = [NDTheme success];
                }
                self.lastIP = ip;
            }
            UIView *chip = [NDTheme statusChip:chipText color:color];
            [self replaceChip:self.ipChip with:chip inRow:self.chipRow];
            self.ipChip = chip;

            UIView *metric = [NDTheme metricPill:@"PUBLIC IP" value:metricValue tone:color];
            [self replaceMetric:self.ipMetric with:metric];
            self.ipMetric = metric;
            [self refreshStatusDetail];
        });
    }];
}

- (void)openProbe {
    [self.navigationController pushViewController:[ProbeViewController new] animated:YES];
}

- (void)openDetail {
    NDDeviceProfile *p = [[NDRecordStore shared] currentProfile];
    if (!p) return;
    ProfileDetailViewController *vc = [[ProfileDetailViewController alloc] initWithProfile:p];
    [self.navigationController pushViewController:vc animated:YES];
}

- (void)alert:(NSString *)msg {
    UIAlertController *a = [UIAlertController alertControllerWithTitle:@"提示" message:msg preferredStyle:UIAlertControllerStyleAlert];
    [a addAction:[UIAlertAction actionWithTitle:@"好" style:UIAlertActionStyleDefault handler:nil]];
    [self presentViewController:a animated:YES completion:nil];
}

@end
