// AFNetworkReachabilityManager.m
// Copyright (c) 2011–2016 Alamofire Software Foundation ( http://alamofire.org/ )
//
// Permission is hereby granted, free of charge, to any person obtaining a copy
// of this software and associated documentation files (the "Software"), to deal
// in the Software without restriction, including without limitation the rights
// to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
// copies of the Software, and to permit persons to whom the Software is
// furnished to do so, subject to the following conditions:
//
// The above copyright notice and this permission notice shall be included in
// all copies or substantial portions of the Software.
//
// THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
// IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
// FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
// AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
// LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
// OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
// THE SOFTWARE.

#import "AFNetworkReachabilityManager.h"
#if !TARGET_OS_WATCH

#import <netinet/in.h>
#import <netinet6/in6.h>
#import <arpa/inet.h>
#import <ifaddrs.h>
#import <netdb.h>

NSString * const AFNetworkingReachabilityDidChangeNotification = @"com.alamofire.networking.reachability.change";
NSString * const AFNetworkingReachabilityNotificationStatusItem = @"AFNetworkingReachabilityNotificationStatusItem";

typedef void (^AFNetworkReachabilityStatusBlock)(AFNetworkReachabilityStatus status);

NSString * AFStringFromNetworkReachabilityStatus(AFNetworkReachabilityStatus status) {
    switch (status) {
        case AFNetworkReachabilityStatusNotReachable:
            return NSLocalizedStringFromTable(@"Not Reachable", @"AFNetworking", nil);
        case AFNetworkReachabilityStatusReachableViaWWAN:
            return NSLocalizedStringFromTable(@"Reachable via WWAN", @"AFNetworking", nil);
        case AFNetworkReachabilityStatusReachableViaWiFi:
            return NSLocalizedStringFromTable(@"Reachable via WiFi", @"AFNetworking", nil);
        case AFNetworkReachabilityStatusUnknown:
        default:
            return NSLocalizedStringFromTable(@"Unknown", @"AFNetworking", nil);
    }
}

/**
 *  因为 flags 是一个 SCNetworkReachabilityFlags，它的不同位代表了不同的网络可达性状态，通过 flags 的位操作，获取当前的状态信息 AFNetworkReachabilityStatus。
 */
static AFNetworkReachabilityStatus AFNetworkReachabilityStatusForFlags(SCNetworkReachabilityFlags flags) {
    BOOL isReachable = ((flags & kSCNetworkReachabilityFlagsReachable) != 0);
    BOOL needsConnection = ((flags & kSCNetworkReachabilityFlagsConnectionRequired) != 0);
    BOOL canConnectionAutomatically = (((flags & kSCNetworkReachabilityFlagsConnectionOnDemand ) != 0) || ((flags & kSCNetworkReachabilityFlagsConnectionOnTraffic) != 0));
    BOOL canConnectWithoutUserInteraction = (canConnectionAutomatically && (flags & kSCNetworkReachabilityFlagsInterventionRequired) == 0);
    BOOL isNetworkReachable = (isReachable && (!needsConnection || canConnectWithoutUserInteraction));

    AFNetworkReachabilityStatus status = AFNetworkReachabilityStatusUnknown;
    if (isNetworkReachable == NO) {
        status = AFNetworkReachabilityStatusNotReachable;
    }
#if	TARGET_OS_IPHONE
    else if ((flags & kSCNetworkReachabilityFlagsIsWWAN) != 0) {
        status = AFNetworkReachabilityStatusReachableViaWWAN;
    }
#endif
    else {
        status = AFNetworkReachabilityStatusReachableViaWiFi;
    }

    return status;
}

/**
 * Queue a status change notification for the main thread.
 *
 * This is done to ensure that the notifications are received in the same order
 * as they are sent. If notifications are sent directly, it is possible that
 * a queued notification (for an earlier status condition) is processed after
 * the later update, resulting in the listener being left in the wrong state.
 */
static void AFPostReachabilityStatusChange(SCNetworkReachabilityFlags flags, AFNetworkReachabilityStatusBlock block) {
    // 1、调用 AFNetworkReachabilityStatusForFlags 获取当前的网络可达性状态
    AFNetworkReachabilityStatus status = AFNetworkReachabilityStatusForFlags(flags);
    dispatch_async(dispatch_get_main_queue(), ^{
        // 2、在主线程中异步执行上面传入的 callback block（设置 self 的网络状态，调用 networkReachabilityStatusBlock）
        if (block) {
            block(status);
        }
        // 3、发送 AFNetworkingReachabilityDidChangeNotification 通知.
        NSNotificationCenter *notificationCenter = [NSNotificationCenter defaultCenter];
        NSDictionary *userInfo = @{ AFNetworkingReachabilityNotificationStatusItem: @(status) };
        [notificationCenter postNotificationName:AFNetworkingReachabilityDidChangeNotification object:nil userInfo:userInfo];
    });
}

/**
 *  在 Main Runloop 中对网络状态进行监控之后，在每次网络状态改变，就会调用 AFNetworkReachabilityCallback 函数
 */
static void AFNetworkReachabilityCallback(SCNetworkReachabilityRef __unused target, SCNetworkReachabilityFlags flags, void *info) {
    /**
     *  这里会从 info 中取出之前存在 context 中的 AFNetworkReachabilityStatusBlock
     */
    AFPostReachabilityStatusChange(flags, (__bridge AFNetworkReachabilityStatusBlock)info);
}


static const void * AFNetworkReachabilityRetainCallback(const void *info) {
    return Block_copy(info);
}

static void AFNetworkReachabilityReleaseCallback(const void *info) {
    if (info) {
        Block_release(info);
    }
}

@interface AFNetworkReachabilityManager ()
@property (readonly, nonatomic, assign) SCNetworkReachabilityRef networkReachability;
@property (readwrite, nonatomic, assign) AFNetworkReachabilityStatus networkReachabilityStatus;
@property (readwrite, nonatomic, copy) AFNetworkReachabilityStatusBlock networkReachabilityStatusBlock;
@end

/**
 *  AFNetworkReachabilityManager 的使用还是非常简单的，只需要三个步骤，就基本可以完成对网络状态的监控。
 
 初始化 AFNetworkReachabilityManager
 调用 startMonitoring 方法开始对网络状态进行监控
 设置 networkReachabilityStatusBlock 在每次网络状态改变时, 调用这个 block
 */
@implementation AFNetworkReachabilityManager

+ (instancetype)sharedManager {
    static AFNetworkReachabilityManager *_sharedManager = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        _sharedManager = [self manager];
    });

    return _sharedManager;
}

/**
 *  初始化 AFNetworkReachabilityManager
 *
 *  @param domain 通过一个域名生成一个 SCNetworkReachabilityRef
 *
 *  使用 SCNetworkReachabilityCreateWithName 生成一个 SCNetworkReachabilityRef 的引用
 */
+ (instancetype)managerForDomain:(NSString *)domain {
    SCNetworkReachabilityRef reachability = SCNetworkReachabilityCreateWithName(kCFAllocatorDefault, [domain UTF8String]);

    AFNetworkReachabilityManager *manager = [[self alloc] initWithReachability:reachability];
    
    CFRelease(reachability);

    return manager;
}

/**
 *  初始化 AFNetworkReachabilityManager
 *
 *  @param domain 通过一个 sockaddr_in 的指针生成一个 SCNetworkReachabilityRef
 *
 *  使用 SCNetworkReachabilityCreateWithAddress 生成一个 SCNetworkReachabilityRef 的引用
 */
+ (instancetype)managerForAddress:(const void *)address {
    SCNetworkReachabilityRef reachability = SCNetworkReachabilityCreateWithAddress(kCFAllocatorDefault, (const struct sockaddr *)address);
    AFNetworkReachabilityManager *manager = [[self alloc] initWithReachability:reachability];

    CFRelease(reachability);
    
    return manager;
}

+ (instancetype)manager
{
#if (defined(__IPHONE_OS_VERSION_MIN_REQUIRED) && __IPHONE_OS_VERSION_MIN_REQUIRED >= 90000) || (defined(__MAC_OS_X_VERSION_MIN_REQUIRED) && __MAC_OS_X_VERSION_MIN_REQUIRED >= 101100)
    struct sockaddr_in6 address;
    bzero(&address, sizeof(address));
    address.sin6_len = sizeof(address);
    address.sin6_family = AF_INET6;
#else
    struct sockaddr_in address;
    bzero(&address, sizeof(address));
    address.sin_len = sizeof(address);
    address.sin_family = AF_INET;
#endif
    return [self managerForAddress:&address];
}

/**
 *  调用 - [AFNetworkReachabilityManager initWithReachability:] 将生成的 SCNetworkReachabilityRef 引用传给 networkReachability
 *
 *  @return <#return value description#>
 */
- (instancetype)initWithReachability:(SCNetworkReachabilityRef)reachability {
    self = [super init];
    if (!self) {
        return nil;
    }
    
//    当调用 CFBridgingRelease(reachability) 后，会把 reachability 桥接成一个 NSObject 对象赋值给 self.networkReachability，然后释放原来的 CoreFoundation 对象。
//    self.networkReachability = CFBridgingRelease(reachability);
    _networkReachability = CFRetain(reachability);
    /**
     *  设置一个默认的 networkReachabilityStatus
     */
    self.networkReachabilityStatus = AFNetworkReachabilityStatusUnknown;

    return self;
}

- (instancetype)init NS_UNAVAILABLE
{
    return nil;
}

- (void)dealloc {
    [self stopMonitoring];
    
    if (_networkReachability != NULL) {
        CFRelease(_networkReachability);
    }
}

#pragma mark -

- (BOOL)isReachable {
    return [self isReachableViaWWAN] || [self isReachableViaWiFi];
}

- (BOOL)isReachableViaWWAN {
    return self.networkReachabilityStatus == AFNetworkReachabilityStatusReachableViaWWAN;
}

- (BOOL)isReachableViaWiFi {
    return self.networkReachabilityStatus == AFNetworkReachabilityStatusReachableViaWiFi;
}

#pragma mark - 在初始化 AFNetworkReachabilityManager 后，会调用 startMonitoring 方法开始监控网络状态。

- (void)startMonitoring {
    /**
     *  1、先调用 - stopMonitoring 方法，如果之前设置过对网络状态的监听，取消之前的监听
     */
    [self stopMonitoring];

    if (!self.networkReachability) {
        return;
    }

    /**
     *  2、创建一个在每次网络状态改变时的回调
         每次回调被调用时
         重新设置 networkReachabilityStatus 属性
         调用 networkReachabilityStatusBlock
     */
    __weak __typeof(self)weakSelf = self;
    AFNetworkReachabilityStatusBlock callback = ^(AFNetworkReachabilityStatus status) {
        __strong __typeof(weakSelf)strongSelf = weakSelf;

        strongSelf.networkReachabilityStatus = status;
        if (strongSelf.networkReachabilityStatusBlock) {
            strongSelf.networkReachabilityStatusBlock(status);
        }

    };

    /**
     *  3、创建一个 SCNetworkReachabilityContext
     typedef struct {
     CFIndex		version;
     void *		__nullable info;
     const void	* __nonnull (* __nullable retain)(const void *info);
     void		(* __nullable release)(const void *info);
     CFStringRef	__nonnull (* __nullable copyDescription)(const void *info);
     } SCNetworkReachabilityContext;

     */
    /**
     *  这里的 AFNetworkReachabilityRetainCallback 和 AFNetworkReachabilityReleaseCallback 都是非常简单的 block，在回调被调用时，只是使用 Block_copy 和 Block_release 这样的宏
     传入的 info 会以参数的形式在 AFNetworkReachabilityCallback 执行时传入
     
     static const void * AFNetworkReachabilityRetainCallback(const void *info) { return Block_copy(info); }
     
     static void AFNetworkReachabilityReleaseCallback(const void *info) { if (info) { Block_release(info); } }
     */
    SCNetworkReachabilityContext context = {
        0,                                    // CFIndex		version
        (__bridge void *) callback,           // void *		__nullable info
        AFNetworkReachabilityRetainCallback,  // const void	* __nonnull (* __nullable retain)(const void *info)
        AFNetworkReachabilityReleaseCallback, // void		(* __nullable release)(const void *info)
        NULL                                  //__nonnull (* __nullable copyDescription)(const void *info)
    };
    /**
     *  当目标的网络状态改变时，会调用传入的回调
     */
    SCNetworkReachabilitySetCallback(self.networkReachability,
                                     AFNetworkReachabilityCallback,
                                     &context);
    /**
     *  在 Main Runloop 中对应的模式开始监控网络状态
     */
    SCNetworkReachabilityScheduleWithRunLoop(self.networkReachability,
                                             CFRunLoopGetMain(),
                                             kCFRunLoopCommonModes);

    /**
     *  获取当前的网络状态，调用 callback
     */
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_BACKGROUND, 0),^{
        SCNetworkReachabilityFlags flags;
        if (SCNetworkReachabilityGetFlags(self.networkReachability, &flags)) {
            AFPostReachabilityStatusChange(flags, callback);
        }
    });
}

/**
 *  如果之前设置过对网络状态的监听，使用 SCNetworkReachabilityUnscheduleFromRunLoop 方法取消之前在 Main Runloop 中的监听
 */
- (void)stopMonitoring {
    if (!self.networkReachability) {
        return;
    }

    SCNetworkReachabilityUnscheduleFromRunLoop(self.networkReachability, CFRunLoopGetMain(), kCFRunLoopCommonModes);
}

#pragma mark -

- (NSString *)localizedNetworkReachabilityStatusString {
    return AFStringFromNetworkReachabilityStatus(self.networkReachabilityStatus);
}

#pragma mark -

- (void)setReachabilityStatusChangeBlock:(void (^)(AFNetworkReachabilityStatus status))block {
    self.networkReachabilityStatusBlock = block;
}

#pragma mark - NSKeyValueObserving

+ (NSSet *)keyPathsForValuesAffectingValueForKey:(NSString *)key {
    if ([key isEqualToString:@"reachable"] || [key isEqualToString:@"reachableViaWWAN"] || [key isEqualToString:@"reachableViaWiFi"]) {
        return [NSSet setWithObject:@"networkReachabilityStatus"];
    }

    return [super keyPathsForValuesAffectingValueForKey:key];
}

@end
#endif
