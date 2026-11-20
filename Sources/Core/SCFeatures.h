#import <Foundation/Foundation.h>

// Every feature is behind a flag (NSUserDefaults "spotcloud.feature.<name>", on by default) and behind a
// crash guard: a feature that was starting when the app died three launches in a row is turned off until
// the user turns it on again in SpotCloud's settings.
typedef NS_ENUM(NSInteger, SCFeature) {
    SCFeatureJamesDSP,
    SCFeatureProbe,
    SCFeatureSearch,
    SCFeaturePlayback,
    SCFeaturePrefetch,
    SCFeatureCount
};

NSString *SCFeatureName(SCFeature feature);
BOOL SCFeatureEnabled(SCFeature feature);
void SCFeatureSetEnabled(SCFeature feature, BOOL enabled);
// Runs `start` when the feature is on and not quarantined, catching Objective-C exceptions; YES if it ran.
BOOL SCFeatureStart(SCFeature feature, void (^start)(void));
// Called once the app has stayed up long enough: clears the launch markers.
void SCFeaturesLaunchSucceeded(void);
// Runs `block`, catching Objective-C exceptions and logging them against the feature instead of crashing.
void SCGuard(SCFeature feature, NSString *what, void (^block)(void));
