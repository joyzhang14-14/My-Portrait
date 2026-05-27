#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// 跑 block,捕获 ObjC NSException 转成 NSError 返回。Swift 不接
/// NSException 抛出会直接杀进程,AVAudioEngine.installTap /
/// engine.start 在 aggregate device 格式不匹配时就用 NSException 报错。
///
/// 返回 nil = block 正常跑完;非 nil = 抛过异常,error.domain 是
/// "MyPortraitObjC.NSException",error.userInfo 含 name / reason / callStack。
NSError * _Nullable MyPortraitObjCTryCatch(NS_NOESCAPE dispatch_block_t block);

NS_ASSUME_NONNULL_END
