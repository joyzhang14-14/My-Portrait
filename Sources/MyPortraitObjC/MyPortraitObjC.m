#import "MyPortraitObjC.h"

NSError * _Nullable MyPortraitObjCTryCatch(NS_NOESCAPE dispatch_block_t block) {
    @try {
        block();
        return nil;
    } @catch (NSException *exception) {
        NSMutableDictionary *info = [NSMutableDictionary dictionary];
        info[@"name"] = exception.name ?: @"<unknown>";
        info[@"reason"] = exception.reason ?: @"<no reason>";
        if (exception.userInfo) info[@"exception_userInfo"] = exception.userInfo;
        if (exception.callStackSymbols) info[@"callStack"] = exception.callStackSymbols;
        info[NSLocalizedDescriptionKey] =
            [NSString stringWithFormat:@"%@: %@",
                exception.name ?: @"NSException",
                exception.reason ?: @""];
        return [NSError errorWithDomain:@"MyPortraitObjC.NSException"
                                   code:0
                               userInfo:info];
    }
}
