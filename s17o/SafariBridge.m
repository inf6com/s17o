#import "SafariBridge.h"
@import SafariServices;
@import Speech;
@import UserNotifications;

@implementation SafariBridge

// MARK: - SafariServices

+ (void)getExtensionStateForIdentifier:(NSString *)identifier
                            completion:(void (^)(BOOL isEnabled, NSError * _Nullable error))completion {
    [SFSafariExtensionManager getStateOfSafariExtensionWithIdentifier:identifier
                                                    completionHandler:^(SFSafariExtensionState * _Nullable state,
                                                                        NSError * _Nullable error) {
        BOOL enabled = (error == nil) && (state != nil) && state.isEnabled;
        dispatch_async(dispatch_get_main_queue(), ^{
            completion(enabled, error);
        });
    }];
}

+ (void)showPreferencesForIdentifier:(NSString *)identifier
                          completion:(void (^)(NSError * _Nullable error))completion {
    [SFSafariApplication showPreferencesForExtensionWithIdentifier:identifier
                                                 completionHandler:^(NSError * _Nullable error) {
        dispatch_async(dispatch_get_main_queue(), ^{
            completion(error);
        });
    }];
}

+ (void)dispatchMessageWithName:(NSString *)messageName
        toExtensionWithIdentifier:(NSString *)identifier
                         userInfo:(NSDictionary<NSString *,id> * _Nullable)userInfo
                       completion:(void (^)(NSError * _Nullable error))completion {
    [SFSafariApplication dispatchMessageWithName:messageName
                         toExtensionWithIdentifier:identifier
                                         userInfo:userInfo
                                completionHandler:^(NSError * _Nullable error) {
        dispatch_async(dispatch_get_main_queue(), ^{
            completion(error);
        });
    }];
}

+ (void)getTabCatalogWithCompletion:(void (^)(NSArray<NSDictionary<NSString *, id> *> * _Nullable tabs,
                                              NSError * _Nullable error))completion {
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSString *source = @"on run\n"
                            "    set itemSeparator to character id 31\n"
                            "    set rowSeparator to character id 30\n"
                            "    set rows to {}\n"
                            "    tell application \"Safari\"\n"
                            "        repeat with windowIndex from 1 to count of windows\n"
                            "            set w to window windowIndex\n"
                            "            set currentTabIndex to index of current tab of w\n"
                            "            set orderedTabIndexes to {currentTabIndex}\n"
                            "            repeat with tabIndex from 1 to count of tabs of w\n"
                            "                if tabIndex is not currentTabIndex then\n"
                            "                    set end of orderedTabIndexes to tabIndex\n"
                            "                end if\n"
                            "            end repeat\n"
                            "            repeat with orderedTabIndex in orderedTabIndexes\n"
                            "                set tabIndex to orderedTabIndex as integer\n"
                            "                set t to tab tabIndex of w\n"
                            "                set tabTitle to name of t\n"
                            "                set tabURL to URL of t\n"
                            "                if tabURL is not missing value and tabURL is not \"\" then\n"
                            "                    set end of rows to ((windowIndex as text) & itemSeparator & (tabIndex as text) & itemSeparator & (tabTitle as text) & itemSeparator & (tabURL as text))\n"
                            "                end if\n"
                            "            end repeat\n"
                            "        end repeat\n"
                            "    end tell\n"
                            "    set AppleScript's text item delimiters to rowSeparator\n"
                            "    set outputText to rows as text\n"
                            "    set AppleScript's text item delimiters to \"\"\n"
                            "    return outputText\n"
                            "end run";

        NSDictionary *errorInfo = nil;
        NSAppleScript *script = [[NSAppleScript alloc] initWithSource:source];
        NSAppleEventDescriptor *result = [script executeAndReturnError:&errorInfo];

        NSMutableArray<NSDictionary<NSString *, id> *> *catalog = [NSMutableArray array];
        NSError *resolvedError = nil;

        if (result == nil) {
            NSString *message = errorInfo[NSAppleScriptErrorMessage];
            if (message.length == 0) {
                message = @"Safari のタブ一覧を取得できませんでした。";
            }
            resolvedError = [NSError errorWithDomain:@"SafariBridge"
                                                code:1
                                            userInfo:@{ NSLocalizedDescriptionKey: message }];
        } else {
            NSString *output = result.stringValue ?: @"";
            NSString *itemSeparator = [NSString stringWithFormat:@"%C", 31];
            NSString *rowSeparator = [NSString stringWithFormat:@"%C", 30];
            NSArray<NSString *> *rows = [output componentsSeparatedByString:rowSeparator];

            for (NSString *row in rows) {
                if (row.length == 0) {
                    continue;
                }

                NSArray<NSString *> *columns = [row componentsSeparatedByString:itemSeparator];
                if (columns.count != 4) {
                    continue;
                }

                NSInteger windowIndex = columns[0].integerValue;
                NSInteger tabIndex = columns[1].integerValue;
                NSString *title = columns[2];
                NSString *url = columns[3];
                if (windowIndex <= 0 || tabIndex <= 0 || url.length == 0) {
                    continue;
                }

                [catalog addObject:@{
                    @"id": @((windowIndex << 16) | tabIndex),
                    @"windowIndex": @(windowIndex),
                    @"tabIndex": @(tabIndex),
                    @"title": title,
                    @"url": url,
                    @"active": @(tabIndex == 1),
                    @"isFocusedWindow": @(windowIndex == 1)
                }];
            }
        }

        dispatch_async(dispatch_get_main_queue(), ^{
            completion(resolvedError == nil ? [catalog copy] : nil, resolvedError);
        });
    });
}

// MARK: - Speech

+ (void)requestSpeechAuthorizationWithCompletion:(void (^)(NSInteger status))completion {
    [SFSpeechRecognizer requestAuthorization:^(SFSpeechRecognizerAuthorizationStatus status) {
        dispatch_async(dispatch_get_main_queue(), ^{
            completion((NSInteger)status);
        });
    }];
}

// MARK: - UserNotifications

+ (void)requestNotificationAuthorizationWithOptions:(NSUInteger)options
                                         completion:(void (^)(BOOL granted, NSError * _Nullable error))completion {
    UNUserNotificationCenter *center = [UNUserNotificationCenter currentNotificationCenter];
    [center requestAuthorizationWithOptions:(UNAuthorizationOptions)options
                          completionHandler:^(BOOL granted, NSError * _Nullable error) {
        dispatch_async(dispatch_get_main_queue(), ^{
            completion(granted, error);
        });
    }];
}

@end
