//
//  Copyright (c) 2018 Open Whisper Systems. All rights reserved.
//

#import "OWSBackupExport.h"

//#import "NSUserDefaults+OWS.h"
#import "Signal-Swift.h"
#import "zlib.h"

//#import <SAMKeychain/SAMKeychain.h>
#import <SSZipArchive/SSZipArchive.h>

//#import <SignalMessaging/SignalMessaging-Swift.h>
//#import <SignalServiceKit/Cryptography.h>
#import <SignalServiceKit/OWSFileSystem.h>

//#import <SignalServiceKit/OWSPrimaryStorage.h>
//#import "NSNotificationCenter+OWS.h"
#import <Curve25519Kit/Randomness.h>
#import <SignalServiceKit/NSDate+OWS.h>
#import <SignalServiceKit/OWSBackgroundTask.h>
#import <SignalServiceKit/OWSBackupStorage.h>
#import <SignalServiceKit/OWSError.h>
#import <SignalServiceKit/TSMessage.h>
#import <SignalServiceKit/TSThread.h>
#import <SignalServiceKit/Threading.h>
#import <SignalServiceKit/YapDatabaseConnection+OWS.h>
#import <YapDatabase/YapDatabase.h>
#import <YapDatabase/YapDatabaseCryptoUtils.h>

// NSString *const NSNotificationNameBackupStateDidChange = @"NSNotificationNameBackupStateDidChange";
//
// NSString *const OWSPrimaryStorage_OWSBackupCollection = @"OWSPrimaryStorage_OWSBackupCollection";
// NSString *const OWSBackup_IsBackupEnabledKey = @"OWSBackup_IsBackupEnabledKey";

NS_ASSUME_NONNULL_BEGIN

typedef void (^OWSBackupExportBoolCompletion)(BOOL success);
typedef void (^OWSBackupExportCompletion)(NSError *_Nullable error);

//// Hide the "import" directories from exports, etc. by prefixing their name with a period.
////
//// OWSBackup backs up files and directories in the "app documents" and "shared data container",
//// but ignores any top-level files or directories in those locations whose names start with a
//// period ".".
// NSString *const OWSBackup_DirNamePrefix = @".SignalBackup.";
// NSString *const OWSBackup_FileExtension = @".signalbackup";
// NSString *const OWSBackup_EncryptionKeyFilename = @".encryptionKey";
// NSString *const OWSBackup_DatabasePasswordFilename = @".databasePassword";
// NSString *const OWSBackup_StandardUserDefaultsFilename = @".standardUserDefaults";
// NSString *const OWSBackup_AppUserDefaultsFilename = @".appUserDefaults";
// NSString *const OWSBackup_AppDocumentDirName = @"appDocumentDirectoryPath";
// NSString *const OWSBackup_AppSharedDataDirName = @"appSharedDataDirectoryPath";
//
// NSString *const NSUserDefaults_QueuedBackupPath = @"NSUserDefaults_QueuedBackupPath";
//
// NSString *const Keychain_ImportBackupService = @"OWSKeychainService";
// NSString *const Keychain_ImportBackupKey = @"ImportBackupKey";

@interface OWSBackupExport () <SSZipArchiveDelegate>

@property (nonatomic, weak) id<OWSBackupExportDelegate> delegate;

@property (nonatomic, nullable) YapDatabaseConnection *srcDBConnection;

@property (nonatomic, nullable) YapDatabaseConnection *dstDBConnection;

// Indicates that the backup succeeded, failed or was cancelled.
@property (atomic) BOOL isComplete;

@property (nonatomic, nullable) OWSBackupStorage *backupStorage;

@property (nonatomic, nullable) NSData *databaseSalt;

@property (nonatomic, nullable) OWSBackgroundTask *backgroundTask;

@property (nonatomic) NSMutableArray<NSString *> *databaseFilePaths;
// A map of "record name"-to-"file name".
@property (nonatomic) NSMutableDictionary<NSString *, NSString *> *databaseRecordMap;

@property (nonatomic, nullable) NSString *manifestFilePath;
@property (nonatomic, nullable) NSString *manifestRecordName;

@property (nonatomic) NSString *exportDirPath;
//- (NSData *)databasePassword;
//
//+ (void)storeDatabasePassword:(NSString *)password;

//@end
//
//#pragma mark -
//
//@interface OWSBackupExport () <SSZipArchiveDelegate>

//@property (nonatomic) OWSBackupState backupState;
//
//@property (nonatomic) CGFloat backupProgress;
//
//@property (nonatomic, nullable) TSThread *currentThread;
//
//@property (nonatomic, nullable) NSString *backupPassword;
//
//@property (nonatomic) NSString *backupDirPath;
//@property (nonatomic) NSString *backupZipPath;
//
//@property (nonatomic) OWSAES256Key *encryptionKey;

@end

#pragma mark -

@implementation OWSBackupExport

//@synthesize dbConnection = _dbConnection;

//+ (instancetype)sharedManager
//{
//    static OWSBackup *sharedMyManager = nil;
//    static dispatch_once_t onceToken;
//    dispatch_once(&onceToken, ^{
//        sharedMyManager = [[self alloc] initDefault];
//    });
//    return sharedMyManager;
//}
//
//- (instancetype)initDefault
//{
//    OWSPrimaryStorage *primaryStorage = [OWSPrimaryStorage sharedManager];
//
//    return [self initWithPrimaryStorage:primaryStorage];
//}

- (instancetype)initWithDelegate:(id<OWSBackupExportDelegate>)delegate
                  primaryStorage:(OWSPrimaryStorage *)primaryStorage
{
    self = [super init];

    if (!self) {
        return self;
    }

    OWSAssert(primaryStorage);
    OWSAssert([OWSStorage isStorageReady]);

    self.delegate = delegate;
    _srcDBConnection = primaryStorage.newDatabaseConnection;

    //    _backupExportState = OWSBackupState_AtRest;

    // TODO: Remove.
    DDLogVerbose(@"%@ %s", self.logTag, __PRETTY_FUNCTION__);

    return self;
}

- (void)dealloc
{
    // Surface memory leaks by logging the deallocation.
    DDLogVerbose(@"Dealloc: %@", self.class);

    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

- (void)startAsync
{
    OWSAssertIsOnMainThread();

    DDLogInfo(@"%@ %s", self.logTag, __PRETTY_FUNCTION__);

    self.backgroundTask = [OWSBackgroundTask backgroundTaskWithLabelStr:__PRETTY_FUNCTION__];

    __weak OWSBackupExport *weakSelf = self;
    [OWSBackupAPI checkCloudKitAccessWithCompletion:^(BOOL hasAccess) {
        if (hasAccess) {
            dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
                [weakSelf start];
            });
        }
    }];
}

- (void)start
{
    __weak OWSBackupExport *weakSelf = self;
    [self configureExport:^(BOOL success) {
        if (!success) {
            [self failWithErrorDescription:
                      NSLocalizedString(@"BACKUP_EXPORT_ERROR_COULD_NOT_EXPORT",
                          @"Error indicating the a backup export could not export the user's data.")];
            return;
        }

        if (self.isComplete) {
            return;
        }
        if (![self exportDatabase]) {
            [self failWithErrorDescription:
                      NSLocalizedString(@"BACKUP_EXPORT_ERROR_COULD_NOT_EXPORT",
                          @"Error indicating the a backup export could not export the user's data.")];
            return;
        }
        if (self.isComplete) {
            return;
        }
        [self saveToCloud:^(NSError *_Nullable error) {
            if (error) {
                [weakSelf failWithError:error];
            } else {
                [weakSelf succeed];
            }
        }];
    }];
}

- (void)configureExport:(OWSBackupExportBoolCompletion)completion
{
    DDLogVerbose(@"%@ %s", self.logTag, __PRETTY_FUNCTION__);

    NSString *temporaryDirectory = NSTemporaryDirectory();
    self.exportDirPath = [temporaryDirectory stringByAppendingString:[NSUUID UUID].UUIDString];
    NSString *exportDatabaseDirPath = [self.exportDirPath stringByAppendingPathComponent:@"Database"];
    self.databaseSalt = [Randomness generateRandomBytes:(int)kSQLCipherSaltLength];

    if (![OWSFileSystem ensureDirectoryExists:self.exportDirPath]) {
        DDLogError(@"%@ Could not create exportDirPath.", self.logTag);
        return completion(NO);
    }
    if (![OWSFileSystem ensureDirectoryExists:exportDatabaseDirPath]) {
        DDLogError(@"%@ Could not create exportDatabaseDirPath.", self.logTag);
        return completion(NO);
    }
    if (!self.databaseSalt) {
        DDLogError(@"%@ Could not create databaseSalt.", self.logTag);
        return completion(NO);
    }
    __weak OWSBackupExport *weakSelf = self;
    BackupStorageKeySpecBlock keySpecBlock = ^{
        NSData *_Nullable backupKey = [weakSelf.delegate backupKey];
        if (!backupKey) {
            return (NSData *)nil;
        }
        NSData *_Nullable databaseSalt = weakSelf.databaseSalt;
        if (!databaseSalt) {
            return (NSData *)nil;
        }
        OWSCAssert(backupKey.length > 0);
        NSData *_Nullable keySpec =
            [YapDatabaseCryptoUtils deriveDatabaseKeySpecForPassword:backupKey saltData:databaseSalt];
        return keySpec;
    };
    self.backupStorage =
        [[OWSBackupStorage alloc] initBackupStorageWithDatabaseDirPath:exportDatabaseDirPath keySpecBlock:keySpecBlock];
    if (!self.backupStorage) {
        DDLogError(@"%@ Could not create backupStorage.", self.logTag);
        return completion(NO);
    }
    _dstDBConnection = self.backupStorage.newDatabaseConnection;
    if (!self.dstDBConnection) {
        DDLogError(@"%@ Could not create dstDBConnection.", self.logTag);
        return completion(NO);
    }

    // TODO: Do we really need to run these registrations on the main thread?
    dispatch_async(dispatch_get_main_queue(), ^{
        [self.backupStorage runSyncRegistrations];
        [self.backupStorage runAsyncRegistrationsWithCompletion:^{
            dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
                completion(YES);
            });
        }];
    });

    //    // The backup storage is empty and therefore async registrations should
    //    // complete very quickly.  We'll wait a short period for them to complete.
    //    NSDate *readyStart = [NSDate new];
    //    while (YES) {
    //        if (self.backupStorage.areAllRegistrationsComplete) {
    //            return YES;
    //        }
    //        DDLogVerbose(@"%@ waiting for backup storage: %f %f", self.logTag, readyStart.timeIntervalSinceNow,
    //        kMinuteInterval); if (fabs(readyStart.timeIntervalSinceNow) > kMinuteInterval) {
    //            return NO;
    //        }
    //        // Sleep 100 ms.
    //        usleep(100 * 1000);
    //    }
}

- (BOOL)exportDatabase
{
    DDLogVerbose(@"%@ %s", self.logTag, __PRETTY_FUNCTION__);

    __block unsigned long long copiedThreads = 0;
    __block unsigned long long copiedInteractions = 0;
    __block unsigned long long copiedEntities = 0;

    [self.srcDBConnection readWithBlock:^(YapDatabaseReadTransaction *srcTransaction) {
        [self.dstDBConnection readWriteWithBlock:^(YapDatabaseReadWriteTransaction *dstTransaction) {
            // Copy threads.
            [srcTransaction
                enumerateKeysAndObjectsInCollection:[TSThread collection]
                                         usingBlock:^(NSString *key, id object, BOOL *stop) {
                                             if (self.isComplete) {
                                                 *stop = YES;
                                                 return;
                                             }
                                             if (![object isKindOfClass:[TSThread class]]) {
                                                 DDLogError(@"%@ unexpected class: %@", self.logTag, [object class]);
                                                 return;
                                             }
                                             TSThread *thread = object;
                                             [thread saveWithTransaction:dstTransaction];
                                             copiedThreads++;
                                             copiedEntities++;
                                         }];

            // Copy interactions.
            [srcTransaction
                enumerateKeysAndObjectsInCollection:[TSInteraction collection]
                                         usingBlock:^(NSString *key, id object, BOOL *stop) {
                                             if (self.isComplete) {
                                                 *stop = YES;
                                                 return;
                                             }
                                             if (![object isKindOfClass:[TSInteraction class]]) {
                                                 DDLogError(@"%@ unexpected class: %@", self.logTag, [object class]);
                                                 return;
                                             }
                                             // Ignore disappearing messages.
                                             if ([object isKindOfClass:[TSMessage class]]) {
                                                 TSMessage *message = object;
                                                 if (message.isExpiringMessage) {
                                                     return;
                                                 }
                                             }
                                             TSInteraction *interaction = object;
                                             // Ignore dynamic interactions.
                                             if (interaction.isDynamicInteraction) {
                                                 return;
                                             }
                                             [interaction saveWithTransaction:dstTransaction];
                                             copiedInteractions++;
                                             copiedEntities++;
                                         }];

            // TODO: Copy attachments.
        }];
    }];

    // TODO: Should we do a database checkpoint?

    DDLogInfo(@"%@ copiedThreads: %llu", self.logTag, copiedThreads);
    DDLogInfo(@"%@ copiedMessages: %llu", self.logTag, copiedInteractions);
    DDLogInfo(@"%@ copiedEntities: %llu", self.logTag, copiedEntities);

    [self.backupStorage logFileSizes];

    // Capture the list of files to save.
    self.databaseFilePaths = [@[
        self.backupStorage.databaseFilePath,
        self.backupStorage.databaseFilePath_WAL,
        self.backupStorage.databaseFilePath_SHM,
    ] mutableCopy];

    // Close the database.
    self.dstDBConnection = nil;
    self.backupStorage = nil;

    return YES;
}

- (void)saveToCloud:(OWSBackupExportCompletion)completion
{
    DDLogVerbose(@"%@ %s", self.logTag, __PRETTY_FUNCTION__);

    self.databaseRecordMap = [NSMutableDictionary new];

    [self saveNextFileToCloud:completion];
}

- (void)saveNextFileToCloud:(OWSBackupExportCompletion)completion
{
    if (self.isComplete) {
        return;
    }

    __weak OWSBackupExport *weakSelf = self;

    if (self.databaseFilePaths.count > 0) {
        NSString *filePath = self.databaseFilePaths.lastObject;
        [self.databaseFilePaths removeLastObject];
        // Database files are encrypted and can be safely stored unencrypted in the cloud.
        // TODO: Security review.
        [OWSBackupAPI saveBackupFileToCloudWithFileUrl:[NSURL fileURLWithPath:filePath]
            success:^(NSString *recordName) {
                // Ensure that we continue to perform the backup export
                // off the main thread.
                dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
                    OWSBackupExport *strongSelf = weakSelf;
                    if (!strongSelf) {
                        return;
                    }
                    strongSelf.databaseRecordMap[recordName] = [filePath lastPathComponent];
                    [strongSelf saveNextFileToCloud:completion];
                });
            }
            failure:^(NSError *error) {
                // Database files are critical so any error uploading them is unrecoverable.
                completion(error);
            }];
        return;
    }

    if (!self.manifestFilePath) {
        if (![self writeManifestFile]) {
            completion(OWSErrorWithCodeDescription(OWSErrorCodeExportBackupFailed,
                NSLocalizedString(@"BACKUP_EXPORT_ERROR_COULD_NOT_EXPORT",
                    @"Error indicating the a backup export could not export the user's data.")));
            return;
        }
        OWSAssert(self.manifestFilePath);

        [OWSBackupAPI saveBackupFileToCloudWithFileUrl:[NSURL fileURLWithPath:self.manifestFilePath]
            success:^(NSString *recordName) {
                // Ensure that we continue to perform the backup export
                // off the main thread.
                dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
                    OWSBackupExport *strongSelf = weakSelf;
                    if (!strongSelf) {
                        return;
                    }
                    strongSelf.manifestRecordName = recordName;
                    [strongSelf saveNextFileToCloud:completion];
                });
            }
            failure:^(NSError *error) {
                // The manifest file is critical so any error uploading them is unrecoverable.
                completion(error);
            }];
        return;
    }


    // All files have been saved to the cloud.
    completion(nil);
}

- (BOOL)writeManifestFile
{
    OWSAssert(self.databaseRecordMap.count > 0);
    OWSAssert(self.exportDirPath.length > 0);

    NSDictionary *json = @{
        @"database_files" : self.databaseRecordMap,
    };
    NSError *error;
    NSData *_Nullable jsonData =
        [NSJSONSerialization dataWithJSONObject:json options:NSJSONWritingPrettyPrinted error:&error];
    if (!jsonData || error) {
        DDLogError(@"%@ error encoding manifest file: %@", self.logTag, error);
        return NO;
    }
    // TODO: Encrypt the manifest.
    self.manifestFilePath = [self.exportDirPath stringByAppendingPathComponent:@"manifest.json"];
    if (![jsonData writeToFile:self.manifestFilePath atomically:YES]) {
        DDLogError(@"%@ error writing manifest file: %@", self.logTag, error);
        return NO;
    }
    return YES;
}

- (void)cancel
{
    OWSAssertIsOnMainThread();

    // TODO:
    self.isComplete = YES;
}

- (void)succeed
{
    DDLogInfo(@"%@ %s", self.logTag, __PRETTY_FUNCTION__);

    dispatch_async(dispatch_get_main_queue(), ^{
        if (self.isComplete) {
            return;
        }
        self.isComplete = YES;
        [self.delegate backupExportDidSucceed:self];
    });
    // TODO:
}

- (void)failWithErrorDescription:(NSString *)description
{
    [self failWithError:OWSErrorWithCodeDescription(OWSErrorCodeExportBackupFailed, description)];
}

- (void)failWithError:(NSError *)error
{
    DDLogError(@"%@ %s %@", self.logTag, __PRETTY_FUNCTION__, error);

    // TODO:

    dispatch_async(dispatch_get_main_queue(), ^{
        if (self.isComplete) {
            return;
        }
        self.isComplete = YES;
        [self.delegate backupExportDidFail:self error:error];
    });
}

//- (void)observeNotifications
//{
//    [[NSNotificationCenter defaultCenter] addObserver:self
//                                             selector:@selector(applicationDidBecomeActive:)
//                                                 name:OWSApplicationDidBecomeActiveNotification
//                                               object:nil];
//}

//- (void)dealloc
//{
//    DDLogInfo(@"%@ Cleaning up: %@", self.logTag, self.backupDirPath);
//    [OWSFileSystem deleteFileIfExists:self.backupDirPath];
//
//    dispatch_async(dispatch_get_main_queue(), ^{
//        [OWSBackup cleanupBackupState];
//    });
//}

//- (void)setBackupExportState:(OWSBackupState)backupExportState
//{
//    _backupExportState = backupExportState;
//
//    [[NSNotificationCenter defaultCenter] postNotificationNameAsync:NSNotificationNameBackupStateDidChange
//                                                             object:nil
//                                                           userInfo:nil];
//}
//
//- (BOOL)isBackupEnabled
//{
//    return [self.dbConnection boolForKey:OWSBackup_IsBackupEnabledKey
//                            inCollection:OWSPrimaryStorage_OWSBackupCollection
//                            defaultValue:NO];
//}
//
//- (void)setIsBackupEnabled:(BOOL)value
//{
//    [self.dbConnection setBool:value
//                        forKey:OWSBackup_IsBackupEnabledKey
//                  inCollection:OWSPrimaryStorage_OWSBackupCollection];
//
//    [[NSNotificationCenter defaultCenter] postNotificationNameAsync:NSNotificationNameBackupStateDidChange
//                                                             object:nil
//                                                           userInfo:nil];
//}

//- (void)setBackupProgress:(CGFloat)backupProgress
//{
//    _backupProgress = backupProgress;
//
//    dispatch_async(dispatch_get_main_queue(), ^{
//        [self.delegate backupProgressDidChange];
//    });
//}
//
//- (void)fail
//{
//    DDLogInfo(@"%@ %s.", self.logTag, __PRETTY_FUNCTION__);
//
//    if (!self.isCancelledOrFailed) {
//        self.backupState = OWSBackupState_Failed;
//    }
//
//    dispatch_async(dispatch_get_main_queue(), ^{
//        [OWSBackup cleanupBackupState];
//    });
//}
//
//- (void)cancel
//{
//    DDLogInfo(@"%@ %s.", self.logTag, __PRETTY_FUNCTION__);
//
//    if (!self.isCancelledOrFailed) {
//        self.backupState = OWSBackupState_Cancelled;
//    }
//
//    dispatch_async(dispatch_get_main_queue(), ^{
//        [OWSBackup cleanupBackupState];
//    });
//}
//
//- (void)complete
//{
//    DDLogInfo(@"%@ %s.", self.logTag, __PRETTY_FUNCTION__);
//
//    if (!self.isCancelledOrFailed) {
//        self.backupState = OWSBackupState_Complete;
//    }
//}
//
//- (BOOL)isCancelledOrFailed
//{
//    return (self.backupState == OWSBackupState_Cancelled || self.backupState == OWSBackupState_Failed);
//}
//
//#pragma mark - Export Backup
//
//- (void)exportBackup:(nullable TSThread *)currentThread skipPassword:(BOOL)skipPassword
//{
//    OWSAssertIsOnMainThread();
//    OWSAssert(CurrentAppContext().isMainApp);
//
//    DDLogInfo(@"%@ %s.", self.logTag, __PRETTY_FUNCTION__);
//
//    self.currentThread = currentThread;
//    self.backupState = OWSBackupState_InProgress;
//
//    if (skipPassword) {
//        DDLogInfo(@"%@ backup export without password", self.logTag);
//    } else {
//        // TODO: Should the user pick a password?
//        //       If not, should probably generate something more user-friendly,
//        //       e.g. case-insensitive set of hexadecimal?
//        NSString *backupPassword = [NSUUID UUID].UUIDString;
//        self.backupPassword = backupPassword;
//        DDLogInfo(@"%@ backup export with password: %@", self.logTag, backupPassword);
//    }
//
//    [self startExport];
//}
//
//- (void)startExport
//{
//    OWSAssertIsOnMainThread();
//
//    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
//        [self exportToFilesAndZip];
//
//        dispatch_async(dispatch_get_main_queue(), ^{
//            [self complete];
//        });
//    });
//}
//
//- (void)exportToFilesAndZip
//{
//    DDLogInfo(@"%@ %s.", self.logTag, __PRETTY_FUNCTION__);
//
//    // First, clean up any existing backup import/export state.
//    [OWSBackup cleanupBackupState];
//
//    NSString *temporaryDirectory = NSTemporaryDirectory();
//    NSString *rootDirName = [OWSBackup_DirNamePrefix stringByAppendingString:[NSUUID UUID].UUIDString];
//    NSString *rootDirPath = [temporaryDirectory stringByAppendingPathComponent:rootDirName];
//    NSString *backupDirPath = [rootDirPath stringByAppendingPathComponent:@"Contents"];
//
//    NSDateFormatter *dateFormatter = [NSDateFormatter new];
//    [dateFormatter setLocale:[NSLocale currentLocale]];
//    [dateFormatter setDateFormat:@"yyyy.MM.dd hh.mm.ss"];
//    NSString *backupDateTime = [dateFormatter stringFromDate:[NSDate new]];
//    NSString *backupName =
//        [NSString stringWithFormat:NSLocalizedString(@"BACKUP_FILENAME_FORMAT",
//                                       @"Format for backup filenames. Embeds: {{the date and time of the backup}}. "
//                                       @"Should not include characters like slash (/ or \\) or colon (:)."),
//                  backupDateTime];
//    NSString *backupZipPath =
//        [rootDirPath stringByAppendingPathComponent:[backupName stringByAppendingString:OWSBackup_FileExtension]];
//    self.backupDirPath = backupDirPath;
//    self.backupZipPath = backupZipPath;
//    DDLogInfo(@"%@ rootDirPath: %@", self.logTag, rootDirPath);
//    DDLogInfo(@"%@ backupDirPath: %@", self.logTag, backupDirPath);
//    DDLogInfo(@"%@ backupZipPath: %@", self.logTag, backupZipPath);
//
//    [OWSFileSystem ensureDirectoryExists:rootDirPath];
//    [OWSFileSystem protectFileOrFolderAtPath:rootDirPath];
//    [OWSFileSystem ensureDirectoryExists:backupDirPath];
//
//    if (self.isCancelledOrFailed) {
//        return;
//    }
//
//    OWSAES256Key *encryptionKey = [OWSAES256Key generateRandomKey];
//    self.encryptionKey = encryptionKey;
//
//    NSData *databasePassword = [OWSPrimaryStorage sharedManager].databasePassword;
//
//    // TODO: We don't want this to reside unencrypted on disk even temporarily.
//    // We need to encrypt this with a key that we hide in the keychain.
//    if (![self writeData:databasePassword
//                 fileName:OWSBackup_DatabasePasswordFilename
//            backupDirPath:backupDirPath
//            encryptionKey:encryptionKey]) {
//        return [self fail];
//    }
//    if (self.isCancelledOrFailed) {
//        return;
//    }
//    if (![self writeUserDefaults:NSUserDefaults.standardUserDefaults
//                        fileName:OWSBackup_StandardUserDefaultsFilename
//                   backupDirPath:backupDirPath
//                   encryptionKey:encryptionKey]) {
//        return [self fail];
//    }
//    if (self.isCancelledOrFailed) {
//        return;
//    }
//    if (![self writeUserDefaults:NSUserDefaults.appUserDefaults
//                        fileName:OWSBackup_AppUserDefaultsFilename
//                   backupDirPath:backupDirPath
//                   encryptionKey:encryptionKey]) {
//        return [self fail];
//    }
//    if (self.isCancelledOrFailed) {
//        return;
//    }
//    // Use a read/write transaction to acquire a file lock on the database files.
//    //
//    // TODO: If we use multiple database files, lock them too.
//    [OWSPrimaryStorage.sharedManager.newDatabaseConnection
//        readWriteWithBlock:^(YapDatabaseReadWriteTransaction *_Nonnull transaction) {
//            if (![self copyDirectory:OWSFileSystem.appDocumentDirectoryPath
//                          dstDirName:OWSBackup_AppDocumentDirName
//                       backupDirPath:backupDirPath]) {
//                [self fail];
//                return;
//            }
//            if (self.isCancelledOrFailed) {
//                return;
//            }
//            if (![self copyDirectory:OWSFileSystem.appSharedDataDirectoryPath
//                          dstDirName:OWSBackup_AppSharedDataDirName
//                       backupDirPath:backupDirPath]) {
//                [self fail];
//                return;
//            }
//        }];
//    if (self.isCancelledOrFailed) {
//        return;
//    }
//    if (![self zipDirectory:backupDirPath dstFilePath:backupZipPath encryptionKey:encryptionKey]) {
//        return [self fail];
//    }
//
//    [OWSFileSystem protectFileOrFolderAtPath:backupZipPath];
//
//    [OWSFileSystem deleteFileIfExists:self.backupDirPath];
//}
//
//- (BOOL)writeData:(NSData *)data
//         fileName:(NSString *)fileName
//    backupDirPath:(NSString *)backupDirPath
//    encryptionKey:(OWSAES256Key *)encryptionKey
//{
//    OWSAssert(data);
//    OWSAssert(fileName.length > 0);
//    OWSAssert(backupDirPath.length > 0);
//    OWSAssert(encryptionKey);
//
//    NSData *_Nullable encryptedData = [Cryptography encryptAESGCMWithData:data key:encryptionKey];
//    if (!encryptedData) {
//        OWSFail(@"%@ failed to encrypt data: %@", self.logTag, fileName);
//        return NO;
//    }
//
//    NSString *filePath = [backupDirPath stringByAppendingPathComponent:fileName];
//
//    DDLogInfo(@"%@ writeData: %@", self.logTag, filePath);
//
//    NSError *error;
//    BOOL success = [encryptedData writeToFile:filePath options:NSDataWritingAtomic error:&error];
//    if (!success || error) {
//        OWSFail(@"%@ failed to write user defaults: %@", self.logTag, error);
//        return NO;
//    }
//    return YES;
//}
//
//- (BOOL)copyDirectory:(NSString *)srcDirPath dstDirName:(NSString *)dstDirName backupDirPath:(NSString *)backupDirPath
//{
//    OWSAssert(srcDirPath.length > 0);
//    OWSAssert(dstDirName.length > 0);
//    OWSAssert(backupDirPath.length > 0);
//
//    NSString *dstDirPath = [backupDirPath stringByAppendingPathComponent:dstDirName];
//
//    DDLogInfo(@"%@ copyDirectory: %@ -> %@", self.logTag, srcDirPath, dstDirPath);
//
//    // We "manually" copy the "root" items in the src directory.
//    // Can't just use [NSFileManager copyItemAtPath:...] because the shared data container
//    // contains files that the app is not allowed to access.
//    [OWSFileSystem ensureDirectoryExists:dstDirPath];
//    NSError *error = nil;
//    NSArray<NSString *> *fileNames = [[NSFileManager defaultManager] contentsOfDirectoryAtPath:srcDirPath
//    error:&error]; if (error) {
//        OWSFail(@"%@ failed to list directory: %@, %@", self.logTag, srcDirPath, error);
//        return NO;
//    }
//    for (NSString *fileName in fileNames) {
//        NSString *srcFilePath = [srcDirPath stringByAppendingPathComponent:fileName];
//        NSString *dstFilePath = [dstDirPath stringByAppendingPathComponent:fileName];
//        if ([fileName hasPrefix:@"."]) {
//            DDLogInfo(@"%@ ignoring: %@", self.logTag, srcFilePath);
//            continue;
//        }
//        BOOL success = [[NSFileManager defaultManager] copyItemAtPath:srcFilePath toPath:dstFilePath error:&error];
//        if (!success || error) {
//            OWSFail(@"%@ failed to copy directory item: %@, %@", self.logTag, srcFilePath, error);
//            return NO;
//        }
//    }
//
//    return YES;
//}
//
//- (BOOL)writeUserDefaults:(NSUserDefaults *)userDefaults
//                 fileName:(NSString *)fileName
//            backupDirPath:(NSString *)backupDirPath
//            encryptionKey:(OWSAES256Key *)encryptionKey
//{
//    OWSAssert(userDefaults);
//    OWSAssert(fileName.length > 0);
//    OWSAssert(backupDirPath.length > 0);
//    OWSAssert(encryptionKey);
//
//    DDLogInfo(@"%@ writeUserDefaults: %@", self.logTag, fileName);
//
//    NSDictionary<NSString *, id> *dictionary = userDefaults.dictionaryRepresentation;
//    if (!dictionary) {
//        OWSFail(@"%@ failed to extract user defaults", self.logTag);
//        return NO;
//    }
//    NSData *data = [NSKeyedArchiver archivedDataWithRootObject:dictionary];
//    if (!data) {
//        OWSFail(@"%@ failed to archive user defaults", self.logTag);
//        return NO;
//    }
//
//    return [self writeData:data fileName:fileName backupDirPath:backupDirPath encryptionKey:encryptionKey];
//}
//
//- (BOOL)zipDirectory:(NSString *)srcDirPath
//         dstFilePath:(NSString *)dstFilePath
//       encryptionKey:(OWSAES256Key *)encryptionKey
//{
//    OWSAssert(srcDirPath.length > 0);
//    OWSAssert(dstFilePath.length > 0);
//    OWSAssert(encryptionKey);
//
//    DDLogInfo(@"%@ %s.", self.logTag, __PRETTY_FUNCTION__);
//
//    srcDirPath = [srcDirPath stringByStandardizingPath];
//    OWSAssert(srcDirPath.length > 0);
//
//    NSError *error;
//    NSArray<NSString *> *_Nullable srcFilePaths = [OWSFileSystem allFilesInDirectoryRecursive:srcDirPath
//    error:&error]; if (!srcFilePaths || error) {
//        OWSFail(@"%@ failed to find files to zip: %@", self.logTag, error);
//        return NO;
//    }
//
//    // Don't use the SSZipArchive convenience methods so that we can add the
//    // encryption key directly as data.
//    SSZipArchive *zipArchive = [[SSZipArchive alloc] initWithPath:dstFilePath];
//    if (![zipArchive open]) {
//        OWSFail(@"%@ failed to open zip file.", self.logTag);
//        return NO;
//    }
//    for (NSString *srcFilePath in srcFilePaths) {
//        NSString *relativePath = [self relativePathforPath:srcFilePath basePath:srcDirPath];
//        BOOL success = [zipArchive writeFileAtPath:srcFilePath
//                                      withFileName:relativePath
//                                  compressionLevel:Z_DEFAULT_COMPRESSION
//                                          password:self.backupPassword
//                                               AES:self.backupPassword != nil];
//        if (!success) {
//            OWSFail(@"%@ failed to write file to zip file.", self.logTag);
//            return NO;
//        }
//    }
//    // Write the encryption key directly into the zip so that it never
//    // resides in plaintext on disk.
//    BOOL success = [zipArchive writeData:encryptionKey.keyData
//                                filename:OWSBackup_EncryptionKeyFilename
//                        compressionLevel:Z_DEFAULT_COMPRESSION
//                                password:self.backupPassword
//                                     AES:self.backupPassword != nil];
//    if (!success) {
//        OWSFail(@"%@ failed to write file to zip file.", self.logTag);
//        return NO;
//    }
//
//
//    if (![zipArchive close]) {
//        OWSFail(@"%@ failed to close zip file.", self.logTag);
//        return NO;
//    }
//
//    NSNumber *fileSize = [[NSFileManager defaultManager] attributesOfItemAtPath:dstFilePath error:&error][NSFileSize];
//    if (error) {
//        OWSFail(@"%@ failed to get zip file size: %@", self.logTag, error);
//        return NO;
//    }
//    DDLogInfo(@"%@ Zip file size: %@", self.logTag, fileSize);
//
//    return YES;
//}
//
//#pragma mark - Import Backup, Part 1
//
//- (void)importBackup:(NSString *)srcZipPath password:(NSString *_Nullable)password
//{
//    OWSAssertIsOnMainThread();
//    OWSAssert(srcZipPath.length > 0);
//    OWSAssert(CurrentAppContext().isMainApp);
//
//    DDLogInfo(@"%@ %s.", self.logTag, __PRETTY_FUNCTION__);
//
//    self.backupPassword = password;
//
//    self.backupState = OWSBackupState_InProgress;
//
//    if (password.length == 0) {
//        DDLogInfo(@"%@ backup import without password", self.logTag);
//    } else {
//        DDLogInfo(@"%@ backup import with password: %@", self.logTag, password);
//    }
//
//    [self startImport:srcZipPath];
//}
//
//- (void)startImport:(NSString *)srcZipPath
//{
//    OWSAssertIsOnMainThread();
//    OWSAssert(srcZipPath.length > 0);
//
//    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
//        [self prepareForImport:srcZipPath];
//
//        dispatch_async(dispatch_get_main_queue(), ^{
//            [self complete];
//        });
//    });
//}
//
//- (void)prepareForImport:(NSString *)srcZipPath
//{
//    OWSAssert(srcZipPath.length > 0);
//
//    DDLogInfo(@"%@ %s.", self.logTag, __PRETTY_FUNCTION__);
//
//    NSString *documentDirectoryPath = OWSFileSystem.appDocumentDirectoryPath;
//    NSString *rootDirName = [OWSBackup_DirNamePrefix stringByAppendingString:[NSUUID UUID].UUIDString];
//    NSString *rootDirPath = [documentDirectoryPath stringByAppendingPathComponent:rootDirName];
//    NSString *backupDirPath = [rootDirPath stringByAppendingPathComponent:@"Contents"];
//    NSString *backupZipPath = [rootDirPath stringByAppendingPathComponent:srcZipPath.lastPathComponent];
//    self.backupDirPath = backupDirPath;
//    self.backupZipPath = backupZipPath;
//    DDLogInfo(@"%@ rootDirPath: %@", self.logTag, rootDirPath);
//    DDLogInfo(@"%@ backupDirPath: %@", self.logTag, backupDirPath);
//    DDLogInfo(@"%@ backupZipPath: %@", self.logTag, backupZipPath);
//
//    [OWSFileSystem ensureDirectoryExists:rootDirPath];
//    [OWSFileSystem protectFileOrFolderAtPath:rootDirPath];
//    [OWSFileSystem ensureDirectoryExists:backupDirPath];
//
//    NSError *error = nil;
//    BOOL success = [[NSFileManager defaultManager] copyItemAtPath:srcZipPath toPath:backupZipPath error:&error];
//    if (!success || error) {
//        OWSFail(@"%@ failed to copy backup zip: %@, %@", self.logTag, srcZipPath, error);
//        return [self fail];
//    }
//
//    if (self.isCancelledOrFailed) {
//        return;
//    }
//    if (![self unzipFilePath]) {
//        return [self fail];
//    }
//    if (self.isCancelledOrFailed) {
//        return;
//    }
//    if (![self extractEncryptionKey]) {
//        return [self fail];
//    }
//    if (self.isCancelledOrFailed) {
//        return;
//    }
//    if (![self isValidBackup]) {
//        return [self fail];
//    }
//    if (self.isCancelledOrFailed) {
//        return;
//    }
//    if (![self enqueueBackupRestore]) {
//        return [self fail];
//    }
//}
//
//- (BOOL)extractEncryptionKey
//{
//    DDLogInfo(@"%@ %s.", self.logTag, __PRETTY_FUNCTION__);
//
//    NSString *encryptionKeyFilePath =
//        [self.backupDirPath stringByAppendingPathComponent:OWSBackup_EncryptionKeyFilename];
//    if (![[NSFileManager defaultManager] fileExistsAtPath:encryptionKeyFilePath]) {
//        return NO;
//    }
//    NSData *_Nullable encryptionKeyData = [NSData dataWithContentsOfFile:encryptionKeyFilePath];
//    if (!encryptionKeyData) {
//        return NO;
//    }
//    OWSAES256Key *encryptionKey = [OWSAES256Key keyWithData:encryptionKeyData];
//    if (!encryptionKey) {
//        return NO;
//    }
//    self.encryptionKey = encryptionKey;
//
//    NSError *error = nil;
//    BOOL success = [[NSFileManager defaultManager] removeItemAtPath:encryptionKeyFilePath error:&error];
//    if (!success || error) {
//        OWSFail(@"%@ could not delete encryption key file: %@", self.logTag, error);
//        return NO;
//    }
//    return YES;
//}
//
//- (BOOL)unzipFilePath
//{
//    OWSAssert(self.backupZipPath.length > 0);
//    OWSAssert(self.backupDirPath.length > 0);
//
//    DDLogInfo(@"%@ %s.", self.logTag, __PRETTY_FUNCTION__);
//
//    // Don't use the SSZipArchive convenience methods so that we can add the
//    // encryption key directly as data.
//
//    // TODO: Should we use preserveAttributes?
//    NSError *error = nil;
//    BOOL success = [SSZipArchive unzipFileAtPath:self.backupZipPath
//        toDestination:self.backupDirPath
//        preserveAttributes:YES
//        overwrite:YES
//        nestedZipLevel:0
//        password:self.backupPassword
//        error:&error
//        delegate:self
//        progressHandler:^(NSString *entry, unz_file_info zipInfo, long entryNumber, long total) {
//            DDLogInfo(@"%@ progressHandler: %ld %ld", self.logTag, entryNumber, total);
//
//            CGFloat progress = entryNumber / (CGFloat)total;
//            self.backupProgress = progress;
//        }
//        completionHandler:^(NSString *path, BOOL succeeded, NSError *_Nullable completionError) {
//            DDLogInfo(@"%@ completionHandler: %d %@", self.logTag, succeeded, completionError);
//        }];
//    if (!success || error) {
//        OWSFail(@"%@ failed to unzip file: %@.", self.logTag, error);
//        return NO;
//    }
//
//    return YES;
//}
//
//- (BOOL)isValidBackup
//{
//    NSString *databasePasswordFilePath =
//        [self.backupDirPath stringByAppendingPathComponent:OWSBackup_DatabasePasswordFilename];
//    if (![[NSFileManager defaultManager] fileExistsAtPath:databasePasswordFilePath]) {
//        return NO;
//    }
//    NSString *standardUserDefaultsFilePath =
//        [self.backupDirPath stringByAppendingPathComponent:OWSBackup_StandardUserDefaultsFilename];
//    if (![[NSFileManager defaultManager] fileExistsAtPath:standardUserDefaultsFilePath]) {
//        return NO;
//    }
//    NSString *appUserDefaultsFilePath =
//        [self.backupDirPath stringByAppendingPathComponent:OWSBackup_AppUserDefaultsFilename];
//    if (![[NSFileManager defaultManager] fileExistsAtPath:appUserDefaultsFilePath]) {
//        return NO;
//    }
//    // TODO: Verify that the primary database exists.
//
//    return YES;
//}
//
//- (BOOL)enqueueBackupRestore
//{
//    DDLogInfo(@"%@ %s.", self.logTag, __PRETTY_FUNCTION__);
//
//    NSError *error = nil;
//    [SAMKeychain setAccessibilityType:kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly];
//    BOOL success = [SAMKeychain setPasswordData:self.encryptionKey.keyData
//                                     forService:Keychain_ImportBackupService
//                                        account:Keychain_ImportBackupKey
//                                          error:&error];
//    if (!success || error) {
//        OWSFail(@"%@ Could not store encryption key for import backup: %@", self.logTag, error);
//        return NO;
//    }
//
//    NSString *documentDirectoryPath = OWSFileSystem.appDocumentDirectoryPath;
//    NSString *relativePath = [self relativePathforPath:self.backupDirPath basePath:documentDirectoryPath];
//    [[NSUserDefaults appUserDefaults] setObject:relativePath forKey:NSUserDefaults_QueuedBackupPath];
//    [[NSUserDefaults appUserDefaults] synchronize];
//
//    return YES;
//}
//
//#pragma mark - Import Backup, Part 2
//
//- (void)completeImportBackupIfPossible
//{
//    OWSAssertIsOnMainThread();
//    OWSAssert(CurrentAppContext().isMainApp);
//
//    DDLogInfo(@"%@ %s.", self.logTag, __PRETTY_FUNCTION__);
//
//    NSString *_Nullable queuedBackupRelativePath =
//        [[NSUserDefaults appUserDefaults] stringForKey:NSUserDefaults_QueuedBackupPath];
//    if (queuedBackupRelativePath.length == 0) {
//        return;
//    }
//    NSString *documentDirectoryPath = OWSFileSystem.appDocumentDirectoryPath;
//    NSString *_Nullable queuedBackupPath =
//        [self joinRelativePath:queuedBackupRelativePath basePath:documentDirectoryPath];
//    if (![[NSFileManager defaultManager] fileExistsAtPath:queuedBackupPath]) {
//        OWSFail(@"%@ Missing import backup directory: %@.", self.logTag, queuedBackupPath);
//        return;
//    }
//    self.backupDirPath = queuedBackupPath;
//    self.backupState = OWSBackupState_InProgress;
//    DDLogInfo(@"%@ queuedBackupPath: %@", self.logTag, queuedBackupPath);
//
//    [SAMKeychain setAccessibilityType:kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly];
//    NSError *error;
//    NSData *_Nullable encryptionKeyData =
//        [SAMKeychain passwordDataForService:Keychain_ImportBackupService account:Keychain_ImportBackupKey
//        error:&error];
//    if (!encryptionKeyData || error) {
//        OWSFail(@"%@ Could not retrieve encryption key for import backup: %@", self.logTag, error);
//        return;
//    }
//    self.encryptionKey = [OWSAES256Key keyWithData:encryptionKeyData];
//
//    if (![self isValidBackup]) {
//        return;
//    }
//
//    NSData *_Nullable databasePassword = [self readDataFromFileName:OWSBackup_DatabasePasswordFilename];
//    if (!databasePassword) {
//        OWSFail(@"%@ Could not retrieve database password.", self.logTag);
//        return;
//    }
//
//    // We can't restore a backup atomically, so we:
//    //
//    // * Ensure the restore consists only of tiny writes, and file moves.
//    // * Write the database password last.
//    if (![self loadUserDefaults:NSUserDefaults.standardUserDefaults fileName:OWSBackup_StandardUserDefaultsFilename])
//    {
//        return;
//    }
//    if (![self loadUserDefaults:NSUserDefaults.appUserDefaults fileName:OWSBackup_AppUserDefaultsFilename]) {
//        return;
//    }
//
//    if (![self restoreDirectoryContents:OWSFileSystem.appDocumentDirectoryPath
//                             srcDirName:OWSBackup_AppDocumentDirName]) {
//        return;
//    }
//    if (![self restoreDirectoryContents:OWSFileSystem.appSharedDataDirectoryPath
//                             srcDirName:OWSBackup_AppSharedDataDirName]) {
//        return;
//    }
//
//    // TODO: Possibly verify database file location?
//
//    [OWSStorage storeDatabasePassword:[[NSString alloc] initWithData:databasePassword encoding:NSUTF8StringEncoding]];
//}
//
//- (nullable NSData *)readDataFromFileName:(NSString *)fileName
//{
//    OWSAssert(fileName.length > 0);
//    OWSAssert(self.backupDirPath.length > 0);
//    OWSAssert(self.encryptionKey);
//
//    NSString *filePath = [self.backupDirPath stringByAppendingPathComponent:fileName];
//
//    DDLogInfo(@"%@ readDataFromFileName: %@", self.logTag, filePath);
//
//    NSData *_Nullable encryptedData = [NSData dataWithContentsOfFile:filePath];
//    if (!encryptedData) {
//        OWSFail(@"%@ failed to read encrypted data: %@", self.logTag, fileName);
//        return nil;
//    }
//
//    NSData *_Nullable data = [Cryptography decryptAESGCMWithData:encryptedData key:self.encryptionKey];
//    if (!data) {
//        OWSFail(@"%@ failed to decrypt data: %@", self.logTag, fileName);
//        return nil;
//    }
//
//    return data;
//}
//
//- (BOOL)loadUserDefaults:(NSUserDefaults *)userDefaults fileName:(NSString *)fileName
//{
//    OWSAssert(userDefaults);
//    OWSAssert(fileName.length > 0);
//    OWSAssert(self.backupDirPath.length > 0);
//    OWSAssert(self.encryptionKey);
//
//    DDLogInfo(@"%@ loadUserDefaults: %@", self.logTag, fileName);
//
//    NSData *_Nullable data = [self readDataFromFileName:fileName];
//    if (!data) {
//        OWSFail(@"%@ Could not retrieve user defaults: %@.", self.logTag, fileName);
//        return NO;
//    }
//
//    NSError *error;
//    NSDictionary<NSString *, id> *_Nullable dictionary =
//        [NSKeyedUnarchiver unarchiveTopLevelObjectWithData:data error:&error];
//    if (!dictionary || error) {
//        OWSFail(@"%@ Could not unarchive user defaults: %@", self.logTag, error);
//        return NO;
//    }
//    if (![dictionary isKindOfClass:[NSDictionary class]]) {
//        OWSFail(@"%@ Unexpected archived user defaults: %@", self.logTag, error);
//        return NO;
//    }
//
//    // Clear out any existing keys in this instance of NSUserDefaults.
//    for (NSString *key in userDefaults.dictionaryRepresentation) {
//        [userDefaults removeObjectForKey:key];
//    }
//
//    // TODO: this doesn't yet remove any keys, so you end up with the "union".
//    for (NSString *key in dictionary) {
//        id value = dictionary[key];
//        OWSAssert(value);
//        [userDefaults setObject:value forKey:key];
//    }
//
//    [userDefaults synchronize];
//
//    return YES;
//}
//
//- (BOOL)renameDirectoryContents:(NSString *)dirPath
//{
//    OWSAssert(dirPath.length > 0);
//
//    DDLogInfo(@"%@ renameDirectoryContents: %@", self.logTag, dirPath);
//
//    NSError *error = nil;
//    NSArray<NSString *> *fileNames = [[NSFileManager defaultManager] contentsOfDirectoryAtPath:dirPath error:&error];
//    if (error) {
//        OWSFail(@"%@ failed to list directory: %@, %@", self.logTag, dirPath, error);
//        return NO;
//    }
//    for (NSString *fileName in fileNames) {
//        if ([fileName hasPrefix:@"."]) {
//            // Ignore hidden files and directories.
//            continue;
//        }
//        NSString *filePath = [dirPath stringByAppendingPathComponent:fileName];
//
//        // To replace an existing file or directory, rename the existing item
//        // by adding a date/time suffix.
//        NSDateFormatter *dateFormatter = [NSDateFormatter new];
//        [dateFormatter setLocale:[NSLocale currentLocale]];
//        [dateFormatter setDateFormat:@".yyyy.MM.dd hh.mm.ss"];
//        NSString *replacementDateTime = [dateFormatter stringFromDate:[NSDate new]];
//
//        // Prefix with period to prevent subsequent backups from including these old, replaced
//        // files and directories.
//        NSString *renamedFileName = [NSString stringWithFormat:@".Old.%@.%@", fileName, replacementDateTime];
//        NSString *renamedFilePath = [dirPath stringByAppendingPathComponent:renamedFileName];
//        BOOL success = [[NSFileManager defaultManager] moveItemAtPath:filePath toPath:renamedFilePath error:&error];
//        if (!success || error) {
//            OWSFail(@"%@ failed to move directory item: %@, %@", self.logTag, filePath, error);
//            return NO;
//        }
//        if (![OWSFileSystem protectFileOrFolderAtPath:renamedFilePath]) {
//            OWSFail(@"%@ failed to protect old directory item: %@, %@", self.logTag, renamedFilePath, error);
//            return NO;
//        }
//    }
//
//    return YES;
//}
//
//- (BOOL)restoreDirectoryContents:(NSString *)dstDirPath srcDirName:(NSString *)srcDirName
//{
//    OWSAssert(srcDirName.length > 0);
//    OWSAssert(dstDirPath.length > 0);
//    OWSAssert(self.backupDirPath.length > 0);
//
//    // Rename any existing files and directories in this directory.
//    if (![self renameDirectoryContents:dstDirPath]) {
//        return NO;
//    }
//
//    NSString *srcDirPath = [self.backupDirPath stringByAppendingPathComponent:srcDirName];
//
//    DDLogInfo(@"%@ restoreDirectoryContents: %@ -> %@", self.logTag, srcDirPath, dstDirPath);
//
//    if (![[NSFileManager defaultManager] fileExistsAtPath:srcDirPath]) {
//        // Not all backups will have both a "app documents" and "shared data container" folder.
//        // The latter should always be present for "modern" installs, but we are permissive
//        // here about what we accept so that we can easily apply this branch to historic
//        // (pre-shared data container) versions of the app and restore from them.
//        DDLogInfo(@"%@ Skipping restore directory: %@.", self.logTag, srcDirPath);
//        return YES;
//    }
//
//    NSError *error = nil;
//    NSArray<NSString *> *fileNames = [[NSFileManager defaultManager] contentsOfDirectoryAtPath:srcDirPath
//    error:&error]; if (error) {
//        OWSFail(@"%@ failed to list directory: %@, %@", self.logTag, srcDirPath, error);
//        return NO;
//    }
//    for (NSString *fileName in fileNames) {
//        if ([fileName hasPrefix:@"."]) {
//            // Ignore hidden files and directories.
//            OWSFail(@"%@ can't restore hidden file or directory: %@", self.logTag, fileName);
//            continue;
//        }
//        NSString *srcFilePath = [srcDirPath stringByAppendingPathComponent:fileName];
//        NSString *dstFilePath = [dstDirPath stringByAppendingPathComponent:fileName];
//
//        if ([[NSFileManager defaultManager] fileExistsAtPath:dstFilePath]) {
//            // All conflicting contents should have already been moved by renameDirectoryContents.
//            OWSFail(@"%@ unexpected pre-existing file or directory: %@", self.logTag, fileName);
//            continue;
//        }
//
//        BOOL success = [[NSFileManager defaultManager] moveItemAtPath:srcFilePath toPath:dstFilePath error:&error];
//        if (!success || error) {
//            OWSFail(@"%@ failed to move directory item: %@, %@", self.logTag, dstFilePath, error);
//            return NO;
//        }
//        if (![OWSFileSystem protectFileOrFolderAtPath:dstFilePath]) {
//            OWSFail(@"%@ failed to protect directory item: %@, %@", self.logTag, dstFilePath, error);
//            return NO;
//        }
//    }
//
//    return YES;
//}
//
//#pragma mark - Clean up
//
//+ (void)cleanupBackupState
//{
//    DDLogInfo(@"%@ %s.", self.logTag, __PRETTY_FUNCTION__);
//
//    [self cleanupBackupDirectoriesInDirectory:NSTemporaryDirectory()];
//    [self cleanupBackupDirectoriesInDirectory:OWSFileSystem.appDocumentDirectoryPath];
//
//    [[NSUserDefaults appUserDefaults] removeObjectForKey:NSUserDefaults_QueuedBackupPath];
//    [[NSUserDefaults appUserDefaults] synchronize];
//}
//
//+ (void)cleanupBackupDirectoriesInDirectory:(NSString *)dirPath
//{
//    OWSAssert(dirPath.length > 0);
//
//    NSError *error;
//    NSArray<NSString *> *filenames = [[NSFileManager defaultManager] contentsOfDirectoryAtPath:dirPath error:&error];
//    if (error) {
//        OWSFail(@"%@ could not find files in directory: %@", self.logTag, error);
//        return;
//    }
//
//    for (NSString *filename in filenames) {
//        if (![filename hasPrefix:OWSBackup_DirNamePrefix]) {
//            continue;
//        }
//        NSString *filePath = [dirPath stringByAppendingPathComponent:filename];
//        BOOL success = [[NSFileManager defaultManager] removeItemAtPath:filePath error:&error];
//        if (!success || error) {
//            OWSFail(@"%@ could not clean up backup directory: %@", self.logTag, error);
//            return;
//        }
//    }
//}
//
//#pragma mark - Utils
//
//- (NSString *)relativePathforPath:(NSString *)filePath basePath:(NSString *)basePath
//{
//    OWSAssert(filePath.stringByStandardizingPath.length > 0);
//    OWSAssert([filePath.stringByStandardizingPath hasPrefix:basePath.stringByStandardizingPath]);
//
//    NSString *relativePath =
//        [filePath.stringByStandardizingPath substringFromIndex:basePath.stringByStandardizingPath.length];
//    NSString *separator = @"/";
//    if ([relativePath hasPrefix:separator]) {
//        relativePath = [relativePath substringFromIndex:separator.length];
//    }
//    OWSAssert(relativePath.length > 0);
//    return relativePath;
//}
//
//- (NSString *)joinRelativePath:(NSString *)relativePath basePath:(NSString *)basePath
//{
//    OWSAssert(basePath.stringByStandardizingPath.length > 0);
//    OWSAssert(relativePath.length > 0);
//
//    return [basePath stringByAppendingPathComponent:relativePath];
//}
//
//#pragma mark - App Launch
//
//+ (void)applicationDidFinishLaunching
//{
//    [[OWSBackup new] completeImportBackupIfPossible];
//
//    // Always clean up backup state on disk, but defer so as not to interface with
//    // app launch sequence.
//    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 1 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
//        [OWSBackup cleanupBackupState];
//    });
//}
//
//#pragma mark - SSZipArchiveDelegate
//
//- (void)zipArchiveProgressEvent:(unsigned long long)loaded total:(unsigned long long)total
//{
//    DDLogInfo(@"%@ zipArchiveProgressEvent: %llu %llu", self.logTag, loaded, total);
//
//    CGFloat progress = loaded / (CGFloat)total;
//    self.backupProgress = progress;
//}

@end

NS_ASSUME_NONNULL_END
