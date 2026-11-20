// Toasts, and SpotCloud's settings: a three-finger double tap anywhere in Spotify opens them.
#import <UIKit/UIKit.h>
#import "../Core/SCFeatures.h"
#import "../Core/SCLog.h"
#import "../Library/SCLibrary.h"
#import "../SoundCloud/SCClient.h"

extern NSString *const SCSearchCountKey;

static UIWindow *keyWindow(void) {
    for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
        if (![scene isKindOfClass:UIWindowScene.class]) continue;
        for (UIWindow *w in ((UIWindowScene *)scene).windows) if (w.isKeyWindow) return w;
    }
    return nil;
}

void SCToast(NSString *text) {
    dispatch_async(dispatch_get_main_queue(), ^{
        UIWindow *window = keyWindow();
        if (!window) return;
        UILabel *label = [UILabel new];
        label.text = text;
        label.numberOfLines = 2;
        label.textAlignment = NSTextAlignmentCenter;
        label.font = [UIFont systemFontOfSize:14 weight:UIFontWeightSemibold];
        label.textColor = UIColor.whiteColor;
        label.backgroundColor = [UIColor colorWithWhite:0.12 alpha:0.94];
        label.layer.cornerRadius = 14;
        label.layer.masksToBounds = YES;
        CGFloat width = MIN(window.bounds.size.width - 32, 360);
        CGSize fit = [label sizeThatFits:CGSizeMake(width - 24, 60)];
        label.frame = CGRectMake((window.bounds.size.width - width) / 2, window.safeAreaInsets.top + 8, width, fit.height + 18);
        label.alpha = 0;
        [window addSubview:label];
        [UIView animateWithDuration:0.2 animations:^{ label.alpha = 1; } completion:^(BOOL done) {
            [UIView animateWithDuration:0.3 delay:2.6 options:0 animations:^{ label.alpha = 0; }
                             completion:^(BOOL finished) { [label removeFromSuperview]; }];
        }];
    });
}

static UIViewController *topController(void) {
    UIViewController *top = keyWindow().rootViewController;
    while (top.presentedViewController) top = top.presentedViewController;
    return top;
}

static void showFeatures(void);

static void showSettings(void) {
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    unsigned long long mb = SCLibrary.shared.cachedBytes / 1048576;
    NSString *message = [NSString stringWithFormat:@"SpotCloud %s\nКэш SoundCloud: %llu МБ из %ld МБ\nclient_id обновляется сам при ошибке 401.",
                         SPOTCLOUD_VERSION, mb, (long)([defaults integerForKey:SCCacheLimitKey] ?: 1024)];
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"SpotCloud" message:message preferredStyle:UIAlertControllerStyleAlert];
    [alert addTextFieldWithConfigurationHandler:^(UITextField *field) {
        field.placeholder = @"client_id (пусто = авто)";
        field.text = [defaults stringForKey:SCClientIDKey];
        field.autocorrectionType = UITextAutocorrectionTypeNo;
        field.autocapitalizationType = UITextAutocapitalizationTypeNone;
    }];
    [alert addTextFieldWithConfigurationHandler:^(UITextField *field) {
        field.placeholder = @"oauth_token (необязательно)";
        field.text = [defaults stringForKey:SCOAuthTokenKey];
        field.secureTextEntry = YES;
        field.autocorrectionType = UITextAutocorrectionTypeNo;
        field.autocapitalizationType = UITextAutocapitalizationTypeNone;
    }];
    [alert addTextFieldWithConfigurationHandler:^(UITextField *field) {
        field.placeholder = @"Лимит кэша, МБ (1024)";
        field.keyboardType = UIKeyboardTypeNumberPad;
        NSInteger limit = [defaults integerForKey:SCCacheLimitKey];
        field.text = limit ? [NSString stringWithFormat:@"%ld", (long)limit] : @"";
    }];
    [alert addAction:[UIAlertAction actionWithTitle:@"Сохранить" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
        NSString *clientID = [alert.textFields[0].text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
        NSString *token = [alert.textFields[1].text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
        if (clientID.length) [defaults setObject:clientID forKey:SCClientIDKey]; else [defaults removeObjectForKey:SCClientIDKey];
        if (token.length) [defaults setObject:token forKey:SCOAuthTokenKey]; else [defaults removeObjectForKey:SCOAuthTokenKey];
        NSInteger limit = alert.textFields[2].text.integerValue;
        if (limit >= 100) [defaults setInteger:limit forKey:SCCacheLimitKey]; else [defaults removeObjectForKey:SCCacheLimitKey];
        [SCLibrary.shared evictKeeping:nil];
        SCToast(@"SpotCloud: сохранено");
    }]];
    [alert addAction:[UIAlertAction actionWithTitle:@"Обновить client_id" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
        [SCClient.shared refreshClientID:^(NSString *clientID, NSError *error) {
            SCToast(clientID ? @"SpotCloud: client_id обновлён" : [NSString stringWithFormat:@"SpotCloud: %@", error.localizedDescription]);
        }];
    }]];
    [alert addAction:[UIAlertAction actionWithTitle:@"Функции…" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) { showFeatures(); }]];
    [alert addAction:[UIAlertAction actionWithTitle:@"Очистить кэш SoundCloud" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *a) {
        [SCLibrary.shared removeAllFiles];
        SCToast(@"SpotCloud: кэш очищен");
    }]];
    [alert addAction:[UIAlertAction actionWithTitle:@"Закрыть" style:UIAlertActionStyleCancel handler:nil]];
    [topController() presentViewController:alert animated:YES completion:nil];
}

static void showFeatures(void) {
    UIAlertController *sheet = [UIAlertController alertControllerWithTitle:@"Функции SpotCloud"
                                                                   message:@"Изменения JamesDSP и пробы — после перезапуска Spotify."
                                                            preferredStyle:UIAlertControllerStyleAlert];
    NSDictionary *names = @{@(SCFeatureJamesDSP): @"JamesDSP", @(SCFeatureSearch): @"SoundCloud в поиске",
                            @(SCFeaturePlayback): @"Воспроизведение SC", @(SCFeaturePrefetch): @"Предзагрузка очереди",
                            @(SCFeatureProbe): @"Диагностика (проба)"};
    for (SCFeature f = 0; f < SCFeatureCount; f++) {
        BOOL on = SCFeatureEnabled(f);
        NSString *title = [NSString stringWithFormat:@"%@ %@", on ? @"✓" : @"✗", names[@(f)] ?: SCFeatureName(f)];
        [sheet addAction:[UIAlertAction actionWithTitle:title style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
            SCFeatureSetEnabled(f, !on);
            showFeatures();
        }]];
    }
    [sheet addAction:[UIAlertAction actionWithTitle:@"Готово" style:UIAlertActionStyleCancel handler:nil]];
    [topController() presentViewController:sheet animated:YES completion:nil];
}

@interface SCGestureTarget : NSObject
@end
@implementation SCGestureTarget
- (void)open:(UITapGestureRecognizer *)gesture {
    if (gesture.state == UIGestureRecognizerStateRecognized) showSettings();
}
@end

static SCGestureTarget *gTarget;

static void attach(UIWindow *window) {
    if (!window || [window isKindOfClass:NSClassFromString(@"UITextEffectsWindow")]) return;
    for (UIGestureRecognizer *g in window.gestureRecognizers) if (g.delegate == nil && [g.name isEqualToString:@"spotcloud"]) return;
    UITapGestureRecognizer *tap = [[UITapGestureRecognizer alloc] initWithTarget:gTarget action:@selector(open:)];
    tap.numberOfTouchesRequired = 3;
    tap.numberOfTapsRequired = 2;
    tap.cancelsTouchesInView = NO;
    tap.name = @"spotcloud";
    [window addGestureRecognizer:tap];
}

void SCUIStart(void) {
    gTarget = [SCGestureTarget new];
    [NSNotificationCenter.defaultCenter addObserverForName:UIWindowDidBecomeKeyNotification object:nil queue:NSOperationQueue.mainQueue
                                                usingBlock:^(NSNotification *note) { attach(note.object); }];
    dispatch_async(dispatch_get_main_queue(), ^{ attach(keyWindow()); });
}
