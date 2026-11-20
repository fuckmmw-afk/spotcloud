#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

// Just enough protobuf wire format to edit Spotify's messages without their schemas.
@interface SCProtoField : NSObject
@property (nonatomic) uint32_t number;
@property (nonatomic) uint32_t wireType;
@property (nonatomic, copy) NSData *raw;            // key + value, as on the wire
@property (nonatomic, copy, nullable) NSData *value; // the payload of a length-delimited field
@end

// Top-level fields in order; nil when the bytes are not a message.
NSArray<SCProtoField *> *_Nullable SCProtoParse(NSData *message);
void SCProtoAppendVarint(NSMutableData *out, uint64_t value);
void SCProtoAppendVarintField(NSMutableData *out, uint32_t number, uint64_t value);
void SCProtoAppendBytesField(NSMutableData *out, uint32_t number, NSData *bytes);
void SCProtoAppendStringField(NSMutableData *out, uint32_t number, NSString *string);
// Every length-delimited value equal to `old`, at any depth, replaced by `replacement` (lengths of the
// messages around it fixed up). nil when nothing matched.
NSData *_Nullable SCProtoReplaceString(NSData *message, NSString *old, NSString *replacement);
// Every string starting with `prefix` anywhere in the bytes, in order, without duplicates.
NSArray<NSString *> *SCProtoStringsWithPrefix(NSData *bytes, NSString *prefix);

NS_ASSUME_NONNULL_END
