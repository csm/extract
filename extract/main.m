//
//  main.m
//  extract
//
//  Created by Casey Marshall on 5/3/13.
//  Copyright (c) 2013 Memeo, Inc. All rights reserved.
//

#import <Foundation/Foundation.h>
#import <CoreFoundation/CFPlugInCOM.h>
#import <getopt.h>

static const NSString *kSystemPluginsDir = @"/System/Library/Spotlight";
static const NSString *kPluginsDir = @"/Library/Spotlight";

typedef struct {
    IUNKNOWN_C_GUTS;
    Boolean (*GetMetadataForFile)(void *myInstance,
                                  CFMutableDictionaryRef attributes,
                                  CFStringRef contentTypeUTI,
                                  CFStringRef pathToFile);
} IMetadataImporter;

int main(int argc, const char * argv[])
{
    @autoreleasepool {
        NSError *error = nil;
        NSFileManager *fm = [NSFileManager defaultManager];
        
        if (optind >= argc)
        {
            fprintf(stderr, "usage: %s [-o outfile] infile\n", argv[0]);
            exit(EXIT_FAILURE);
        }

        NSString *outfile = nil;
        int ch = 0;
        while ((ch = getopt(argc, argv, "ho:")) != -1)
        {
            switch (ch) {
                case 'h':
                    fprintf(stderr, "usage: %s [-o outfile] infile\n", argv[0]);
                    exit(EXIT_SUCCESS);
                case 'o':
                    outfile = [NSString stringWithCString: optarg encoding: NSUTF8StringEncoding];
                    break;
                default:
                    fprintf(stderr, "usage: %s [-o outfile] infile\n", argv[0]);
                    exit(EXIT_FAILURE);
            }
        }
        
        NSFileHandle *output = nil;
        if (outfile) {
            if (![outfile isAbsolutePath])
                outfile = [[[fm currentDirectoryPath] stringByAppendingPathComponent: outfile] stringByStandardizingPath];
            if (![fm fileExistsAtPath: outfile])
                [fm createFileAtPath: outfile
                            contents: nil
                          attributes: nil];
            output = [NSFileHandle fileHandleForWritingAtPath: outfile];
            if (!output) {
                fprintf(stderr, "can't open %s for writing\n", [outfile cStringUsingEncoding: NSUTF8StringEncoding]);
                exit(EXIT_FAILURE);
            }
        } else {
            output = [NSFileHandle fileHandleWithStandardOutput];
        }

        NSMutableArray *plugins = [NSMutableArray array];
        if ([fm fileExistsAtPath: kSystemPluginsDir]) {
            NSArray *contents = [fm contentsOfDirectoryAtPath: kSystemPluginsDir
                                                        error: &error];
            if (contents == nil)
            {
                NSLog(@"failed to enumerate %@: %@", kSystemPluginsDir, [error localizedDescription]);
            }
            else
            {
                for (id obj in contents)
                {
                    if (![obj hasSuffix: @".mdimporter"]) continue;
                    NSURL *url = [NSURL URLWithString: [NSString stringWithFormat: @"file://%@/%@", kSystemPluginsDir,
                                                        [obj stringByAddingPercentEscapesUsingEncoding: NSUTF8StringEncoding]]];
                    NSLog(@"loading %@", url);
                    CFPlugInRef plugin = CFPlugInCreate(kCFAllocatorDefault, (__bridge CFURLRef)(url));
                    [plugins addObject: CFBridgingRelease(plugin)];
                }
            }
        }
        if ([fm fileExistsAtPath: kPluginsDir])
        {
            NSArray *contents = [fm contentsOfDirectoryAtPath: kPluginsDir
                                                        error: &error];
            if (contents == nil)
            {
                NSLog(@"failed to enumerate %@: %@", kPluginsDir, [error localizedDescription]);
            }
            else
            {
                for (id obj in contents)
                {
                    if (![obj hasSuffix: @".mdimporter"]) continue;
                    NSLog(@"%@", obj);
                    NSURL *url = [NSURL URLWithString: [NSString stringWithFormat: @"file://%@/%@", kPluginsDir,
                                                        [obj stringByAddingPercentEscapesUsingEncoding: NSUTF8StringEncoding]]];
                    NSLog(@"loading %@", url);
                    CFPlugInRef plugin = CFPlugInCreate(kCFAllocatorDefault, (__bridge CFURLRef)(url));
                    [plugins addObject: CFBridgingRelease(plugin)];
                }
            }
        }
        
        NSString *infile = [NSString stringWithCString: argv[optind]
                                              encoding: NSUTF8StringEncoding];
        if (![infile isAbsolutePath]) {
            infile = [[fm currentDirectoryPath] stringByAppendingPathComponent: infile];
        }
        infile = [infile stringByStandardizingPath];
        
        NSString *extension = [infile pathExtension];
        NSURL *url = [NSURL URLWithString: [infile stringByAddingPercentEscapesUsingEncoding: NSUTF8StringEncoding]];
        CFStringRef fileUTI = UTTypeCreatePreferredIdentifierForTag(kUTTagClassFilenameExtension, (__bridge CFStringRef)(extension), NULL);
        if (!fileUTI)
        {
            // No output, no text.
            exit(EXIT_SUCCESS);
        }
        
        NSMutableDictionary *attr = [NSMutableDictionary dictionary];
        for (id obj in plugins)
        {
            CFPlugInRef plugin = (__bridge CFPlugInRef)(obj);
            NSLog(@"type %ld", CFGetTypeID(plugin));
            NSLog(@"type desc %@", CFCopyTypeIDDescription(CFGetTypeID(plugin)));
            CFBundleRef bundle = CFPlugInGetBundle(plugin);
            NSLog(@"trying plugin %@", CFBundleGetIdentifier(bundle));
            id docTypes = (__bridge id)(CFBundleGetValueForInfoDictionaryKey(bundle, CFSTR("CFBundleDocumentTypes")));
            if (![docTypes isKindOfClass: [NSArray class]])
                continue;
            BOOL utiMatch = NO;
            NSLog(@"looking up UTI %@ in %@", fileUTI, docTypes);
            for (id val in docTypes) {
                if ([val isKindOfClass: [NSDictionary class]]) {
                    if ([[val valueForKey: @"CFBundleTypeRole"] isEqual: @"MDImporter"]) {
                        id val2 = [val valueForKey: @"LSItemContentTypes"];
                        if ([val2 isKindOfClass: [NSArray class]] && [val2 indexOfObject: (__bridge id)(fileUTI)] != NSNotFound) {
                            utiMatch = YES;
                            break;
                        }
                    }
                }
            }
            if (!utiMatch)
                continue;
            CFArrayRef factoryIDs = CFPlugInFindFactoriesForPlugInTypeInPlugIn(kMDImporterTypeID, plugin);
            NSMutableArray *importers = [NSMutableArray arrayWithCapacity: CFArrayGetCount(factoryIDs)];
            for (int i = 0; i < CFArrayGetCount(factoryIDs); i++)
            {
                IMetadataImporter **importer = NULL;
                CFUUIDRef uuid = (CFUUIDRef) CFArrayGetValueAtIndex(factoryIDs, i);
                IUnknownVTbl **vtbl = CFPlugInInstanceCreate(NULL, uuid, kMDImporterTypeID);
                if (vtbl)
                {
                    (*vtbl)->QueryInterface(vtbl, CFUUIDGetUUIDBytes(kMDImporterInterfaceID), (LPVOID *)(&importer));
                    (*vtbl)->Release(vtbl);
                    if (importer != NULL)
                    {
                        (*importer)->GetMetadataForFile(plugin, (__bridge CFMutableDictionaryRef)(attr), fileUTI, (__bridge CFStringRef)(infile));
                        id value = [attr objectForKey: kMDItemTextContent];
                        if ([value isKindOfClass: [NSString class]]) {
                            [output writeData: [value dataUsingEncoding: NSUTF8StringEncoding]];
                            exit(0);
                        }
                        [attr removeAllObjects];
                    }
                }
            }
        }
    }
    return 0;
}

