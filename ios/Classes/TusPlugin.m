// Copyright 2020 Lionell Yip. All rights reserved.

#import "TusPlugin.h"

static NSString *const CHANNEL_NAME = @"io.tus.flutter_service";
static NSString *const InvalidParameters = @"Invalid parameters";
static NSString* const FILE_NAME = @"tuskit_example";

@interface TusPlugin()

@property (strong, nonatomic) NSURL *applicationSupportUrl;
@property (strong, atomic) NSDictionary *tusSessions;
@property (strong, nonatomic) TUSUploadStore *tusUploadStore;
@property (strong, nonatomic) NSURLSessionConfiguration *sessionConfiguration;
@property(nonatomic, retain) FlutterMethodChannel *channel;

@end

@implementation TusPlugin
-(instancetype) init {
    self = [super init];
    if(self) {
        self.applicationSupportUrl = [[[NSFileManager defaultManager] URLsForDirectory:NSApplicationSupportDirectory inDomains:NSUserDomainMask] firstObject];
        self.tusUploadStore = [[TUSFileUploadStore alloc] initWithURL:[self.applicationSupportUrl URLByAppendingPathComponent:FILE_NAME]];
        self.sessionConfiguration = [NSURLSessionConfiguration defaultSessionConfiguration];
        self.sessionConfiguration.allowsCellularAccess = YES;
        self.tusSessions = [[NSMutableDictionary alloc]init];
    }

    return self;
}

+ (void)registerWithRegistrar:(NSObject<FlutterPluginRegistrar>*)registrar {
  FlutterMethodChannel* channel = [FlutterMethodChannel
      methodChannelWithName:CHANNEL_NAME
            binaryMessenger:[registrar messenger]];
  TusPlugin* instance = [[TusPlugin alloc] init];
    instance.channel = channel;
  [registrar addMethodCallDelegate:instance channel:channel];
}

- (void)handleMethodCall:(FlutterMethodCall*)call result:(FlutterResult)result {
    NSDictionary *arguments = [call arguments];
    NSDictionary *options = [arguments[@"options"] isKindOfClass:[NSDictionary class]] ? arguments[@"options"] : nil;

    if ([@"initWithEndpoint" isEqualToString:call.method]) {
        NSString *endpointUrl = arguments[@"endpointUrl"];
        if (![endpointUrl isKindOfClass:[NSString class]]) {
            result([FlutterError errorWithCode:InvalidParameters
                                       message:@"endpointUrl must be a string"
                                       details:nil]);
            return;
        }

        NSURL *endpointNSURL = [NSURL URLWithString:endpointUrl];
        if (!endpointNSURL) {
            result([FlutterError errorWithCode:InvalidParameters
                                       message:@"Invalid URL format"
                                       details:nil]);
            return;
        }

        NSURLSessionConfiguration *localSessionConfiguration = [self.sessionConfiguration copy];
        localSessionConfiguration.allowsCellularAccess = [options[@"allowsCellularAccess"] boolValue];

        TUSSession *session = [[TUSSession alloc] initWithEndpoint:endpointNSURL
                                                          dataStore:self.tusUploadStore
                                             sessionConfiguration:localSessionConfiguration];
        [self.tusSessions setValue:session forKey:endpointUrl];

        for (TUSResumableUpload *upload in [session restoreAllUploads]) {
            [self setupUploadCallbacks:upload endpointUrl:endpointUrl];
        }

        [session resumeAll];
        result(@{@"endpointUrl": endpointUrl});
    } else if ([@"createUploadFromFile" isEqualToString:call.method]) {
        NSString *endpointUrl = arguments[@"endpointUrl"];
        NSString *fileUploadUrl = arguments[@"fileUploadUrl"];

        if (![endpointUrl isKindOfClass:[NSString class]] || ![fileUploadUrl isKindOfClass:[NSString class]]) {
            result([FlutterError errorWithCode:InvalidParameters
                                       message:@"endpointUrl and fileUploadUrl must be strings"
                                       details:nil]);
            return;
        }

        NSURL *uploadFromFile = [NSURL fileURLWithPath:fileUploadUrl];
        if (![[NSFileManager defaultManager] fileExistsAtPath:uploadFromFile.path]) {
            result([FlutterError errorWithCode:InvalidParameters
                                       message:@"File does not exist"
                                       details:nil]);
            return;
        }

        TUSSession *localTusSession = [self.tusSessions objectForKey:endpointUrl];
        if (!localTusSession) {
            result([FlutterError errorWithCode:InvalidParameters
                                       message:@"Invalid endpointUrl provided"
                                       details:nil]);
            return;
        }

        NSDictionary *headers = [arguments[@"headers"] isKindOfClass:[NSDictionary class]] ? arguments[@"headers"] : @{};
        NSDictionary *metadata = [arguments[@"metadata"] isKindOfClass:[NSDictionary class]] ? arguments[@"metadata"] : @{};

        @try {
            TUSResumableUpload *upload = [localTusSession createUploadFromFile:uploadFromFile
                                                                          retry:3
                                                                        headers:headers
                                                                       metadata:metadata];

            [self setupUploadCallbacks:upload endpointUrl:endpointUrl];
            [upload uploadFile];
            result(@{@"inProgress": @YES});
        } @catch (NSException *exception) {
            result([FlutterError errorWithCode:exception.name
                                       message:exception.reason
                                       details:exception.callStackSymbols]);
        }
    } else {
        result(FlutterMethodNotImplemented);
    }
}

- (void)setupUploadCallbacks:(TUSResumableUpload *)upload endpointUrl:(NSString *)endpointUrl {
    upload.progressBlock = ^(int64_t bytesWritten, int64_t bytesTotal) {
        [self.channel invokeMethod:@"progressBlock" arguments:@{
            @"bytesWritten": @(bytesWritten),
            @"bytesTotal": @(bytesTotal),
            @"endpointUrl": endpointUrl
        }];
    };

    upload.resultBlock = ^(NSURL *fileUrl) {
        [self.channel invokeMethod:@"resultBlock" arguments:@{
            @"resultUrl": fileUrl.absoluteString,
            @"endpointUrl": endpointUrl
        }];
    };

    upload.failureBlock = ^(NSError * _Nonnull error) {
        [self.channel invokeMethod:@"failureBlock" arguments:@{
            @"error": error.localizedDescription,
            @"endpointUrl": endpointUrl
        }];
    };
}



@end
