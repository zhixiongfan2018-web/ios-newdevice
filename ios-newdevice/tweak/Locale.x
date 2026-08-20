#import <Foundation/Foundation.h>
#import "NDTweakState.h"
#import "NDSafeLoad.h"

%group NDLocaleLang
%hook NSLocale
+ (NSLocale *)currentLocale {
    NDTweakState *st = [NDTweakState shared];
    if ([st shouldSpoof]) {
        return [NSLocale localeWithLocaleIdentifier:@"en_US"];
    }
    return %orig;
}
+ (NSLocale *)autoupdatingCurrentLocale {
    NDTweakState *st = [NDTweakState shared];
    if ([st shouldSpoof]) {
        return [NSLocale localeWithLocaleIdentifier:@"en_US"];
    }
    return %orig;
}
+ (NSArray<NSString *> *)preferredLanguages {
    NDTweakState *st = [NDTweakState shared];
    if ([st shouldSpoof]) {
        return @[@"en-US", @"en"];
    }
    return %orig;
}
+ (NSArray *)preferredLocaleIdentifiers {
    NDTweakState *st = [NDTweakState shared];
    if ([st shouldSpoof]) {
        return @[@"en_US"];
    }
    return %orig;
}
%end

%hook NSBundle
- (NSArray<NSString *> *)preferredLocalizations {
    NDTweakState *st = [NDTweakState shared];
    if ([st shouldSpoof] && self == [NSBundle mainBundle]) {
        return @[@"en"];
    }
    return %orig;
}
%end
%end // NDLocaleLang

%group NDLocaleDefaults
%hook NSUserDefaults
- (id)objectForKey:(NSString *)defaultName {
    NDTweakState *st = [NDTweakState shared];
    if ([st shouldSpoof] && [defaultName isKindOfClass:[NSString class]]) {
        if ([defaultName isEqualToString:@"AppleLocale"]) return @"en_US";
        if ([defaultName isEqualToString:@"AppleLanguages"]) return @[@"en-US", @"en"];
        if ([defaultName isEqualToString:@"NSLanguages"]) return @[@"en-US", @"en"];
    }
    return %orig;
}
- (NSArray *)arrayForKey:(NSString *)defaultName {
    NDTweakState *st = [NDTweakState shared];
    if ([st shouldSpoof] && [defaultName isKindOfClass:[NSString class]]) {
        if ([defaultName isEqualToString:@"AppleLanguages"] || [defaultName isEqualToString:@"NSLanguages"]) {
            return @[@"en-US", @"en"];
        }
    }
    return %orig;
}
- (NSString *)stringForKey:(NSString *)defaultName {
    NDTweakState *st = [NDTweakState shared];
    if ([st shouldSpoof] && [defaultName isEqualToString:@"AppleLocale"]) return @"en_US";
    return %orig;
}
%end
%end // NDLocaleDefaults

%ctor {
    NDRunAfterUIKitReady(^{
        // NSLocale / NSUserDefaults getter swizzles crash PrizePicks RN (XPoint/RCT fatal).
        if (NDPrizePicksSkipRNSwizzles()) {
            return;
        }
        %init(NDLocaleLang);
        %init(NDLocaleDefaults);
    });
}
