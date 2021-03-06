//
//  SFDatabaseManager.m
//  Pods
//
//  Created by Derek on 28/9/2016.
//
//

#import "SFDatabaseManager.h"

// Frameworks
#import <MagicalRecord/MagicalRecord.h>
#import <MagicalRecord/NSManagedObjectContext+MagicalSaves.h>

// Models
#import "SFLog.h"

// Categories
#import "NSString+SFAddition.h"
#import "NSDictionary+SFAddition.h"

@interface SFDatabaseManager ()

@property (nonatomic, strong) NSString *storeName;

@end

@implementation SFDatabaseManager

#pragma mark - Singleton

+ (instancetype)sharedInstance
{
    static id sharedInstance = nil;
    static dispatch_once_t onceToken;
    
    dispatch_once(&onceToken, ^{
        
        sharedInstance = [[[self class] alloc] init];
    });
    
    return sharedInstance;
}

#pragma mark - Setup

- (void)setupWithStoreName:(NSString *)storeName {
    
    self.storeName = storeName;
    [self setup];
}

- (void)setup {
    
    [MagicalRecord setLoggingLevel:MagicalRecordLoggingLevelOff];
    [MagicalRecord setupCoreDataStackWithStoreNamed:[self store]];
    
    SFLogDB(@"Database setup completed");
}

#pragma mark - Public

- (void)reset {
    
    NSURL *storeURL = [NSPersistentStore MR_urlForStoreName:[self store]];
    NSURL *walURL = [[storeURL URLByDeletingPathExtension] URLByAppendingPathExtension:@"sqlite-wal"];
    NSURL *shmURL = [[storeURL URLByDeletingPathExtension] URLByAppendingPathExtension:@"sqlite-shm"];
    
    NSError *error = nil;
    BOOL result = YES;
    
    for (NSURL *url in @[storeURL, walURL, shmURL]) {
        
        if ([[NSFileManager defaultManager] fileExistsAtPath:url.path]) {
            
            result = [[NSFileManager defaultManager] removeItemAtURL:url error:&error];
        }
    }
    
    if (result) {
        
        [MagicalRecord cleanUp];
        [self setup];
        
    } else {
        
        SFLogDB(@"An error has occurred while deleting %@ error %@", self.store, error);
    }
}

- (void)createOrUpdateAPICacheWithURL:(NSString *)url
                               method:(NSString *)method
                           parameters:(NSDictionary *)parameters
                             response:(NSDictionary *)response
                    cachePeriodInSecs:(CGFloat)cachePeriodInSecs
                             complete:(SFDatabaseCompletionBlock)complete {
    
    __weak typeof(self) weakSelf = self;
    [MagicalRecord saveWithBlock:^(NSManagedObjectContext * _Nonnull localContext) {
        
        SFDBAPICache *model = [weakSelf getAPICacheWithURL:url method:method parameters:parameters context:localContext];
        
        if (!model) {
            
            model = [SFDBAPICache MR_createEntityInContext:localContext];
        }
        
        model.url = url;
        model.method = method;
        model.parametersString = [parameters toJSONString];
        model.response = [NSDictionary dictionaryWithDictionary:response];
        model.expiryDate = [NSDate dateWithTimeIntervalSinceNow:cachePeriodInSecs];
        
        [self logAPICacheLogWithURL:url method:method parameters:parameters cachePeriodInSecs:cachePeriodInSecs expiryDate:model.expiryDate isExpired:NO];
        
    } completion:^(BOOL contextDidSave, NSError * _Nullable error) {
        
        if (complete) {
            
            complete(!error);
        }
    }];
}

- (SFDBAPICache *)getAPICacheWithURL:(NSString *)url
                              method:(NSString *)method
                          parameters:(NSDictionary *)parameters
                             context:(NSManagedObjectContext *)context {
    
    NSPredicate *urlFilter = [NSPredicate predicateWithFormat:@"url contains[cd] %@", url];
    NSPredicate *methodFilter = [NSPredicate predicateWithFormat:@"method contains[cd] %@", method];
    
    NSMutableArray *filters = [NSMutableArray arrayWithObjects:urlFilter, methodFilter, nil];
    
    if (parameters) {
        
        NSString *parametersString = [parameters toJSONString];
        NSPredicate *parameterFilter = [NSPredicate predicateWithFormat:@"parametersString contains[cd] %@", parametersString];
        [filters addObject:parameterFilter];
    }
    
    NSPredicate *finalFilter = [NSCompoundPredicate andPredicateWithSubpredicates:filters];
    
    SFDBAPICache *model = context ? [SFDBAPICache MR_findFirstWithPredicate:finalFilter inContext:context] : [SFDBAPICache MR_findFirstWithPredicate:finalFilter];
    
    if (model) {
        
        BOOL isExpiried = [model.expiryDate timeIntervalSinceNow] < 0;
        
        if (isExpiried) {
            
            [self logAPICacheLogWithURL:url method:method parameters:parameters cachePeriodInSecs:0 expiryDate:model.expiryDate isExpired:YES];
            
            [MagicalRecord saveWithBlockAndWait:^(NSManagedObjectContext * _Nonnull localContext) {
                
                [model MR_deleteEntityInContext:localContext];
            }];
            model = nil;
        }
    }
    
    return model;
}

- (SFDBAPICache *)getAPICacheWithURL:(NSString *)url
                              method:(NSString *)method
                          parameters:(NSDictionary *)parameters {
    
    return [self getAPICacheWithURL:url method:method parameters:parameters context:nil];
}

#pragma mark - Helpers

- (void)logAPICacheLogWithURL:(NSString *)url
                       method:(NSString *)method
                   parameters:(NSDictionary *)parameters
            cachePeriodInSecs:(CGFloat)cachePeriodInSecs
                   expiryDate:(NSDate *)expiryDate
                    isExpired:(BOOL)isExpired {
    
    NSMutableString *log = [NSMutableString new];
    
    if (isExpired) {
        
        [log appendString:@"---Expired API cache---\n"];
        
    } else {
        
        [log appendString:@"---Write API cache---\n"];
    }
    
    [log appendFormat:@"URL: %@\n", url];
    [log appendFormat:@"Method: %@\n", method];
    [log appendFormat:@"Parameters: %@\n", parameters];
    
    if (!isExpired) {
        
        [log appendFormat:@"CacheFor: %.f sec\n", cachePeriodInSecs];
    }
    
    NSDateFormatter *formatter = [NSDateFormatter new];
    formatter.locale = [NSLocale currentLocale];
    formatter.dateStyle = NSDateFormatterMediumStyle;
    formatter.timeStyle = NSDateFormatterLongStyle;
    NSString *dateString = [formatter stringFromDate:expiryDate];
    
    [log appendFormat:@"ExpiryDate: %@\n", dateString];
    
    if (isExpired) {
        
        [log appendString:@"---Expired API cache---\n"];
        
    } else {
        
        [log appendString:@"---Write API cache---\n"];
    }
    
    SFLogDB(@"%@", log);
}

- (NSString *)store {
    
    return [NSString stringWithFormat:@"%@.sqlite", self.storeName];
}

@end
