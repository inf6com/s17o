#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Wraps system APIs whose completion handlers are annotated @MainActor in the
/// macOS 26 SDK but are delivered on XPC threads at runtime.  All callbacks
/// are dispatched to the main queue before being forwarded to Swift.
@interface SafariBridge : NSObject

// MARK: - SafariServices
+ (void)getExtensionStateForIdentifier:(NSString *)identifier
                            completion:(void (^)(BOOL isEnabled, NSError * _Nullable error))completion;

+ (void)showPreferencesForIdentifier:(NSString *)identifier
                          completion:(void (^)(NSError * _Nullable error))completion;

+ (void)dispatchMessageWithName:(NSString *)messageName
        toExtensionWithIdentifier:(NSString *)identifier
                         userInfo:(nullable NSDictionary<NSString *, id> *)userInfo
                       completion:(void (^)(NSError * _Nullable error))completion;

+ (void)getTabCatalogWithCompletion:(void (^)(NSArray<NSDictionary<NSString *, id> *> * _Nullable tabs,
                                              NSError * _Nullable error))completion;

// MARK: - Speech
/// Requests on-device speech recognition authorization.
/// `status` is the raw NSInteger value of SFSpeechRecognizerAuthorizationStatus.
+ (void)requestSpeechAuthorizationWithCompletion:(void (^)(NSInteger status))completion;

// MARK: - UserNotifications
/// Requests notification authorization with the given options bitmask.
/// `granted` is YES when permission was granted; error is non-nil on failure.
+ (void)requestNotificationAuthorizationWithOptions:(NSUInteger)options
                                         completion:(void (^)(BOOL granted, NSError * _Nullable error))completion;

@end

NS_ASSUME_NONNULL_END
