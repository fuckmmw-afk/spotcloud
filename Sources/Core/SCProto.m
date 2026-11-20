#import "SCProto.h"

@implementation SCProtoField
@end

static BOOL readVarint(const uint8_t *b, NSUInteger length, NSUInteger *i, uint64_t *out) {
    uint64_t value = 0;
    for (int shift = 0; shift < 64 && *i < length; shift += 7) {
        uint8_t c = b[(*i)++];
        value |= (uint64_t)(c & 0x7f) << shift;
        if (c < 0x80) { *out = value; return YES; }
    }
    return NO;
}

NSArray<SCProtoField *> *SCProtoParse(NSData *message) {
    const uint8_t *b = message.bytes;
    NSUInteger length = message.length, i = 0;
    NSMutableArray *fields = [NSMutableArray array];
    while (i < length) {
        NSUInteger start = i;
        uint64_t key = 0;
        if (!readVarint(b, length, &i, &key)) return nil;
        uint32_t number = (uint32_t)(key >> 3), type = (uint32_t)(key & 7);
        if (number == 0) return nil;
        SCProtoField *field = [SCProtoField new];
        field.number = number;
        field.wireType = type;
        uint64_t n = 0;
        switch (type) {
            case 0: if (!readVarint(b, length, &i, &n)) return nil; break;
            case 1: if (i + 8 > length) return nil; i += 8; break;
            case 5: if (i + 4 > length) return nil; i += 4; break;
            case 2:
                if (!readVarint(b, length, &i, &n) || n > length - i) return nil;
                field.value = [message subdataWithRange:NSMakeRange(i, (NSUInteger)n)];
                i += (NSUInteger)n;
                break;
            default: return nil;
        }
        field.raw = [message subdataWithRange:NSMakeRange(start, i - start)];
        [fields addObject:field];
    }
    return fields;
}

void SCProtoAppendVarint(NSMutableData *out, uint64_t value) {
    uint8_t buffer[10];
    int n = 0;
    do {
        uint8_t c = value & 0x7f;
        value >>= 7;
        buffer[n++] = value ? (c | 0x80) : c;
    } while (value);
    [out appendBytes:buffer length:n];
}

void SCProtoAppendVarintField(NSMutableData *out, uint32_t number, uint64_t value) {
    SCProtoAppendVarint(out, (uint64_t)number << 3);
    SCProtoAppendVarint(out, value);
}

void SCProtoAppendBytesField(NSMutableData *out, uint32_t number, NSData *bytes) {
    SCProtoAppendVarint(out, (uint64_t)number << 3 | 2);
    SCProtoAppendVarint(out, bytes.length);
    [out appendData:bytes];
}

void SCProtoAppendStringField(NSMutableData *out, uint32_t number, NSString *string) {
    SCProtoAppendBytesField(out, number, [string dataUsingEncoding:NSUTF8StringEncoding] ?: [NSData data]);
}

static NSData *replaceIn(NSData *message, NSData *old, NSData *replacement, int depth) {
    if (depth > 24 || [message rangeOfData:old options:0 range:NSMakeRange(0, message.length)].location == NSNotFound) return nil;
    NSArray<SCProtoField *> *fields = SCProtoParse(message);
    if (!fields) return nil;
    NSMutableData *out = [NSMutableData dataWithCapacity:message.length + replacement.length];
    BOOL changed = NO;
    for (SCProtoField *field in fields) {
        NSData *value = field.value;
        if (field.wireType == 2 && value) {
            NSData *updated = [value isEqualToData:old] ? replacement : replaceIn(value, old, replacement, depth + 1);
            if (updated) {
                SCProtoAppendBytesField(out, field.number, updated);
                changed = YES;
                continue;
            }
        }
        [out appendData:field.raw];
    }
    return changed ? out : nil;
}

NSData *SCProtoReplaceString(NSData *message, NSString *old, NSString *replacement) {
    NSData *o = [old dataUsingEncoding:NSUTF8StringEncoding], *r = [replacement dataUsingEncoding:NSUTF8StringEncoding];
    if (!o.length || !r || [o isEqualToData:r]) return nil;
    return replaceIn(message, o, r, 0);
}

NSArray<NSString *> *SCProtoStringsWithPrefix(NSData *bytes, NSString *prefix) {
    NSData *needle = [prefix dataUsingEncoding:NSUTF8StringEncoding];
    const uint8_t *b = bytes.bytes;
    NSUInteger length = bytes.length;
    NSMutableOrderedSet *found = [NSMutableOrderedSet orderedSet];
    NSRange search = NSMakeRange(0, length);
    while (needle.length && search.length) {
        NSRange hit = [bytes rangeOfData:needle options:0 range:search];
        if (hit.location == NSNotFound) break;
        NSUInteger p = hit.location;
        // The string's length is the varint just before it: one byte (< 128) or two.
        NSUInteger n = 0;
        if (p >= 1 && b[p - 1] < 0x80 && b[p - 1] >= needle.length) n = b[p - 1];
        if (p >= 2 && b[p - 2] >= 0x80 && b[p - 1] < 0x80) {
            NSUInteger two = (b[p - 2] & 0x7f) | ((NSUInteger)b[p - 1] << 7);
            if (two >= 128) n = two;
        }
        if (n && p + n <= length) {
            NSString *s = [[NSString alloc] initWithData:[bytes subdataWithRange:NSMakeRange(p, n)] encoding:NSUTF8StringEncoding];
            if (s) [found addObject:s];
        }
        search = NSMakeRange(p + needle.length, length - p - needle.length);
    }
    return found.array;
}
