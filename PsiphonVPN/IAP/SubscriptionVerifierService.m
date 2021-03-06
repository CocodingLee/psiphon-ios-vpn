/*
 * Copyright (c) 2018, Psiphon Inc.
 * All rights reserved.
 *
 * This program is free software: you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation, either version 3 of the License, or
 * (at your option) any later version.
 *
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU General Public License for more details.
 *
 * You should have received a copy of the GNU General Public License
 * along with this program.  If not, see <http://www.gnu.org/licenses/>.
 *
 */

#import <Foundation/Foundation.h>
#import <ReactiveObjC/RACDisposable.h>
#import <ReactiveObjC/RACScheduler.h>
#import "AppProfiler.h"
#import "SubscriptionVerifierService.h"
#import "NSDate+Comparator.h"
#import "NSError+Convenience.h"
#import "RACTuple.h"
#import "PsiFeedbackLogger.h"
#import "Logging.h"
#import "Asserts.h"
#import "RACCompoundDisposable.h"
#import "PsiphonDataSharedDB.h"
#import "SharedConstants.h"
#import "SubscriptionData.h"

NSErrorDomain _Nonnull const ReceiptValidationErrorDomain = @"PsiphonReceiptValidationErrorDomain";

PsiFeedbackLogType const SubscriptionVerifierServiceLogType = @"SubscriptionVerifierService";

@implementation SubscriptionVerifierService {
    NSURLSession *urlSession;
}

+ (RACSignal<NSNumber *> *_Nonnull)localSubscriptionCheck {
    return [RACSignal createSignal:^RACDisposable *(id <RACSubscriber> subscriber) {
        MutableSubscriptionData *subscription = [MutableSubscriptionData fromPersistedDefaults];
        if ([subscription shouldUpdateAuthorization]) {
            // subscription server needs to be contacted.
            [subscriber sendNext:@(SubscriptionCheckShouldUpdateAuthorization)];
            [subscriber sendCompleted];
        } else {
            // subscription server doesn't need to be contacted.
            // Checks if subscription is active compared to device's clock.
            if ([subscription hasActiveAuthorizationForDate:[NSDate date]]) {
                [subscriber sendNext:@(SubscriptionCheckHasActiveAuthorization)];
                [subscriber sendCompleted];
            } else {
                // Send error, subscription has expired.
                [subscriber sendNext:@(SubscriptionCheckAuthorizationExpired)];
                [subscriber sendCompleted];
            }
        }

        return nil;
    }];
}

+ (RACSignal<RACTwoTuple<NSDictionary *, NSNumber *> *> *)updateAuthorizationFromRemote {
    return [RACSignal createSignal:^RACDisposable *(id <RACSubscriber> subscriber) {

        // This object holds a reference to the current scheduler, in order to schedule
        // the events sent to the subscriber on the same scheduler it is subscribed on,
        // since the callback from `SubscriptionVerifierService startWithCompletionHandler`
        // is executed on an operation queue managed by the system.
        PSIAssert(RACScheduler.currentScheduler != nil);
        RACScheduler *scheduler = RACScheduler.currentScheduler;

        RACCompoundDisposable *compoundDisposable = [RACCompoundDisposable compoundDisposable];

        SubscriptionVerifierService *service = [[SubscriptionVerifierService alloc] init];
        [service startWithCompletionHandler:^(NSDictionary *remoteAuthDict, NSNumber *submittedReceiptFileSize, NSError *error) {

            // Schedule subscription events on the same scheduler this signal was subscribed on.
            RACDisposable *schedulingDisposable = [scheduler schedule:^{
                if (error) {
                    [subscriber sendError:error];
                } else {
                    [subscriber sendNext:[RACTwoTuple pack:remoteAuthDict :submittedReceiptFileSize]];
                    [subscriber sendCompleted];
                }
            }];

            [compoundDisposable addDisposable:schedulingDisposable];
        }];

        [compoundDisposable addDisposable:[RACDisposable disposableWithBlock:^{
            @autoreleasepool {
                [service cancel];
            }
        }]];

        return compoundDisposable;
    }];
}

/**
 * Starts asynchronous task that upload current App Store receipt file to the subscription verifier server,
 * and calls receiptUploadCompletionHandler with the response from the server.
 * @param receiptUploadCompletionHandler Completion handler called with the result of the network request.
 * @details Note that the completion handler is called from a queue handled by the system.
 */
- (void)startWithCompletionHandler:(SubscriptionVerifierCompletionHandler _Nonnull)receiptUploadCompletionHandler {
    NSMutableURLRequest *request;

    [AppProfiler logMemoryReportWithTag:@"SubscriptionVerifierSubmitAuthRequest"];

    // Open a connection for the URL, configured to POST the file.

    request = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:kRemoteVerificationURL]];

    NSNumber *appReceiptFileSize;
    [[NSBundle mainBundle].appStoreReceiptURL getResourceValue:&appReceiptFileSize forKey:NSURLFileSizeKey error:nil];

    [request setHTTPBodyStream:[NSInputStream inputStreamWithURL:NSBundle.mainBundle.appStoreReceiptURL]];
    [request setHTTPMethod:@"POST"];
    [request setValue:@"application/octet-stream" forHTTPHeaderField:@"Content-Type"];

    NSURLSessionConfiguration *sessionConfig = [NSURLSessionConfiguration ephemeralSessionConfiguration];
    sessionConfig.timeoutIntervalForRequest = kReceiptRequestTimeOutSeconds;

    urlSession = [NSURLSession sessionWithConfiguration:sessionConfig];

    NSURLSessionDataTask *postDataTask = [urlSession dataTaskWithRequest:request completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {

        [AppProfiler logMemoryReportWithTag:@"SubscriptionVerifierLoadRequestCompleted"];
        [PsiFeedbackLogger infoWithType:SubscriptionVerifierServiceLogType message:@"load request completed"];

        // Session is no longer needed, invalidates and cancels outstanding tasks.
        [urlSession invalidateAndCancel];

        if (error) {
            NSDictionary *errorDict = @{NSLocalizedDescriptionKey: @"NSURLSession error", NSUnderlyingErrorKey: error};
            NSError *err = [[NSError alloc] initWithDomain:ReceiptValidationErrorDomain code:PsiphonReceiptValidationErrorNSURLSessionFailed userInfo:errorDict];
            receiptUploadCompletionHandler(nil, appReceiptFileSize, err);
            return;
        }

        NSHTTPURLResponse *httpResponse = (NSHTTPURLResponse *) response;
        if (httpResponse.statusCode != 200) {
            NSString *description = [NSString stringWithFormat:@"HTTP code: %ld", (long) httpResponse.statusCode];
            NSDictionary *errorDict = @{NSLocalizedDescriptionKey: description};
            NSError *err = [[NSError alloc] initWithDomain:ReceiptValidationErrorDomain code:PsiphonReceiptValidationErrorHTTPFailed userInfo:errorDict];
            receiptUploadCompletionHandler(nil, appReceiptFileSize, err);
            return;
        }

        if (data.length == 0) {
            NSDictionary *errorDict = @{NSLocalizedDescriptionKey: @"Empty server response"};
            NSError *err = [[NSError alloc] initWithDomain:ReceiptValidationErrorDomain code:PsiphonReceiptValidationErrorInvalidReceipt userInfo:errorDict];
            receiptUploadCompletionHandler(nil, appReceiptFileSize, err);
            return;
        }

        NSError *jsonError;
        NSDictionary *dict = [NSJSONSerialization JSONObjectWithData:data options:kNilOptions error:&jsonError];

        if (jsonError) {
            NSDictionary *errorDict = @{NSLocalizedDescriptionKey:@"JSON parse failure", NSUnderlyingErrorKey:jsonError};
            NSError *err = [[NSError alloc] initWithDomain:ReceiptValidationErrorDomain code:PsiphonReceiptValidationErrorJSONParseFailed userInfo:errorDict];
            receiptUploadCompletionHandler(nil, appReceiptFileSize, err);
            return;
        }

        receiptUploadCompletionHandler(dict, appReceiptFileSize, nil);
    }];

    [postDataTask resume];

    [AppProfiler logMemoryReportWithTag:@"SubscriptionVerifierAuthRequestSubmitted"];
    [PsiFeedbackLogger infoWithType:SubscriptionVerifierServiceLogType message:@"authorization request submitted"];

}

- (void)cancel {
    [urlSession invalidateAndCancel];
}

@end



#pragma mark - Subscription Result Model

NSErrorDomain _Nonnull const SubscriptionResultErrorDomain = @"SubscriptionResultErrorDomain";

@interface SubscriptionResultModel ()

@property (nonatomic, readwrite, assign) BOOL inProgress;

/** Error with domain SubscriptionResultErrorDomain */
@property (nonatomic, readwrite, nullable) NSError *error;

@property (nonatomic, readwrite, nullable) NSDictionary *remoteAuthDict;

@property (nonatomic, readwrite, nullable) NSNumber *submittedReceiptFileSize;

@end

@implementation SubscriptionResultModel

+ (SubscriptionResultModel *_Nonnull)inProgress {
    SubscriptionResultModel *instance = [[SubscriptionResultModel alloc] init];
    instance.inProgress = TRUE;
    instance.error = nil;
    instance.remoteAuthDict = nil;
    instance.submittedReceiptFileSize = nil;
    return instance;
}

+ (SubscriptionResultModel *)failed:(SubscriptionResultErrorCode)errorCode {
    SubscriptionResultModel *instance = [[SubscriptionResultModel alloc] init];
    instance.inProgress = FALSE;
    instance.error = [NSError errorWithDomain:SubscriptionResultErrorDomain code:errorCode];
    instance.remoteAuthDict = nil;
    instance.submittedReceiptFileSize = nil;
    return instance;
}

+ (SubscriptionResultModel *)success:(NSDictionary *_Nullable)remoteAuthDict receiptFileSize:(NSNumber *_Nullable)receiptFileSize {
    SubscriptionResultModel *instance = [[SubscriptionResultModel alloc] init];
    instance.inProgress = FALSE;
    instance.error = nil;
    instance.remoteAuthDict = remoteAuthDict;
    instance.submittedReceiptFileSize = receiptFileSize;
    return instance;
}

@end

#pragma mark - Subscription state

typedef NS_ENUM(NSInteger, SubscriptionStateEnum) {
    SubscriptionStateNotSubscribed = 1,
    SubscriptionStateInProgress = 2,
    SubscriptionStateSubscribed = 3,
};

@implementation SubscriptionState {
    NSObject *_lock;
    SubscriptionStateEnum _state;
}

+ (SubscriptionState *_Nonnull)initialStateFromSubscription:(MutableSubscriptionData *)subscription {
    SubscriptionState *instance = [[SubscriptionState alloc] init];
    instance.state = SubscriptionStateNotSubscribed;

    if ([subscription hasActiveSubscriptionForNow]) {
        instance.state = SubscriptionStateSubscribed;

    } else if ([subscription shouldUpdateAuthorization]) {
        instance.state = SubscriptionStateInProgress;
    }

    return instance;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _lock = [[NSObject alloc] init];
    }
    return self;
}

- (void)setState:(SubscriptionStateEnum)newState {
    @synchronized (_lock) {
        _state = newState;
    }
}

- (SubscriptionStateEnum)state {
    @synchronized (_lock) {
        PSIAssert(_state != 0);
        return _state;
    }
}

- (BOOL)isSubscribedOrInProgress {
    return self.state != SubscriptionStateNotSubscribed;
}

- (BOOL)isSubscribed {
    return self.state == SubscriptionStateSubscribed;
}

- (BOOL)isInProgress {
   return self.state == SubscriptionStateInProgress;
}

- (void)setStateSubscribed {
    self.state = SubscriptionStateSubscribed;
}

- (void)setStateInProgress {
    self.state = SubscriptionStateInProgress;
}

- (void)setStateNotSubscribed {
    self.state = SubscriptionStateNotSubscribed;
}

- (NSString *_Nonnull)textDescription {
    switch (self.state) {
        case SubscriptionStateNotSubscribed: return @"NotSubscribed";
        case SubscriptionStateInProgress: return @"InProgress";
        case SubscriptionStateSubscribed: return @"Subscribed";
    }
    return @"";
}

@end
