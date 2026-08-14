#import <Foundation/Foundation.h>
#import "NDTweakState.h"
#import "NDSafeLoad.h"

static BOOL NDKeyLooksOpenUDID(NSString *key) {
    if (![key isKindOfClass:[NSString class]] || !key.length) return NO;
    NSString *l = key.lowercaseString;
    return [l containsString:@"openudid"]
        || [l isEqualToString:@"opendudid"]
        || [l containsString:@"uniqueidentifieruid"]
        || [l isEqualToString:@"uuid"]
        || [l isEqualToString:@"deviceuuid"]
        || [l isEqualToString:@"device_uuid"];
}

%group NDOpenUDID
%hook NSUserDefaults
- (id)objectForKey:(NSString *)defaultName {
    id v = %orig;
    NDTweakState *st = [NDTweakState shared];
    if (![st shouldSpoof]) return v;
    if (!NDKeyLooksOpenUDID(defaultName)) return v;
    NSString *l = defaultName.lowercaseString;
    if ([l containsString:@"openudid"] && st.profile.OpenUDID.length) return st.profile.OpenUDID;
    if (([l containsString:@"uuid"] || [l containsString:@"unique"]) && st.profile.UUID.length) return st.profile.UUID;
    return v;
}
- (NSString *)stringForKey:(NSString *)defaultName {
    NDTweakState *st = [NDTweakState shared];
    if ([st shouldSpoof] && NDKeyLooksOpenUDID(defaultName)) {
        NSString *l = defaultName.lowercaseString;
        if ([l containsString:@"openudid"] && st.profile.OpenUDID.length) return st.profile.OpenUDID;
        if (st.profile.UUID.length) return st.profile.UUID;
    }
    return %orig;
}
%end
%end // NDOpenUDID

%ctor {
    NDRunAfterUIKitReady(^{
        %init(NDOpenUDID);
    });
}
