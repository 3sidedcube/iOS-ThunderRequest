#import "TSCRequestController.h"
#import "TSCRequest.h"
#import "TSCRequestResponse.h"
#import "TSCErrorRecoveryAttempter.h"
#import "TSCErrorRecoveryOption.h"
#import "TSCRequestCredential.h"
#import "NSURLSession+Synchronous.h"
#import "NSThread+Blocks.h"
#import "TSCOAuth2Credential.h"
#import "TSCRequest+TaskIdentifier.h"
#import <objc/runtime.h>

@import os.log;

#if TARGET_OS_IOS
#import <ThunderRequest/ThunderRequest-Swift.h>
#endif

static os_log_t request_controller_log;

@interface TSCRequestController ()

/**
 @abstract The operation queue that contains all requests added to a default session
 */
@property (nonatomic, strong) NSOperationQueue *defaultRequestQueue;

/**
 @abstract The operation queue that contains all requests added to a background session
 */
@property (nonatomic, strong) NSOperationQueue *backgroundRequestQueue;

/**
 @abstract The operation queue that contains all requests added to a ephemeral session
 */
@property (nonatomic, strong) NSOperationQueue *ephemeralRequestQueue;

/**
 @abstract Uses persistent disk-based cache and stores credentials in the user's keychain
 */
@property (nonatomic, strong) NSURLSession *defaultSession;

/**
 @abstract Does not store any data on the disk; all caches, credential stores, and so on are kept in the RAM and tied to the session. Thus, when invalidated, they are purged automatically.
 */
@property (nonatomic, strong) NSURLSession *backgroundSession;

/**
 @abstract Similar to a default session, except that a seperate process handles all data transfers. Background sessions have some additional limitations.
 */
@property (nonatomic, strong) NSURLSession *ephemeralSession;

/**
 @abstract A dictionary of completion handlers to be called when file downloads are complete
 */
@property (nonatomic, strong) NSMutableDictionary *completionHandlerDictionary;

/**
 @abstract Whether we are currently re-authenticating or not
 */
@property (nonatomic, assign) BOOL reAuthenticating;

/**
 @abstract An array of TSCRequest objects which are waiting for re-authentication to complete
 */
@property (nonatomic, strong) NSMutableArray *authQueuedRequests;

/**
 @abstract A dictionary representing any re-direct responses provided with a redirect request
 @discussion These will be added onto the TSCRequestResponse object of the re-directed request, they are stored in this request under the request object itself
 */
@property (nonatomic, strong) NSMutableDictionary *redirectResponses;

@end

@implementation TSCRequestController

// Set up the logging component before it's used.
+ (void)initialize {
    request_controller_log = os_log_create("com.threesidedcube.ThunderRequest", "TSCRequestController");
}

- (void)TSC_fireRequestCompletionWithData:(NSData *)data response:(NSURLResponse *)response error:(NSError *)error request:(TSCRequest *)request completion:(TSCRequestCompletionHandler)completion
{
	TSCRequestResponse *requestResponse = [[TSCRequestResponse alloc] initWithResponse:response data:data];
	
	if (request.taskIdentifier && self.redirectResponses[@(request.taskIdentifier)]) {
		requestResponse.redirectResponse = self.redirectResponses[@(request.taskIdentifier)];
		[self.redirectResponses removeObjectForKey:@(request.taskIdentifier)];
	}
	
	NSMutableDictionary *requestInfo = [NSMutableDictionary new];
	if (request) {
		requestInfo[TSCRequestNotificationRequestKey] = request;
	}
	if (response) {
		requestInfo[TSCRequestNotificationResponseKey] = requestResponse;
	}
	
	//Notify of response
	[[NSNotificationCenter defaultCenter] postNotificationName:TSCRequestDidReceiveResponse object:requestResponse userInfo:requestInfo];
	
	//Notify of errors
	if ([self statusCodeIsConsideredHTTPError:requestResponse.status]) {
		[[NSNotificationCenter defaultCenter] postNotificationName:TSCRequestServerError object:requestResponse userInfo:requestInfo];
	}
	
	if (error || [self statusCodeIsConsideredHTTPError:requestResponse.status]) {
		
		TSCErrorRecoveryAttempter *recoveryAttempter = [TSCErrorRecoveryAttempter new];
		
		[recoveryAttempter addOption:[TSCErrorRecoveryOption optionWithTitle:@"Retry" type:TSCErrorRecoveryOptionTypeRetry handler:^(TSCErrorRecoveryOption *option) {
			
			[self scheduleRequest:request completion:completion];
			
		}]];
		
		[recoveryAttempter addOption:[TSCErrorRecoveryOption optionWithTitle:@"Cancel" type:TSCErrorRecoveryOptionTypeCancel handler:nil]];
		
		dispatch_queue_t callbackQueue = self.callbackQueue != NULL ? self.callbackQueue : dispatch_get_main_queue();
		dispatch_async(callbackQueue, ^{

			if (error) {
				completion(requestResponse, [recoveryAttempter recoverableErrorWithError:error]);
			} else {
				
				NSError *httpError = [NSError errorWithDomain:TSCRequestErrorDomain code:requestResponse.status userInfo:@{NSLocalizedDescriptionKey: [NSHTTPURLResponse localizedStringForStatusCode:requestResponse.status]}];
				completion(requestResponse, [recoveryAttempter recoverableErrorWithError:httpError]);
			}
		});
		
	} else {
		
		dispatch_queue_t callbackQueue = self.callbackQueue != NULL ? self.callbackQueue : dispatch_get_main_queue();
		dispatch_async(callbackQueue, ^{
			completion(requestResponse, error);
		});
	}
	
	//Log
	
	if (error) {
		os_log_debug(request_controller_log, "Request:%@", request);
		os_log_error(request_controller_log, "\nURL: %@\nMethod: %@\nRequest Headers:%@\nBody: %@\n\nResponse Status: FAILURE \nError Description: %@",request.URL, request.HTTPMethod, request.allHTTPHeaderFields, [[NSString alloc] initWithData:request.HTTPBody encoding:NSUTF8StringEncoding], error.localizedDescription );
	} else {
		
		os_log_debug(request_controller_log, "\nURL: %@\nMethod: %@\nRequest Headers:%@\nBody: %@\n\nResponse Status: %li\nResponse Body: %@\n", request.URL, request.HTTPMethod, request.allHTTPHeaderFields, [[NSString alloc] initWithData:request.HTTPBody encoding:NSUTF8StringEncoding], (long)requestResponse.status, requestResponse.string);
	}
}

#pragma mark - Request scheduling

- (void)scheduleDownloadRequest:(TSCRequest *)request on:(NSDate *)beginDate progress:(TSCRequestProgressHandler)progress completion:(TSCRequestTransferCompletionHandler)completion
{
	
}

- (void)scheduleUploadRequest:(nonnull TSCRequest *)request on:(NSDate *)beginDate filePath:(NSString *)filePath progress:(nullable TSCRequestProgressHandler)progress completion:(nonnull TSCRequestTransferCompletionHandler)completion
{
	
}

- (void)scheduleRequest:(TSCRequest *)request completion:(TSCRequestCompletionHandler)completion
{
	
}

#pragma mark - NSURLSession challenge handling

#pragma mark - NSURLSessionDownloadDelegate

#pragma mark - NSURLSessionUploadDelegate

#pragma mark - NSURLSessionDownload completion handling

- (void)addCompletionHandler:(TSCRequestTransferCompletionHandler)handler progressHandler:(TSCRequestProgressHandler)progress forTaskIdentifier:(NSUInteger)identifier
{
	
}

#pragma mark - Error handling

- (BOOL)statusCodeIsConsideredHTTPError:(NSInteger)statusCode
{
	if (statusCode >= 400 && statusCode < 600) {
		
		return true;
	}
	
	return false;
}

#pragma mark - OAuth2 Flow

- (void)setOAuth2Delegate:(id<TSCOAuth2Manager>)OAuth2Delegate
{
	_OAuth2Delegate = OAuth2Delegate;
	
	if (!OAuth2Delegate) {
		self.OAuth2RequestController = nil;
	}
	
	if (!OAuth2Delegate) {
		return;
	}
	
	TSCOAuth2Credential *credential = (TSCOAuth2Credential *)[TSCOAuth2Credential retrieveCredentialWithIdentifier:[OAuth2Delegate authIdentifier]];
	if (credential) {
		self.sharedRequestCredential = credential;
	}
}

- (TSCRequestController *)OAuth2RequestController
{
	if (!_OAuth2RequestController) {
//        _OAuth2RequestController = [[TSCRequestController alloc] initWithBaseURL:self.sharedBaseURL];
	}
	
	return _OAuth2RequestController;
}

- (void)setSharedRequestCredential:(TSCRequestCredential *)credential andSaveToKeychain:(BOOL)save
{
	_sharedRequestCredential = credential;
	
	if ([_sharedRequestCredential isKindOfClass:[TSCOAuth2Credential class]]) {
		
		TSCOAuth2Credential *OAuthCredential = (TSCOAuth2Credential *)_sharedRequestCredential;
		self.sharedRequestHeaders[@"Authorization"] = [NSString stringWithFormat:@"%@ %@", OAuthCredential.tokenType, OAuthCredential.authorizationToken];
	}
	
	if (save) {
		[[credential class] storeCredential:credential withIdentifier: self.OAuth2Delegate ? [self.OAuth2Delegate authIdentifier] : [NSString stringWithFormat:@"thundertable.com.threesidedcube-%@", self.sharedBaseURL]];
	}
}

- (void)setSharedRequestCredential:(TSCRequestCredential *)sharedRequestCredential
{
	[self setSharedRequestCredential:sharedRequestCredential andSaveToKeychain:false];
}

#if !TARGET_OS_OSX
- (void)URLSessionDidFinishEventsForBackgroundURLSession:(NSURLSession *)session
{
    os_log_debug(request_controller_log, "finished events for bg session");
}
#endif

#pragma mark - Request conversion

- (NSMutableURLRequest *)backgroundableRequestObjectFromTSCRequest:(TSCRequest *)tscRequest
{
	NSMutableURLRequest *backgroundableRequest = [NSMutableURLRequest new];
	backgroundableRequest.URL = tscRequest.URL;
	backgroundableRequest.HTTPMethod = [tscRequest stringForHTTPMethod:tscRequest.requestHTTPMethod];
	backgroundableRequest.HTTPBody = tscRequest.HTTPBody;
	
	for (NSString *key in [tscRequest.requestHeaders allKeys]) {
		[backgroundableRequest setValue:tscRequest.requestHeaders[key] forHTTPHeaderField:key];
	}
	
	return backgroundableRequest;
}

@end
