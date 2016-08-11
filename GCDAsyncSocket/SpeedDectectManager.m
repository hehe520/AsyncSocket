//
//  SpeedDectectManager.m
//  GCDAsyncSocket
//
//  Created by caokun on 16/7/8.
//  Copyright © 2016年 caokun. All rights reserved.
//

#import "SpeedDectectManager.h"
#import "AFNetworking/AFNetworking.h"
#import "Common.pb.h"
#import "GCDAsyncSocket.h"

#define ServiceListsCacheKey @"ServiceListsCacheKey"    // 服务器列表缓存 key
#define ServiceListsStampKey @"ServiceListsStampKey"    // 时间戳
#define FasterServiceCacheKey @"FasterServiceCacheKey"  // 最快的服务器地址 key
#define FasterServiceStampKey @"FasterServiceStampKey"  // 时间戳

@interface SpeedDectectManager () <GCDAsyncSocketDelegate>

@property (strong, nonatomic) NSMutableArray *socketArray;
@property (strong, nonatomic) dispatch_queue_t socketQueue;
@property (assign, nonatomic) UInt32 seq;
@property (strong, nonatomic) NSArray *serverModels;
@property (assign, nonatomic) NSInteger receiveCount;   // 返回的测速包个数
@property (strong, nonatomic) serverURL completion;     // 回调 block
@property (strong, nonatomic) NSTimer *timer;           // 超时定时器

@end

@implementation SpeedDectectManager

static SpeedDectectManager *instance = nil;

+ (SpeedDectectManager *)instance {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        instance = [[SpeedDectectManager alloc] init];
    });
    return instance;
}

- (instancetype)init {
    if (self = [super init]) {
        self.seq = 1000;
    }
    return self;
}

- (dispatch_queue_t)socketQueue {
    if (_socketQueue == nil) {
        _socketQueue = dispatch_queue_create("com.speedSocket", DISPATCH_QUEUE_CONCURRENT);
    }
    return _socketQueue;
}

- (UInt32)seq {
    _seq = _seq + 1;
    return _seq;
}

- (NSMutableArray *)socketArray {
    if (_socketArray == nil) {
        _socketArray = [[NSMutableArray alloc] init];
    }
    return _socketArray;
}

// 开始测试服务器连接速度
- (void)startDectect:(serverURL)complete {
    NSData *obj = [[NSUserDefaults standardUserDefaults] objectForKey:FasterServiceCacheKey];
    NSDate *date = [[NSUserDefaults standardUserDefaults] objectForKey:FasterServiceStampKey];
    NSDate *curDate = [NSDate dateWithTimeIntervalSinceNow:0];
    NSTimeInterval seconds = 10000;     // 相差的秒数

    if (date != nil && curDate != nil) {
        seconds = ABS([date timeIntervalSinceDate:curDate]);
    }
    // 判断是否在 300 秒内, 使用缓存
    if (obj != nil || date != nil || seconds < 300) {
        ServerURLModel *m = [NSKeyedUnarchiver unarchiveObjectWithData:obj];
        complete(m, nil);
        return ;
    }
    
    // 超时不使用缓存
    __weak typeof(self) ws = self;
    self.receiveCount = 0;
    self.completion = complete;
    
    // 获取服务器列表有缓存
    [ws requestServiceListsWithCache:^(NSArray *response, NSString *error) {
        ws.serverModels = response;
        // 测试连接，由于后台漏掉 seq 字段，此处用 SocketManager 来区分返回的包，创建多个线程，每个线程一个 socket 异步请求
        for (ServerURLModel *m in response) {
            dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
                // 该段代码在不同的线程
                GCDAsyncSocket *socket = [[GCDAsyncSocket alloc] initWithDelegate:ws delegateQueue:ws.socketQueue];
                socket.IPv6Enabled = true;
                socket.IPv4Enabled = true;
                socket.IPv4PreferredOverIPv6 = false;
                
                NSError *error = nil;
                [socket connectToHost:m.ip onPort:(UInt16)[m.port intValue] withTimeout:10 error:&error];
                if (error == nil) {
                    [socket readDataWithTimeout:10 tag:100];
                    [socket writeData:[ws speedTest] withTimeout:10 tag:100];       // 发送测速包
                }
                [ws.socketArray addObject:socket];      // 保证 socket 不 ARC 释放，导致断开
            });
        }
        // 测速包 4 秒超时
        [self closeTimer];
        __weak typeof(self) ws = self;
        dispatch_async(dispatch_get_main_queue(), ^{
            ws.timer = [NSTimer scheduledTimerWithTimeInterval:4 target:ws selector:@selector(timeOut:) userInfo:nil repeats:false];
        });
    }];
}

// 生成测速包
- (NSData *)speedTest {
    load_dector_msgBuilder *msg = [load_dector_msg builder];
    [msg setReq:true];
    [msg setSendTime:CACurrentMediaTime() * 1000];     // 时间戳
    
    rpc_msg_rootBuilder *rootMsg = [rpc_msg_root builder];
    [rootMsg setService:eum_rpc_serviceCommonService];
    [rootMsg setMethod:eum_method_typeLoadDetector];
    [rootMsg setBody:[[msg build] data]];
    UInt32 s = self.seq;
    [rootMsg setSeq:s];

    rpc_msg_root *root = [rootMsg build];
    SInt32 length = [root serializedSize];      // 包头是 32 位的整型，表示包体长度
    NSMutableData *data = [NSMutableData dataWithBytes:&length length:4];
    [data appendData:[root data]];      // 追加包体
    
    return data;
}

// socket 接收数据
- (void)socket:(GCDAsyncSocket *)sock didReadData:(NSData *)data withTag:(long)tag {
    // 此处有个风险，需保证测速包是一次性返回的，由于测速包是 17 个字节比较小，可以一次返回
    if (data.length >= 4) {
        NSData *rootData = [data subdataWithRange:NSMakeRange(4, data.length - 4)];
        rpc_msg_root *root = [rpc_msg_root parseFromData:rootData];
        load_dector_msg *speed = [load_dector_msg parseFromData:root.body];
        
        for (ServerURLModel *m in self.serverModels) {
            if ([m.ip isEqualToString:sock.connectedHost] && (uint16_t)[m.port intValue] == sock.connectedPort) {
                m.loadFactor = speed.loadFactor;
                m.connectCount = speed.connectCount;
                m.delay = CACurrentMediaTime() * 1000 - speed.sendTime;
                self.receiveCount += 1;
                break;
            }
        }
        // 测速包全部返回，计算最快服务器
        if (self.receiveCount == self.serverModels.count) {
            [self calculate:self.serverModels];
            [self closeTimer];
            [self.socketArray removeAllObjects];    // 清空 socket 连接
            return ;
        }
    }
}

- (void)closeTimer {
    __weak typeof(self) ws = self;
    dispatch_async(dispatch_get_main_queue(), ^{
        if (ws.timer) {
            [ws.timer invalidate];
            ws.timer = nil;
        }
    });
}

- (void)timeOut:(NSTimer *)timer {
    [self calculate:self.serverModels];
    [self closeTimer];
    [self.socketArray removeAllObjects];    // 清空 socket 连接
}

// 负载因子不超过平均数的10%，且延迟最小的服务器
- (void)calculate:(NSArray *)array {
    // 按延迟排序
    NSArray *sorted = [array sortedArrayUsingComparator:^NSComparisonResult(id  _Nonnull obj1, id  _Nonnull obj2) {
        ServerURLModel *m1 = obj1;
        ServerURLModel *m2 = obj2;
        
        if (m1.delay > m2.delay) {
            return NSOrderedDescending;
        } else {
            return NSOrderedAscending;
        }
    }];
    // 去掉超时的包
    NSMutableArray *valuableArray = [[NSMutableArray alloc] init];
    for (ServerURLModel *m in sorted) {
        if (m.loadFactor < 10000000) {      // 超过 10000000 是超时的
            [valuableArray addObject:m];
        }
    }
    if (valuableArray.count == 0) {
        dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
            self.completion(nil, @"no servers");
        });
        return ;
    }
    // 计算平均数, 找出不超过平均数 10% 的返回
    CGFloat sum = 0;
    CGFloat ave = 0;
    for (ServerURLModel *m in valuableArray) {
        sum += m.loadFactor;
    }
    ave = sum / valuableArray.count * 1.1;
    for (ServerURLModel *m in valuableArray) {
        if (m.loadFactor < ave) {
            // 本地缓存
            NSData *data = [NSKeyedArchiver archivedDataWithRootObject:m];
            [[NSUserDefaults standardUserDefaults] setObject:data forKey:FasterServiceCacheKey];
            [[NSUserDefaults standardUserDefaults] setObject:[NSDate dateWithTimeIntervalSinceNow:0] forKey:FasterServiceStampKey];
            
            dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
                NSLog(@"使用 %@", m.ip);
                self.completion(m, nil);        // 返回最快的服务器
            });
            break;
        }
    }
}

// 获取服务器列表并缓存一天
- (void)requestServiceListsWithCache:(serverURLs)complete {
    NSData *obj = [[NSUserDefaults standardUserDefaults] objectForKey:ServiceListsCacheKey];
    NSDate *date = [[NSUserDefaults standardUserDefaults] objectForKey:ServiceListsStampKey];
    NSDate *curDate = [NSDate dateWithTimeIntervalSinceNow:0];
    NSTimeInterval seconds = 24 * 3600;     // 相差的秒数
    
    if (date != nil && curDate != nil) {
        seconds = ABS([date timeIntervalSinceDate:curDate]);
    }
    // 判断是否超过一天
    if (obj == nil || date == nil || seconds > 24 * 3600) {
        [self requestServiceLists:^(NSArray *response, NSString *error) {
            // 本地缓存 + 时间戳
            NSData *data = [NSKeyedArchiver archivedDataWithRootObject:response];
            [[NSUserDefaults standardUserDefaults] setObject:data forKey:ServiceListsCacheKey];
            [[NSUserDefaults standardUserDefaults] setObject:[NSDate dateWithTimeIntervalSinceNow:0] forKey:ServiceListsStampKey];
            complete(response, nil);
        }];
    } else {        // 读取缓存
        NSArray *array = [NSKeyedUnarchiver unarchiveObjectWithData:obj];
        complete(array, nil);
    }
}

// 获取服务器列表
// 用户名跟密码由于是公司的账号，还有一些公司内部的域名，不敢随便公布了
- (void)requestServiceLists:(serverURLs)complete {
    // 默认服务器列表
    ServerURLModel *defaultModel = [[ServerURLModel alloc] init];
    defaultModel.ip = @"127.0.0.1";
    defaultModel.port = @"1234";
    
    // 发起请求
    AFHTTPSessionManager *manager = [[AFHTTPSessionManager alloc] initWithBaseURL:[[NSURL alloc] initWithString:@"https://www.baidu.com/"]];
    manager.responseSerializer = [AFHTTPResponseSerializer serializer];
    manager.responseSerializer.acceptableContentTypes = [NSSet setWithObject:@"text/html"];
    
    NSDictionary *params = @{@"userName":@"用户名", @"service":@"T", @"api":@"sf"};
    
    // get 请求
    [manager GET:@"" parameters:params progress:nil success:^(NSURLSessionDataTask * _Nonnull task, id  _Nullable responseObject) {
        // jsonString -> jsonData -> NSDictionary -> model
        NSString *jsonString = [[NSString alloc] initWithData:responseObject encoding:NSUTF8StringEncoding];
        NSData *jsonData = [jsonString dataUsingEncoding:NSUTF8StringEncoding];
        NSError *error = nil;
        NSDictionary *dic = [NSJSONSerialization JSONObjectWithData:jsonData options:NSJSONReadingMutableContainers error:&error];
        if (error) {
            NSLog(@"json 解析失败");
            complete(@[defaultModel], nil);
        } else {
            NSArray *responses = dic[@"response"];
            NSMutableArray *array = [[NSMutableArray alloc] init];
            for (NSDictionary *d in responses) {
                ServerURLModel *m = [[ServerURLModel alloc] initWithDictionary:d];
                [array addObject:m];
            }
            complete(array, nil);
        }
    } failure:^(NSURLSessionDataTask * _Nullable task, NSError * _Nonnull error) {
        NSLog(@"获取服务器列表失败");
        complete(@[defaultModel], nil);
    }];
}

@end

