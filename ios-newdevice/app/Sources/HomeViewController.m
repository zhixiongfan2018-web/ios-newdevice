#import "HomeViewController.h"
#import "NDAPIClient.h"
#import "NDRecordStore.h"
#import "NDDeviceProfile.h"
#import "NDAirplane.h"
#import "NDHTTPServer.h"
#import "NDPaths.h"
#import "NDTheme.h"
#import "NDConfig.h"
#import "ProbeViewController.h"
#import "ProfileDetailViewController.h"

@interface HomeViewController ()
@property (nonatomic, strong) UIScrollView *scroll;
@property (nonatomic, strong) UIStackView *content;
@property (nonatomic, strong) UILabel *recordNameLabel;
@property (nonatomic, strong) UILabel *modelLabel;
@property (nonatomic, strong) UILabel *summaryLabel;
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
    [self.content addArrangedSubview:[self buildSummaryCard]];
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

    self.chipRow = [UIStackView new];
    self.chipRow.axis = UILayoutConstraintAxisHorizontal;
    self.chipRow.spacing = 8;
    self.chipRow.alignment = UIStackViewAlignmentCenter;
    self.chipRow.translatesAutoresizingMaskIntoConstraints = NO;

    self.apiChip = [NDTheme statusChip:@"API" color:[UIColor secondaryLabelColor]];
    self.ipChip = [NDTheme statusChip:@"IP" color:[UIColor secondaryLabelColor]];
    [self.chipRow addArrangedSubview:self.apiChip];
    [self.chipRow addArrangedSubview:self.ipChip];
    [self.chipRow addArrangedSubview:[UIView new]];

    [card addSubview:self.chipRow];

    [NSLayoutConstraint activateConstraints:@[
        [self.chipRow.topAnchor constraintEqualToAnchor:card.topAnchor constant:14],
        [self.chipRow.leadingAnchor constraintEqualToAnchor:card.leadingAnchor constant:18],
        [self.chipRow.trailingAnchor constraintEqualToAnchor:card.trailingAnchor constant:-18],
        [self.chipRow.bottomAnchor constraintEqualToAnchor:card.bottomAnchor constant:-14],
    ]];
    return card;
}

- (UIView *)buildSummaryCard {
    UIView *card = [UIView new];
    [NDTheme styleCard:card];

    UILabel *title = [NDTheme captionLabel:@"环境参数"];
    title.textColor = [NDTheme accent];
    title.translatesAutoresizingMaskIntoConstraints = NO;

    self.summaryLabel = [UILabel new];
    self.summaryLabel.font = [NDTheme monoFont:13];
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
}

- (void)refreshAPIStatus {
    NSError *err = nil;
    BOOL ok = [[NDHTTPServer shared] ensureRunning:&err];
    UIColor *color = (ok || [NDHTTPServer shared].running) ? [NDTheme success] : [NDTheme danger];
    NSString *text = (ok || [NDHTTPServer shared].running) ? @"API 正常" : @"API 关闭";
    UIView *chip = [NDTheme statusChip:text color:color];
    [self replaceChip:self.apiChip with:chip inRow:self.chipRow];
    self.apiChip = chip;
}

- (void)refresh {
    NDDeviceProfile *p = [[NDRecordStore shared] currentProfile];
    if (p.remark.length) {
        self.recordNameLabel.text = p.remark;
        self.modelLabel.text = [NSString stringWithFormat:@"%@\n%@ · iOS %@",
                                p.name.length ? p.name : @"--",
                                p.Model ?: @"未知机型", p.SystemVer ?: @"--"];
        self.modelLabel.numberOfLines = 2;
    } else {
        self.recordNameLabel.text = p.name.length ? p.name : @"--";
        self.modelLabel.text = [NSString stringWithFormat:@"%@ · iOS %@", p.Model ?: @"未知机型", p.SystemVer ?: @"--"];
        self.modelLabel.numberOfLines = 1;
    }

    // Always show the *environment* IDFA from the active profile — never ASIdentifierManager
    // (NewDevice.app is on the tweak RejectList, so the system IDFA is the real device).
    BOOL passthrough = !p || [p.name isEqualToString:@"原始机器"] || !p.spoofDeviceIdentity;
    NSString *idfa = passthrough ? @"（原始 / 不伪装）" : (p.IDFA.length ? p.IDFA : @"（未填写）");
    NSString *idfv = passthrough ? @"—" : (p.IDFV.length ? p.IDFV : @"—");
    self.summaryLabel.text = [NSString stringWithFormat:
                              @"IDFA  %@\nIDFV  %@\nIMEI  %@\nSerial %@\nUDID  %@\nWiFi  %@\nSSID  %@\n运营商 %@ (%@/%@)\nTZ    %@\nGPS   %.5f, %.5f",
                              idfa, idfv, p.IMEI.length ? p.IMEI : @"—",
                              p.Serial.length ? p.Serial : @"—", p.UDID.length ? p.UDID : @"—",
                              p.WiFiMAC.length ? p.WiFiMAC : @"—", p.SSID.length ? p.SSID : @"—",
                              p.Carrier.length ? p.Carrier : @"—", p.MCC.length ? p.MCC : @"—", p.MNC.length ? p.MNC : @"—",
                              p.TimeZone.length ? p.TimeZone : @"—",
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
            [self alert:error.localizedDescription ?: @"执行失败"];
        }
    }];
}

- (void)newDevice {
    if (self.busy) return;

    [[NDConfig shared] reload];
    if (![NDConfig shared].targetApps.count) {
        UIAlertController *a = [UIAlertController alertControllerWithTitle:@"请先选中环境应用"
                                                                   message:@"到「应用」页勾选要隔离的 App（如 Venmo）并保存，再一键新机。"
                                                            preferredStyle:UIAlertControllerStyleAlert];
        [a addAction:[UIAlertAction actionWithTitle:@"去应用页" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
            self.tabBarController.selectedIndex = 2;
        }]];
        [a addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
        [self presentViewController:a animated:YES completion:nil];
        return;
    }

    [self runNewDevice];
}

- (void)runNewDevice {
    if (self.busy) return;
    self.busy = YES;
    NSString *prevIP = self.lastIP;
    [[NDAPIClient shared] call:@"newRecord" completion:^(BOOL ok, NSString *body, NSError *error) {
        self.busy = NO;
        [self refresh];
        [self refreshAPIStatus];
        [self refreshIP:YES expectedChangeFrom:prevIP];
        if (!ok) {
            [self alert:error.localizedDescription ?: (body.length ? body : @"执行失败")];
            return;
        }
        NSString *name = [body stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
        if (!name.length) name = [[NDRecordStore shared] currentRecordName] ?: @"";
        NSString *msg = name.length
            ? [NSString stringWithFormat:@"已新建环境：%@\n原有环境未改身份，可在「记录」里切回去。", name]
            : @"已完成";
        [self alert:msg];
    }];
}

- (void)original { [self run:@"originRecord"]; }
- (void)nextRecord { [self run:@"nextRecord"]; }

- (void)refreshIP:(BOOL)compare {
    [self refreshIP:compare expectedChangeFrom:self.lastIP];
}

- (void)refreshIP:(BOOL)compare expectedChangeFrom:(NSString *)prev {
    [NDAirplane fetchPublicIPWithCompletion:^(NSString *ip, NSError *error) {
        dispatch_async(dispatch_get_main_queue(), ^{
            UIColor *color = [UIColor secondaryLabelColor];
            NSString *chipText = @"IP";
            if (!ip) {
                chipText = @"IP 失败";
                color = [NDTheme warning];
                self.lastIP = nil;
            } else {
                chipText = @"IP 正常";
                if (compare && prev.length && [prev isEqualToString:ip]) {
                    chipText = @"IP 未变";
                    color = [NDTheme warning];
                } else {
                    color = [NDTheme success];
                }
                self.lastIP = ip;
            }
            UIView *chip = [NDTheme statusChip:chipText color:color];
            [self replaceChip:self.ipChip with:chip inRow:self.chipRow];
            self.ipChip = chip;
        });
    }];
}

- (void)openProbe {
    [self.navigationController pushViewController:[ProbeViewController new] animated:YES];
}

- (void)openDetail {
    NDDeviceProfile *p = [[NDRecordStore shared] currentProfile];
    if (!p) return;
    [self.navigationController pushViewController:[[ProfileDetailViewController alloc] initWithProfile:p] animated:YES];
}

- (void)alert:(NSString *)msg {
    UIAlertController *a = [UIAlertController alertControllerWithTitle:nil message:msg preferredStyle:UIAlertControllerStyleAlert];
    [a addAction:[UIAlertAction actionWithTitle:@"好" style:UIAlertActionStyleDefault handler:nil]];
    [self presentViewController:a animated:YES completion:nil];
}

@end
