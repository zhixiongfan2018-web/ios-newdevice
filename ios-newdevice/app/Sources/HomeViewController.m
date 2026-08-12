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
@property (nonatomic, strong) UIActivityIndicatorView *spinner;
@property (nonatomic, strong) UIView *busyOverlay;
@property (nonatomic, copy) NSString *lastIP;
@property (nonatomic, assign) BOOL busy;
@end

@implementation HomeViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"NewDevice";
    self.view.backgroundColor = [NDTheme canvas];
    self.navigationController.navigationBar.prefersLargeTitles = YES;
    self.navigationItem.largeTitleDisplayMode = UINavigationItemLargeTitleDisplayModeAlways;
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithImage:[UIImage systemImageNamed:@"antenna.radiowaves.left.and.right"] style:UIBarButtonItemStylePlain target:self action:@selector(openProbe)];
    self.navigationItem.rightBarButtonItem.accessibilityLabel = @"探测";

    self.scroll = [UIScrollView new];
    self.scroll.translatesAutoresizingMaskIntoConstraints = NO;
    self.scroll.alwaysBounceVertical = YES;
    [self.view addSubview:self.scroll];

    self.content = [UIStackView new];
    self.content.axis = UILayoutConstraintAxisVertical;
    self.content.spacing = 16;
    self.content.translatesAutoresizingMaskIntoConstraints = NO;
    [self.scroll addSubview:self.content];

    [NSLayoutConstraint activateConstraints:@[
        [self.scroll.topAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.topAnchor],
        [self.scroll.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [self.scroll.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [self.scroll.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor],
        [self.content.topAnchor constraintEqualToAnchor:self.scroll.contentLayoutGuide.topAnchor constant:8],
        [self.content.leadingAnchor constraintEqualToAnchor:self.scroll.frameLayoutGuide.leadingAnchor constant:20],
        [self.content.trailingAnchor constraintEqualToAnchor:self.scroll.frameLayoutGuide.trailingAnchor constant:-20],
        [self.content.bottomAnchor constraintEqualToAnchor:self.scroll.contentLayoutGuide.bottomAnchor constant:-28],
        [self.content.widthAnchor constraintEqualToAnchor:self.scroll.frameLayoutGuide.widthAnchor constant:-40],
    ]];

    [self.content addArrangedSubview:[self buildHeroCard]];
    [self.content addArrangedSubview:[self buildStatusCard]];
    [self.content addArrangedSubview:[self buildIdentityCard]];
    [self.content addArrangedSubview:[self buildActions]];

    self.busyOverlay = [UIView new];
    self.busyOverlay.backgroundColor = [[UIColor systemBackgroundColor] colorWithAlphaComponent:0.35];
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

- (UIView *)buildHeroCard {
    UIView *card = [UIView new];
    [NDTheme styleCard:card];

    UILabel *eyebrow = [NDTheme captionLabel:@"当前身份"];
    eyebrow.textColor = [NDTheme accent];
    eyebrow.translatesAutoresizingMaskIntoConstraints = NO;

    self.recordNameLabel = [UILabel new];
    self.recordNameLabel.font = [UIFont systemFontOfSize:24 weight:UIFontWeightBold];
    self.recordNameLabel.numberOfLines = 2;
    self.recordNameLabel.translatesAutoresizingMaskIntoConstraints = NO;

    self.modelLabel = [UILabel new];
    self.modelLabel.font = [NDTheme bodyFont];
    self.modelLabel.textColor = [UIColor secondaryLabelColor];
    self.modelLabel.translatesAutoresizingMaskIntoConstraints = NO;

    UIImageView *icon = [[UIImageView alloc] initWithImage:[UIImage systemImageNamed:@"iphone"]];
    icon.tintColor = [NDTheme accent];
    icon.contentMode = UIViewContentModeScaleAspectFit;
    icon.translatesAutoresizingMaskIntoConstraints = NO;

    UIView *iconWell = [UIView new];
    iconWell.backgroundColor = [NDTheme accentMuted];
    iconWell.layer.cornerRadius = 16;
    iconWell.translatesAutoresizingMaskIntoConstraints = NO;
    [iconWell addSubview:icon];

    [card addSubview:eyebrow];
    [card addSubview:self.recordNameLabel];
    [card addSubview:self.modelLabel];
    [card addSubview:iconWell];

    [NSLayoutConstraint activateConstraints:@[
        [iconWell.topAnchor constraintEqualToAnchor:card.topAnchor constant:18],
        [iconWell.trailingAnchor constraintEqualToAnchor:card.trailingAnchor constant:-18],
        [iconWell.widthAnchor constraintEqualToConstant:52],
        [iconWell.heightAnchor constraintEqualToConstant:52],
        [icon.centerXAnchor constraintEqualToAnchor:iconWell.centerXAnchor],
        [icon.centerYAnchor constraintEqualToAnchor:iconWell.centerYAnchor],
        [icon.widthAnchor constraintEqualToConstant:26],
        [icon.heightAnchor constraintEqualToConstant:26],
        [eyebrow.topAnchor constraintEqualToAnchor:card.topAnchor constant:18],
        [eyebrow.leadingAnchor constraintEqualToAnchor:card.leadingAnchor constant:18],
        [eyebrow.trailingAnchor constraintLessThanOrEqualToAnchor:iconWell.leadingAnchor constant:-12],
        [self.recordNameLabel.topAnchor constraintEqualToAnchor:eyebrow.bottomAnchor constant:6],
        [self.recordNameLabel.leadingAnchor constraintEqualToAnchor:card.leadingAnchor constant:18],
        [self.recordNameLabel.trailingAnchor constraintEqualToAnchor:iconWell.leadingAnchor constant:-12],
        [self.modelLabel.topAnchor constraintEqualToAnchor:self.recordNameLabel.bottomAnchor constant:6],
        [self.modelLabel.leadingAnchor constraintEqualToAnchor:card.leadingAnchor constant:18],
        [self.modelLabel.trailingAnchor constraintEqualToAnchor:card.trailingAnchor constant:-18],
        [self.modelLabel.bottomAnchor constraintEqualToAnchor:card.bottomAnchor constant:-18],
    ]];
    return card;
}

- (UIView *)buildStatusCard {
    UIView *card = [UIView new];
    [NDTheme styleCard:card];

    UILabel *title = [UILabel new];
    title.text = @"运行状态";
    title.font = [NDTheme headlineFont];
    title.translatesAutoresizingMaskIntoConstraints = NO;

    self.chipRow = [UIStackView new];
    self.chipRow.axis = UILayoutConstraintAxisHorizontal;
    self.chipRow.spacing = 8;
    self.chipRow.alignment = UIStackViewAlignmentCenter;
    self.chipRow.translatesAutoresizingMaskIntoConstraints = NO;

    self.apiChip = [NDTheme statusChip:@"API 检测中" color:[UIColor secondaryLabelColor]];
    self.ipChip = [NDTheme statusChip:@"IP --" color:[UIColor secondaryLabelColor]];
    [self.chipRow addArrangedSubview:self.apiChip];
    [self.chipRow addArrangedSubview:self.ipChip];
    [self.chipRow addArrangedSubview:[UIView new]];

    self.statusDetailLabel = [UILabel new];
    self.statusDetailLabel.font = [NDTheme monoFont:12.5];
    self.statusDetailLabel.textColor = [UIColor secondaryLabelColor];
    self.statusDetailLabel.numberOfLines = 3;
    self.statusDetailLabel.translatesAutoresizingMaskIntoConstraints = NO;

    [card addSubview:title];
    [card addSubview:self.chipRow];
    [card addSubview:self.statusDetailLabel];

    [NSLayoutConstraint activateConstraints:@[
        [title.topAnchor constraintEqualToAnchor:card.topAnchor constant:16],
        [title.leadingAnchor constraintEqualToAnchor:card.leadingAnchor constant:18],
        [title.trailingAnchor constraintEqualToAnchor:card.trailingAnchor constant:-18],
        [self.chipRow.topAnchor constraintEqualToAnchor:title.bottomAnchor constant:12],
        [self.chipRow.leadingAnchor constraintEqualToAnchor:card.leadingAnchor constant:18],
        [self.chipRow.trailingAnchor constraintEqualToAnchor:card.trailingAnchor constant:-18],
        [self.statusDetailLabel.topAnchor constraintEqualToAnchor:self.chipRow.bottomAnchor constant:10],
        [self.statusDetailLabel.leadingAnchor constraintEqualToAnchor:card.leadingAnchor constant:18],
        [self.statusDetailLabel.trailingAnchor constraintEqualToAnchor:card.trailingAnchor constant:-18],
        [self.statusDetailLabel.bottomAnchor constraintEqualToAnchor:card.bottomAnchor constant:-16],
    ]];
    return card;
}

- (UIView *)buildIdentityCard {
    UIView *card = [UIView new];
    [NDTheme styleCard:card];

    UILabel *title = [UILabel new];
    title.text = @"参数摘要";
    title.font = [NDTheme headlineFont];
    title.translatesAutoresizingMaskIntoConstraints = NO;

    self.summaryLabel = [UILabel new];
    self.summaryLabel.font = [NDTheme monoFont:12.5];
    self.summaryLabel.textColor = [UIColor secondaryLabelColor];
    self.summaryLabel.numberOfLines = 0;
    self.summaryLabel.translatesAutoresizingMaskIntoConstraints = NO;

    UIButton *detail = [NDTheme secondaryButton:@"查看 / 编辑参数" target:self action:@selector(openDetail)];
    detail.translatesAutoresizingMaskIntoConstraints = NO;

    [card addSubview:title];
    [card addSubview:self.summaryLabel];
    [card addSubview:detail];

    [NSLayoutConstraint activateConstraints:@[
        [title.topAnchor constraintEqualToAnchor:card.topAnchor constant:16],
        [title.leadingAnchor constraintEqualToAnchor:card.leadingAnchor constant:18],
        [title.trailingAnchor constraintEqualToAnchor:card.trailingAnchor constant:-18],
        [self.summaryLabel.topAnchor constraintEqualToAnchor:title.bottomAnchor constant:10],
        [self.summaryLabel.leadingAnchor constraintEqualToAnchor:card.leadingAnchor constant:18],
        [self.summaryLabel.trailingAnchor constraintEqualToAnchor:card.trailingAnchor constant:-18],
        [detail.topAnchor constraintEqualToAnchor:self.summaryLabel.bottomAnchor constant:14],
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

- (void)replaceChip:(UIView *)old with:(UIView *)neu inRow:(UIStackView *)row {
    NSUInteger idx = [row.arrangedSubviews indexOfObject:old];
    if (idx == NSNotFound) return;
    [row removeArrangedSubview:old];
    [old removeFromSuperview];
    [row insertArrangedSubview:neu atIndex:idx];
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    // Migrate/publish world-readable runtime.plist so sandboxed target apps can spoof
    [[NDRecordStore shared] notifyReload];
    [self refresh];
    [self refreshAPIStatus];
    [self refreshIP:NO];
}

- (void)refreshStatusDetail {
    NSString *ipLine = self.lastIP.length ? [NSString stringWithFormat:@"公网 IP  %@", self.lastIP] : @"公网 IP  获取中…";
    NSString *apiLine = ([NDHTTPServer shared].running)
        ? @"API     http://127.0.0.1:8080/cmd（保持前台）"
        : @"API     未启动，请重启 App";
    self.statusDetailLabel.text = [NSString stringWithFormat:@"%@\n%@", ipLine, apiLine];
}

- (void)refreshAPIStatus {
    NSError *err = nil;
    BOOL ok = [[NDHTTPServer shared] ensureRunning:&err];
    UIColor *color = (ok || [NDHTTPServer shared].running) ? [NDTheme success] : [NDTheme danger];
    NSString *text = (ok || [NDHTTPServer shared].running) ? @"API 已监听" : @"API 未启动";
    UIView *chip = [NDTheme statusChip:text color:color];
    [self replaceChip:self.apiChip with:chip inRow:self.chipRow];
    self.apiChip = chip;
    [self refreshStatusDetail];
}

- (void)refresh {
    NDDeviceProfile *p = [[NDRecordStore shared] currentProfile];
    self.recordNameLabel.text = p.name.length ? p.name : @"--";
    self.modelLabel.text = [NSString stringWithFormat:@"%@ · iOS %@", p.Model ?: @"未知机型", p.SystemVer ?: @"--"];
    self.summaryLabel.text = [NSString stringWithFormat:
                              @"IDFA  %@\nIDFV  %@\nSerial %@\nUDID  %@\nWiFi  %@\n运营商 %@ (%@/%@)\nGPS   %.5f, %.5f",
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
            UIColor *color = [UIColor secondaryLabelColor];
            NSString *chipText = @"IP --";
            if (!ip) {
                chipText = @"IP 失败";
                color = [NDTheme warning];
                self.lastIP = nil;
            } else {
                chipText = @"IP 正常";
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
