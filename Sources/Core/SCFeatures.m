#import "SCFeatures.h"
#import "SCLog.h"

static NSString *const kNames[SCFeatureCount] = {@"jdsp", @"probe", @"search", @"playback", @"prefetch"};
static const BOOL kDefaults[SCFeatureCount] = {YES, YES, YES, YES, YES};

NSString *SCFeatureName(SCFeature feature) { return feature < SCFeatureCount ? kNames[feature] : @"?"; }

static NSString *flagKey(SCFeature f) { return [@"spotcloud.feature." stringByAppendingString:kNames[f]]; }
static NSString *strikeKey(SCFeature f) { return [@"spotcloud.strikes." stringByAppendingString:kNames[f]]; }

BOOL SCFeatureEnabled(SCFeature feature) {
    if (feature >= SCFeatureCount) return NO;
    id value = [NSUserDefaults.standardUserDefaults objectForKey:flagKey(feature)];
    return value ? [value boolValue] : kDefaults[feature];
}

void SCFeatureSetEnabled(SCFeature feature, BOOL enabled) {
    if (feature >= SCFeatureCount) return;
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    [defaults setBool:enabled forKey:flagKey(feature)];
    if (enabled) [defaults removeObjectForKey:strikeKey(feature)];
}

BOOL SCFeatureStart(SCFeature feature, void (^start)(void)) {
    if (!SCFeatureEnabled(feature)) {
        SCLog(@"features", @"%@ is off", SCFeatureName(feature));
        return NO;
    }
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    NSInteger strikes = [defaults integerForKey:strikeKey(feature)];
    if (strikes >= 3) {
        SCLog(@"features", @"%@ crashed the app on %ld launches in a row; it stays off", SCFeatureName(feature), (long)strikes);
        [defaults setBool:NO forKey:flagKey(feature)];
        [defaults removeObjectForKey:strikeKey(feature)];
        return NO;
    }
    // Counted as a strike until the launch is known to have survived (SCFeaturesLaunchSucceeded).
    [defaults setInteger:strikes + 1 forKey:strikeKey(feature)];
    SCGuard(feature, @"start", ^{ start(); });
    return YES;
}

void SCFeaturesLaunchSucceeded(void) {
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    for (SCFeature f = 0; f < SCFeatureCount; f++) [defaults removeObjectForKey:strikeKey(f)];
    SCLog(@"features", @"launch survived; crash counters cleared");
}

void SCGuard(SCFeature feature, NSString *what, void (^block)(void)) {
    @try {
        block();
    } @catch (NSException *exception) {
        SCLog(SCFeatureName(feature), @"%@ failed: %@ %@", what, exception.name, exception.reason);
    }
}
