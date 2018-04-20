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

static NSString * const TSCQueuedRequestKey = @"TSC_REQUEST";
static NSString * const TSCQueuedCompletionKey = @"TSC_REQUEST_COMPLETION";

static os_log_t request_controller_log;

@interface NSURLSessionTask (Request)

@property (nonatomic, strong) TSCRequest *request;

@end

@implementation NSURLSessionTask (Request)

static char requestKey;

- (TSCRequest *)request
{
    return objc_getAssociatedObject(self, &requestKey);
}

- (void)setRequest:(TSCRequest *)request
{
    objc_setAssociatedObject(self, &requestKey, request, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

@end

typedef void (^TSCOAuth2CheckCompletion) (BOOL authenticated, NSError *authError, BOOL needsQueueing);

@interface TSCRequestController () <NSURLSessionDownloadDelegate, NSURLSessionTaskDelegate>

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

- (instancetype)init
{
    self = [super init];
    if (self) {
		
        self.sharedRequestHeaders = [NSMutableDictionary dictionary];

        self.authQueuedRequests = [NSMutableArray new];
        self.redirectResponses = [NSMutableDictionary new];
        
        [self resetAllSessions];
    }
    return self;
}

- (void)resetAllSessions
{
    self.defaultRequestQueue = [NSOperationQueue new];
    self.backgroundRequestQueue = [NSOperationQueue new];
    self.ephemeralRequestQueue = [NSOperationQueue new];
    
    NSURLSessionConfiguration *defaultConfigObject = [NSURLSessionConfiguration defaultSessionConfiguration];
    NSURLSessionConfiguration *backgroundConfigObject = [NSURLSessionConfiguration backgroundSessionConfigurationWithIdentifier:[[NSUUID UUID] UUIDString]];
    NSURLSessionConfiguration *ephemeralConfigObject = [NSURLSessionConfiguration ephemeralSessionConfiguration];
    
    self.defaultSession = [NSURLSession sessionWithConfiguration:defaultConfigObject delegate:self delegateQueue:self.defaultRequestQueue];
    self.backgroundSession = [NSURLSession sessionWithConfiguration:backgroundConfigObject delegate:self delegateQueue:self.backgroundRequestQueue];
    self.ephemeralSession = [NSURLSession sessionWithConfiguration:ephemeralConfigObject delegate:nil delegateQueue:self.ephemeralRequestQueue];
    
    self.completionHandlerDictionary = [NSMutableDictionary dictionary];

}

- (void)cancelAllRequests
{
    [self.defaultSession invalidateAndCancel];
    [self.backgroundSession invalidateAndCancel];
    [self.ephemeralSession invalidateAndCancel];
    
    [self resetAllSessions];
}

- (void)cancelRequestsWithTag:(NSInteger)tag
{
    [self.defaultSession getAllTasksWithCompletionHandler:^(NSArray<__kindof NSURLSessionTask *> * _Nonnull tasks) {
        
        for (NSURLSessionTask *task in tasks) {
            
            if (task.request && task.request.tag == tag) {
                [task cancel];
            }
        }
    }];
    
    [self.backgroundSession getAllTasksWithCompletionHandler:^(NSArray<__kindof NSURLSessionTask *> * _Nonnull tasks) {
        
        for (NSURLSessionTask *task in tasks) {
            
            if (task.request && task.request.tag == tag) {
                [task cancel];
            }
        }
    }];
    
    [self.ephemeralSession getAllTasksWithCompletionHandler:^(NSArray<__kindof NSURLSessionTask *> * _Nonnull tasks) {
        
        for (NSURLSessionTask *task in tasks) {
            
            if (task.request && task.request.tag == tag) {
                [task cancel];
            }
        }
    }];
}

+ (void)setUserAgent:(NSString *)userAgent
{
	if (userAgent) {
		[[NSUserDefaults standardUserDefaults] setValue:userAgent forKey:@"TSCUserAgent"];
	} else {
		[[NSUserDefaults standardUserDefaults] removeObjectForKey:@"TSCUserAgent"];
	}
}

- (nonnull instancetype)initWithBaseURL:(nullable NSURL *)baseURL
{
	self = [self init];
	if (self) {
		
		if ([baseURL.absoluteString hasSuffix:@"/"]) {
			self.sharedBaseURL = baseURL;
		} else {
			self.sharedBaseURL = [NSURL URLWithString:[baseURL.absoluteString stringByAppendingString:@"/"]];
		}
		
		self.sharedRequestCredential = [TSCRequestCredential retrieveCredentialWithIdentifier:[NSString stringWithFormat:@"thundertable.com.threesidedcube-%@", self.sharedBaseURL]];
	}
	return self;
}

- (nonnull instancetype)initWithBaseAddress:(nullable NSString *)baseAddress
{
	return [self initWithBaseURL:[NSURL URLWithString:baseAddress]];
}

#pragma mark - GET Requests

- (nonnull TSCRequest *)get:(nonnull NSString *)path completion:(nonnull TSCRequestCompletionHandler)completion
{
	return [self get:path withURLParamDictionary:nil completion:completion];
}

- (nonnull TSCRequest *)get:(nonnull NSString *)path withURLParamDictionary:(nullable NSDictionary *)URLParamDictionary completion:(nonnull TSCRequestCompletionHandler)completion
{
	TSCRequest *request = [TSCRequest new];
	request.baseURL = self.sharedBaseURL;
	request.requestHTTPMethod = TSCRequestHTTPMethodGET;
	request.path = path;
	request.URLParameterDictionary = URLParamDictionary;
	
	NSMutableDictionary *requestHeaders = [self.sharedRequestHeaders mutableCopy];
	// In some API's an error will be returned if you set a Content-Type header
	// but don't pass a body (In the case of a GET request you never pass a body)
	// so for GET requests we nill this out
	[requestHeaders removeObjectForKey:@"Content-Type"];
	request.requestHeaders = requestHeaders;
	
	[self scheduleRequest:request completion:completion];
	return request;
}

#pragma mark - POST Requests

- (nonnull TSCRequest *)post:(nonnull NSString *)path bodyParams:(id)bodyParams completion:(nonnull TSCRequestCompletionHandler)completion
{
	return [self post:path withURLParamDictionary:nil bodyParams:bodyParams completion:completion];
}

- (nonnull TSCRequest *)post:(nonnull NSString *)path withURLParamDictionary:(nullable NSDictionary *)URLParamDictionary bodyParams:(id)bodyParams completion:(nonnull TSCRequestCompletionHandler)completion
{
	return [self post:path withURLParamDictionary:URLParamDictionary bodyParams:bodyParams contentType:TSCRequestContentTypeJSON completion:completion];
}

- (nonnull TSCRequest *)post:(nonnull NSString *)path withURLParamDictionary:(nullable NSDictionary *)URLParamDictionary bodyParams:(id)bodyParams contentType:(TSCRequestContentType)contentType completion:(nonnull TSCRequestCompletionHandler)completion
{
	TSCRequest *request = [TSCRequest new];
	request.baseURL = self.sharedBaseURL;
	request.path = path;
	request.requestHTTPMethod = TSCRequestHTTPMethodPOST;
	request.bodyParameters = bodyParams;
	request.URLParameterDictionary = URLParamDictionary;
	request.contentType = contentType;
	request.requestHeaders = self.sharedRequestHeaders;
	
	[self scheduleRequest:request completion:completion];
	return request;
}

#pragma mark - PUT Requests
- (nonnull TSCRequest *)put:(nonnull NSString *)path bodyParams:(id)bodyParams completion:(nonnull TSCRequestCompletionHandler)completion
{
	return [self put:path withURLParamDictionary:nil bodyParams:bodyParams completion:completion];
}

- (nonnull TSCRequest *)put:(nonnull NSString *)path withURLParamDictionary:(nullable NSDictionary *)URLParamDictionary bodyParams:(id)bodyParams completion:(nonnull TSCRequestCompletionHandler)completion
{
	return [self put:path withURLParamDictionary:URLParamDictionary bodyParams:bodyParams contentType:TSCRequestContentTypeJSON completion:completion];
}

- (nonnull TSCRequest *)put:(nonnull NSString *)path withURLParamDictionary:(nullable NSDictionary *)URLParamDictionary bodyParams:(id)bodyParams contentType:(TSCRequestContentType)contentType completion:(nonnull TSCRequestCompletionHandler)completion
{
	TSCRequest *request = [TSCRequest new];
	request.baseURL = self.sharedBaseURL;
	request.path = path;
	request.requestHTTPMethod = TSCRequestHTTPMethodPUT;
	request.bodyParameters = bodyParams;
	request.URLParameterDictionary = URLParamDictionary;
	request.contentType = contentType;
	request.requestHeaders = self.sharedRequestHeaders;
	
	[self scheduleRequest:request completion:completion];
	return request;
}

#pragma mark - PATCH requests
- (nonnull TSCRequest *)patch:(nonnull NSString *)path bodyParams:(id)bodyParams completion:(nonnull TSCRequestCompletionHandler)completion
{
	return [self patch:path withURLParamDictionary:nil bodyParams:bodyParams completion:completion];
}

- (nonnull TSCRequest *)patch:(nonnull NSString *)path withURLParamDictionary:(nullable NSDictionary *)URLParamDictionary bodyParams:(id)bodyParams completion:(nonnull TSCRequestCompletionHandler)completion
{
	return [self patch:path withURLParamDictionary:URLParamDictionary bodyParams:bodyParams contentType:TSCRequestContentTypeJSON completion:completion];
}

- (nonnull TSCRequest *)patch:(nonnull NSString *)path withURLParamDictionary:(nullable NSDictionary *)URLParamDictionary bodyParams:(id)bodyParams contentType:(TSCRequestContentType)contentType completion:(nonnull TSCRequestCompletionHandler)completion
{
	TSCRequest *request = [TSCRequest new];
	request.baseURL = self.sharedBaseURL;
	request.path = path;
	request.requestHTTPMethod = TSCRequestHTTPMethodPATCH;
	request.bodyParameters = bodyParams;
	request.URLParameterDictionary = URLParamDictionary;
	request.contentType = contentType;
	request.requestHeaders = self.sharedRequestHeaders;
	
	[self scheduleRequest:request completion:completion];
	return request;
}

#pragma mark - DELETE Requests

- (nonnull TSCRequest *)delete:(nonnull NSString *)path completion:(nonnull TSCRequestCompletionHandler)completion
{
	return [self delete:path withURLParamDictionary:nil completion:completion];
}

- (nonnull TSCRequest *)delete:(nonnull NSString *)path withURLParamDictionary:(nullable NSDictionary *)URLParamDictionary completion:(nonnull TSCRequestCompletionHandler)completion
{
	TSCRequest *request = [TSCRequest new];
	request.baseURL = self.sharedBaseURL;
	request.requestHTTPMethod = TSCRequestHTTPMethodDELETE;
	request.path = path;
	request.URLParameterDictionary = URLParamDictionary;
	request.requestHeaders = self.sharedRequestHeaders;
	
	[self scheduleRequest:request completion:completion];
	return request;
}

#pragma mark - HEAD Requests

- (nonnull TSCRequest *)head:(nonnull NSString *)path withURLParamDictionary:(nullable NSDictionary *)URLParamDictionary completion:(nonnull TSCRequestCompletionHandler)completion
{
	TSCRequest *request = [TSCRequest new];
	request.baseURL = self.sharedBaseURL;
	request.requestHTTPMethod = TSCRequestHTTPMethodHEAD;
	request.path = path;
	request.URLParameterDictionary = URLParamDictionary;
	request.requestHeaders = self.sharedRequestHeaders;
	
	[self scheduleRequest:request completion:completion];
	return request;
}

#pragma mark - DOWNLOAD/UPLOAD Requests

- (nonnull TSCRequest *)downloadFileWithPath:(nonnull NSString *)path progress:(nullable TSCRequestProgressHandler)progress completion:(nonnull TSCRequestTransferCompletionHandler)completion
{
    return [self downloadFileWithPath:path on:nil progress:progress completion:completion];
}

- (TSCRequest *)downloadFileWithPath:(NSString *)path on:(NSDate *)date progress:(TSCRequestProgressHandler)progress completion:(TSCRequestTransferCompletionHandler)completion {
    
    TSCRequest *request = [TSCRequest new];
    request.baseURL = self.sharedBaseURL;
    request.path = path;
    request.requestHTTPMethod = TSCRequestHTTPMethodGET;
    request.requestHeaders = self.sharedRequestHeaders;
    
    [self scheduleDownloadRequest:request on:date progress:progress completion:completion];
    return request;
}

- (nonnull TSCRequest *)uploadFileFromPath:(nonnull NSString *)filePath toPath:(nonnull NSString *)path progress:(nullable TSCRequestProgressHandler)progress completion:(nonnull TSCRequestTransferCompletionHandler)completion
{
	TSCRequest *request = [TSCRequest new];
	request.baseURL = self.sharedBaseURL;
	request.path = path;
	request.requestHTTPMethod = TSCRequestHTTPMethodPOST;
	request.requestHeaders = self.sharedRequestHeaders;
	
    [self scheduleUploadRequest:request on:nil filePath:filePath progress:progress completion:completion];
	return request;
}

- (nonnull TSCRequest *)uploadFileData:(nonnull NSData *)fileData toPath:(nonnull NSString *)path progress:(nullable TSCRequestProgressHandler)progress completion:(nonnull TSCRequestTransferCompletionHandler)completion
{
	TSCRequest *request = [TSCRequest new];
	request.baseURL = self.sharedBaseURL;
	request.path = path;
	request.requestHTTPMethod = TSCRequestHTTPMethodPOST;
	request.requestHeaders = self.sharedRequestHeaders;
	request.HTTPBody = fileData;
	
	NSString *cachesDirectory = [NSSearchPathForDirectoriesInDomains(NSCachesDirectory, NSUserDomainMask, YES) lastObject];
	
	NSString *filePathString = [cachesDirectory stringByAppendingPathComponent:[[NSUUID UUID] UUIDString]];
	[fileData writeToFile:filePathString atomically:YES];
	
	[self scheduleUploadRequest:request on:nil  filePath:filePathString progress:progress completion:completion];
	return request;
}

- (nonnull TSCRequest *)uploadFileData:(nonnull NSData *)fileData toPath:(nonnull NSString *)path contentType:(TSCRequestContentType)type progress:(nullable TSCRequestProgressHandler)progress completion:(nonnull TSCRequestTransferCompletionHandler)completion
{
	TSCRequest *request = [TSCRequest new];
	request.baseURL = self.sharedBaseURL;
	request.path = path;
	request.requestHTTPMethod = TSCRequestHTTPMethodPOST;
	request.requestHeaders = self.sharedRequestHeaders;
	request.contentType = type;
	request.HTTPBody = fileData;
	
	NSString *cachesDirectory = [NSSearchPathForDirectoriesInDomains(NSCachesDirectory, NSUserDomainMask, YES) lastObject];
	
	NSString *filePathString = [cachesDirectory stringByAppendingPathComponent:[[NSUUID UUID] UUIDString]];
	[fileData writeToFile:filePathString atomically:YES];
	
	[self scheduleUploadRequest:request on:nil filePath:filePathString progress:progress completion:completion];
	return request;
}

- (nonnull TSCRequest *)uploadBodyParams:(nullable NSDictionary *)bodyParams toPath:(nonnull NSString *)path contentType:(TSCRequestContentType)type progress:(nullable TSCRequestProgressHandler)progress completion:(nonnull TSCRequestTransferCompletionHandler)completion
{
	TSCRequest *request = [TSCRequest new];
	request.baseURL = self.sharedBaseURL;
	request.path = path;
	request.requestHTTPMethod = TSCRequestHTTPMethodPOST;
	request.requestHeaders = self.sharedRequestHeaders;
	request.contentType = type;
	request.bodyParameters = bodyParams;
	
	[self scheduleUploadRequest:request on:nil filePath:nil progress:progress completion:completion];
	return request;
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

// This method is used to check the OAuth2 status before starting a request
- (void)checkOAuthStatusWithRequest:(TSCRequest *)request completion:(TSCOAuth2CheckCompletion)completion
{
	// If we have an OAuth2 delegate and the request isn't the request to refresh our token
	if (self.OAuth2Delegate) {
		
		if (!self.sharedRequestCredential || ![self.sharedRequestCredential isKindOfClass:[TSCOAuth2Credential class]]) {
			self.sharedRequestCredential = [TSCOAuth2Credential retrieveCredentialWithIdentifier:[self.OAuth2Delegate authIdentifier]];
		}
		
		// If we got shared credentials and they are OAuth 2 credentials we can continue
		if (self.sharedRequestCredential && [self.sharedRequestCredential isKindOfClass:[TSCOAuth2Credential class]]) {
			
			TSCOAuth2Credential *OAuth2Credential = (TSCOAuth2Credential *)self.sharedRequestCredential;
			
			// If our credentials have expired, and we don't already have a re-authentication request let's ask our delegate to refresh them
			if (OAuth2Credential.hasExpired && !self.reAuthenticating) {
				
				__weak typeof(self) welf = self;
				
				// Important so if the re-authenticating call uses this request controller we don't end up in an infinite loop! :P (My bad guys! (Simon))
				self.reAuthenticating = true;
				
				[self.OAuth2Delegate reAuthenticateCredential:OAuth2Credential withCompletion:^(TSCOAuth2Credential * __nullable credential, NSError * __nullable error, BOOL saveToKeychain) {
					
					// If we don't get an error we save the credentials to the keychain and then call the completion block
					if (!error) {
						
						if (saveToKeychain) {
							[TSCOAuth2Credential storeCredential:credential withIdentifier:[welf.OAuth2Delegate authIdentifier]];
						}
						welf.sharedRequestCredential = credential;
					}
					
					// Call back to the initial OAuth check
					if (completion) {
						completion(error == nil, error, false);
					}
					
					// Re-schedule any requests that were queued whilst we were refreshing the OAuth token
					for (NSDictionary *request in welf.authQueuedRequests.copy) {
						[welf scheduleRequest:request[TSCQueuedRequestKey] completion:request[TSCQueuedCompletionKey]];
					}
					
					welf.authQueuedRequests = [NSMutableArray new];
					welf.reAuthenticating = false;
				}];
				
			} else if (self.reAuthenticating) { // The OAuth2 token has expired, but this is not the request which will refresh it, this can optionally be queued by the user
				
				completion(false, nil, true);
				
			} else {
				
				completion(true, nil, false);
			}
			
		} else {
			
			completion(true, nil, false);
		}
		
	} else {
		
		if (completion) {
			completion(true, nil, false);
		}
	}
}

- (void)scheduleDownloadRequest:(TSCRequest *)request on:(NSDate *)beginDate progress:(TSCRequestProgressHandler)progress completion:(TSCRequestTransferCompletionHandler)completion
{
	__weak typeof(self) welf = self;
	
	[self TSC_showApplicationActivity];
	[request prepareForDispatch];
	
	// Check OAuth status before making the request
	[self checkOAuthStatusWithRequest:request completion:^(BOOL authenticated, NSError *error, BOOL needsQueueing) {
		
		if (error || !authenticated) {
			
			if (completion) {
				completion(nil, error);
			}
			return;
		}
		
		if (self.runSynchronously) {
			
			NSError *error = nil;
			NSURL *url = [welf.backgroundSession sendSynchronousDownloadTaskWithURL:request.URL returningResponse:nil error:&error];
			
			[self TSC_hideApplicationActivity];
			
			if (completion) {
				completion(url, error);
			}
			
		} else {
			
			NSURLRequest *normalisedRequest = [self backgroundableRequestObjectFromTSCRequest:request];
			NSURLSessionDownloadTask *task = [welf.backgroundSession downloadTaskWithRequest:normalisedRequest];
            
            if (@available(iOS 11.0, *) && @available(watchOS 4.0, *)) {
                task.earliestBeginDate = beginDate;
            }
			
			[welf addCompletionHandler:completion progressHandler:progress forTaskIdentifier:task.taskIdentifier];
            
            // Set the request on the task
            task.request = request;
			[task resume];
		}
	}];
}

- (void)scheduleUploadRequest:(nonnull TSCRequest *)request on:(NSDate *)beginDate filePath:(NSString *)filePath progress:(nullable TSCRequestProgressHandler)progress completion:(nonnull TSCRequestTransferCompletionHandler)completion
{
	__weak typeof(self) welf = self;
	
	[self TSC_showApplicationActivity];
	
	[self checkOAuthStatusWithRequest:request completion:^(BOOL authenticated, NSError *error, BOOL needsQueueing) {
		
		if (error || !authenticated) {
			
			[self TSC_hideApplicationActivity];
			
			if (completion) {
				completion(nil, error);
			}
			return;
		}
		
		[request prepareForDispatch];
		
		if (self.runSynchronously) {
			
			NSError *error = nil;
			
			if (request.HTTPBody) {
				[welf.defaultSession sendSynchronousUploadTaskWithRequest:[welf backgroundableRequestObjectFromTSCRequest:request] fromData:request.HTTPBody returningResponse:nil error:&error];
			} else {
				[welf.backgroundSession sendSynchronousUploadTaskWithRequest:[welf backgroundableRequestObjectFromTSCRequest:request] fromFile:[NSURL fileURLWithPath:filePath] returningResponse:nil error:&error];
			}
			
			[self TSC_hideApplicationActivity];
			
			if (completion) {
				completion(nil, error);
			}
			
		} else {
			
			NSURLSessionUploadTask *task;
			
			if (request.HTTPBody) {
				task = [welf.defaultSession uploadTaskWithRequest:[welf backgroundableRequestObjectFromTSCRequest:request] fromData:request.HTTPBody];
			} else {
				
				task = [welf.backgroundSession uploadTaskWithRequest:[welf backgroundableRequestObjectFromTSCRequest:request] fromFile:[NSURL fileURLWithPath:filePath]];
			}
            
            task.earliestBeginDate = beginDate;
			
			[welf addCompletionHandler:completion progressHandler:progress forTaskIdentifier:task.taskIdentifier];
			
            task.request = request;
			[task resume];
		}
	}];
}

- (void)scheduleRequest:(TSCRequest *)request completion:(TSCRequestCompletionHandler)completion
{
	// Check OAuth status before making the request
	__weak typeof(self) welf = self;
	
	//Loading (Only if we're the first request)
	[self TSC_showApplicationActivity];
	
	NSString *userAgent = [[NSUserDefaults standardUserDefaults] stringForKey:@"TSCUserAgent"];
	if (userAgent) {
		[request.requestHeaders setValue:userAgent forKey:@"User-Agent"];
	}
	
	[self checkOAuthStatusWithRequest:request completion:^(BOOL authenticated, NSError *error, BOOL needsQueueing) {
		
		if (error && !authenticated && !needsQueueing) {
			
			[self TSC_hideApplicationActivity];
			
			if (completion) {
				completion(nil, error);
			}
			return;
			
		} else if (needsQueueing) {
			
			// If we're not authenticated but didn't get an error then our request came inbetween calling re-authentication and getting
			[welf.authQueuedRequests addObject:@{TSCQueuedRequestKey:request,TSCQueuedCompletionKey:completion ? : ^( TSCRequestResponse *response, NSError *error){}}];
		}
		
		[request prepareForDispatch];
		
		if (welf.runSynchronously) {
			
			NSURLResponse *response = nil;
			NSError *error = nil;
			NSData *data = [welf.defaultSession sendSynchronousDataTaskWithRequest:request returningResponse:&response error:&error];
			[welf TSC_fireRequestCompletionWithData:data response:response error:error request:request completion:completion];
			[self TSC_hideApplicationActivity];
			
		} else {
			
			NSURLSessionDataTask *dataTask = [welf.defaultSession dataTaskWithRequest:request completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
				
				[self TSC_hideApplicationActivity];
				
				[welf TSC_fireRequestCompletionWithData:data response:response error:error request:request completion:completion];
				
			}];
			
			request.taskIdentifier = dataTask.taskIdentifier;
            dataTask.request = request;
			[dataTask resume];
		}
	}];
}

#pragma mark - NSURLSession challenge handling

- (void)URLSession:(NSURLSession *)session task:(NSURLSessionTask *)task didReceiveChallenge:(NSURLAuthenticationChallenge *)challenge completionHandler:(void (^)(NSURLSessionAuthChallengeDisposition, NSURLCredential *))completionHandler
{
	if (challenge.previousFailureCount == 0) {
		completionHandler(NSURLSessionAuthChallengeUseCredential, self.sharedRequestCredential.credential);
		return;
	}
	
	completionHandler(NSURLSessionAuthChallengePerformDefaultHandling, nil);
}

- (void)URLSession:(NSURLSession *)session task:(nonnull NSURLSessionTask *)task willPerformHTTPRedirection:(nonnull NSHTTPURLResponse *)response newRequest:(nonnull NSURLRequest *)request completionHandler:(nonnull void (^)(NSURLRequest * _Nullable))completionHandler
{
	self.redirectResponses[@(task.taskIdentifier)] = response;
	completionHandler(request);
}

#pragma mark - NSURLSessionDownloadDelegate

- (void)URLSession:(NSURLSession *)session downloadTask:(NSURLSessionDownloadTask *)downloadTask didWriteData:(int64_t)bytesWritten totalBytesWritten:(int64_t)totalBytesWritten totalBytesExpectedToWrite:(int64_t)totalBytesExpectedToWrite
{
	CGFloat progress = (float)((float)totalBytesWritten /(float)totalBytesExpectedToWrite);
	
	[self callProgressHandlerForTaskIdentifier:downloadTask.taskIdentifier progress:progress totalBytes:(NSInteger)totalBytesExpectedToWrite progressBytes:(NSInteger)totalBytesWritten];
}

- (void)URLSession:(NSURLSession *)session downloadTask:(NSURLSessionDownloadTask *)downloadTask didFinishDownloadingToURL:(NSURL *)location
{
	[self callCompletionHandlerForTaskIdentifier:downloadTask.taskIdentifier downloadedFileURL:location downloadError:nil];
}

- (void)URLSession:(NSURLSession *)session task:(NSURLSessionTask *)task didCompleteWithError:(NSError *)error
{
	[self callCompletionHandlerForTaskIdentifier:task.taskIdentifier downloadedFileURL:nil downloadError:error];
}

#pragma mark - NSURLSessionUploadDelegate

- (void)URLSession:(NSURLSession *)session task:(NSURLSessionTask *)task didSendBodyData:(int64_t)bytesSent totalBytesSent:(int64_t)totalBytesSent totalBytesExpectedToSend:(int64_t)totalBytesExpectedToSend
{
	CGFloat progress = (float)((float)totalBytesSent /(float)totalBytesExpectedToSend);
	[self callProgressHandlerForTaskIdentifier:task.taskIdentifier progress:progress totalBytes:(NSInteger)totalBytesExpectedToSend progressBytes:(NSInteger)totalBytesSent];
}

#pragma mark - NSURLSessionDownload completion handling

- (void)addCompletionHandler:(TSCRequestTransferCompletionHandler)handler progressHandler:(TSCRequestProgressHandler)progress forTaskIdentifier:(NSUInteger)identifier
{
	NSString *taskIdentifierString = [NSString stringWithFormat:@"%lu-completion", (unsigned long)identifier];
	NSString *taskProgressIdentifierString = [NSString stringWithFormat:@"%lu-progress", (unsigned long)identifier];
	
	if ([self.completionHandlerDictionary objectForKey:taskIdentifierString]) {
        os_log_error(request_controller_log, "Error: Got multiple handlers for a single task identifier.  This should not happen.\n");
	}
	
    if (handler) {
        [self.completionHandlerDictionary setObject:handler forKey:taskIdentifierString];
    }
	
	if ([self.completionHandlerDictionary objectForKey:taskProgressIdentifierString]) {
        os_log_error(request_controller_log, "Error: Got multiple progress handlers for a single task identifier.  This should not happen.\n");
	}
	
    if (progress) {
        [self.completionHandlerDictionary setObject:progress forKey:taskProgressIdentifierString];
    }
}

- (void)callCompletionHandlerForTaskIdentifier:(NSUInteger)identifier downloadedFileURL:(NSURL *)fileURL downloadError:(NSError *)error
{
	NSString *taskIdentifierString = [NSString stringWithFormat:@"%lu-completion", (unsigned long)identifier];
	NSString *taskProgressIdentifierString = [NSString stringWithFormat:@"%lu-progress", (unsigned long)identifier];
	
	[self TSC_hideApplicationActivity];
	
	TSCRequestTransferCompletionHandler handler = [self.completionHandlerDictionary objectForKey:taskIdentifierString];
	
	if (handler) {
		
		[self.completionHandlerDictionary removeObjectsForKeys:@[taskIdentifierString, taskProgressIdentifierString]];
		
		handler(fileURL, error);
		
	}
}

- (void)callProgressHandlerForTaskIdentifier:(NSUInteger)identifier progress:(CGFloat)progress totalBytes:(NSInteger)total progressBytes:(NSInteger)bytes
{
	NSString *taskProgressIdentifierString = [NSString stringWithFormat:@"%lu-progress", (unsigned long)identifier];
	
	TSCRequestProgressHandler handler = [self.completionHandlerDictionary objectForKey:taskProgressIdentifierString];
	
	if (handler) {
		
		handler(progress, total, bytes);
		
	}
	
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
		_OAuth2RequestController = [[TSCRequestController alloc] initWithBaseURL:self.sharedBaseURL];
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

- (void)URLSessionDidFinishEventsForBackgroundURLSession:(NSURLSession *)session
{
    os_log_debug(request_controller_log, "finished events for bg session");
}

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

- (void)invalidateAndCancel
{
	[self.defaultSession invalidateAndCancel];
	[self.backgroundSession invalidateAndCancel];
	[self.ephemeralSession invalidateAndCancel];
}

- (void)TSC_showApplicationActivity
{
#if TARGET_OS_IOS
	if (![[[NSBundle mainBundle] objectForInfoDictionaryKey:@"TSCThunderRequestShouldHideActivityIndicator"] boolValue]) {
		[ApplicationLoadingIndicatorManager.sharedManager showActivityIndicator];
	}
#endif
}

- (void)TSC_hideApplicationActivity
{
#if TARGET_OS_IOS
	if (![[[NSBundle mainBundle] objectForInfoDictionaryKey:@"TSCThunderRequestShouldHideActivityIndicator"] boolValue]) {
		[ApplicationLoadingIndicatorManager.sharedManager hideActivityIndicator];
	}
#endif
}

@end
