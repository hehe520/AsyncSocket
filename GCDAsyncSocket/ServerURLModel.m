//
//  ServerURLModel.m
//  GCDAsyncSocket
//
//  Created by caokun on 16/7/8.
//  Copyright © 2016年 caokun. All rights reserved.
//

#import "ServerURLModel.h"

@implementation ServerURLModel

- (instancetype)init {
    if (self = [super init]) {
        self.hostName = nil;
        self.ip = nil;
        self.port = nil;
        self.loadFactor = 10000000;
        self.delay = 10000000;
        self.connectCount = 10000000;
    }
    return self;
}

- (instancetype)initWithDictionary:(NSDictionary *)dic {
    if (self = [super init]) {
        if (dic) {
            self.hostName = dic[@"hostName"];
            self.ip = dic[@"ip"];
            self.port = dic[@"port"];
            self.loadFactor = 10000000;
            self.delay = 10000000;
            self.connectCount = 10000000;
        }
    }
    return self;
}

// encode 到 aCoder 中
- (void)encodeWithCoder:(NSCoder *)aCoder {
    [aCoder encodeObject:self.hostName forKey:@"hostName"];
    [aCoder encodeObject:self.ip forKey:@"ip"];
    [aCoder encodeObject:self.port forKey:@"port"];
}

// 从 aDecoder 还原到类中
- (id)initWithCoder:(NSCoder *)aDecoder {
    if (self = [super init]) {
        self.hostName = [aDecoder decodeObjectForKey:@"hostName"];
        self.ip = [aDecoder decodeObjectForKey:@"ip"];
        self.port = [aDecoder decodeObjectForKey:@"port"];
    }
    return self;
}

@end
