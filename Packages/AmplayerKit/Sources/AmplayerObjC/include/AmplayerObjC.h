#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// 执行 block，接住其中抛出的 Objective-C 异常，返回“名称: 原因”；没有异常返回 nil。
/// AVAudioEngine 连接节点失败（比如输出设备正在切换）抛的是这种异常，Swift 的 do/catch 接不住，会直接闪退。
FOUNDATION_EXPORT NSString * _Nullable AMPCatchException(NS_NOESCAPE void (^block)(void));

NS_ASSUME_NONNULL_END
