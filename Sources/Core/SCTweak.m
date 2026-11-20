// SpotCloud's entry point: starts each feature behind its flag and crash guard.
#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import "SCFeatures.h"
#import "SCLog.h"

void SCJamesDSPStart(void);
void SCProbeStart(void);

__attribute__((constructor)) static void SCTweakInit(void) {
    @autoreleasepool {
        NSString *bundle = NSBundle.mainBundle.bundleIdentifier;
        // Extensions (widgets, notifications) load injected dylibs too; SpotCloud is for the app only.
        if (![bundle isEqualToString:@"com.spotify.client"]) return;
        SCLog(@"tweak", @"SpotCloud %s loaded in Spotify %@", SPOTCLOUD_VERSION,
              NSBundle.mainBundle.infoDictionary[@"CFBundleShortVersionString"]);
        // Before Spotify starts its audio output, so the AudioOutputUnitStart import is repointed in time.
        SCFeatureStart(SCFeatureJamesDSP, ^{ SCJamesDSPStart(); });
        SCFeatureStart(SCFeatureProbe, ^{ SCProbeStart(); });
        // Search, playback and prefetch arrive with stage 1-4 builds.
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 20 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
            SCFeaturesLaunchSucceeded();
        });
    }
}
