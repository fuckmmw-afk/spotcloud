// Host tests for the schema-less protobuf editing and the local URI format.
#import <Foundation/Foundation.h>
#import "SCProto.h"
#import "SCLibrary.h"

static int failures = 0;
#define CHECK(cond) do { if (!(cond)) { failures++; fprintf(stderr, "FAIL %s:%d %s\n", __FILE__, __LINE__, #cond); } } while (0)

int main(void) {
    @autoreleasepool {
        // PlayRequest { 1: PreparePlayRequest { 1: Context { 1: Page { 1: Track { 1: uri } } }, 2: Options { 3: SkipTo { 3: uri } } }, 3: 7 }
        NSString *old = @"spotify:local:Artist:SoundCloud:Song+%28SC%29:200";
        NSString *longer = [old stringByAppendingString:@"-indexed-with-a-much-longer-uri-that-needs-two-length-bytes-in-its-varint-field-0123456789-0123456789"];
        NSMutableData *track = [NSMutableData data], *page = [NSMutableData data], *context = [NSMutableData data];
        SCProtoAppendStringField(track, 1, old);
        SCProtoAppendStringField(track, 2, @"uid");
        SCProtoAppendBytesField(page, 1, track);
        SCProtoAppendBytesField(context, 1, page);
        SCProtoAppendStringField(context, 3, @"spotify:search:x");
        NSMutableData *skip = [NSMutableData data], *options = [NSMutableData data], *prepare = [NSMutableData data], *play = [NSMutableData data];
        SCProtoAppendStringField(skip, 3, old);
        SCProtoAppendBytesField(options, 3, skip);
        SCProtoAppendBytesField(prepare, 1, context);
        SCProtoAppendBytesField(prepare, 2, options);
        SCProtoAppendBytesField(play, 1, prepare);
        SCProtoAppendVarintField(play, 3, 7);

        NSArray *fields = SCProtoParse(play);
        CHECK(fields.count == 2 && ((SCProtoField *)fields[0]).number == 1 && ((SCProtoField *)fields[1]).number == 3);
        CHECK(SCProtoParse([@"not a message \xff" dataUsingEncoding:NSISOLatin1StringEncoding]) == nil);
        NSArray *found = SCProtoStringsWithPrefix(play, @"spotify:local:");
        CHECK(found.count == 1 && [found.firstObject isEqualToString:old]);

        NSData *replaced = SCProtoReplaceString(play, old, longer);
        CHECK(replaced != nil);
        NSArray *after = SCProtoStringsWithPrefix(replaced, @"spotify:local:");
        CHECK(after.count == 1 && [after.firstObject isEqualToString:longer]);
        CHECK(SCProtoParse(replaced).count == 2);
        // The rewritten message still nests: PlayRequest.1.2.3.3 is the new URI.
        SCProtoField *p1 = SCProtoParse(replaced)[0];
        SCProtoField *opts = nil;
        for (SCProtoField *f in SCProtoParse(p1.value)) if (f.number == 2) opts = f;
        SCProtoField *skipTo = SCProtoParse(opts.value)[0];
        SCProtoField *uri = SCProtoParse(skipTo.value)[0];
        CHECK([[[NSString alloc] initWithData:uri.value encoding:NSUTF8StringEncoding] isEqualToString:longer]);
        CHECK(SCProtoReplaceString(play, @"spotify:local:nothing", @"x") == nil);

        // Local URIs: form-encoded parts.
        CHECK([SCLocalURI(@"Fred again..", @"SoundCloud", @"Song (SC)", 200) isEqualToString:@"spotify:local:Fred+again..:SoundCloud:Song+%28SC%29:200"]);
        CHECK([SCLocalURI(@"Ночь", @"SoundCloud", @"a:b", 5) isEqualToString:@"spotify:local:%D0%9D%D0%BE%D1%87%D1%8C:SoundCloud:a%3Ab:5"]);
    }
    if (failures) { fprintf(stderr, "%d failed\n", failures); return 1; }
    puts("all proto tests passed");
    return 0;
}
