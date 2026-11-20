#import "SCModels.h"

NS_ASSUME_NONNULL_BEGIN

// A title for comparing: lowercase, without emoji, "official ...", "free dl", "prod. ...", the uploader's
// nick and punctuation.
NSString *SCNormalizedTitle(NSString *title, NSString *_Nullable artist, NSString *_Nullable username);
// The remix-like words a title has ("remix", "mashup", "edit", "bootleg", "flip", "vip", "sped up",
// "slowed"), sorted and joined; "" for an original. Only titles with the same tags can be duplicates.
NSString *SCVariantTags(NSString *title);
// 0...1, Jaro-Winkler.
double SCTitleSimilarity(NSString *a, NSString *b);
// Duplicates: same variant tags, similar normalized titles (>= 0.88) and durations within 3 s.
BOOL SCTracksAreDuplicates(SCTrack *a, SCTrack *b);
// One track per group of duplicates, in the order the groups first appear: the upload whose uploader is
// the artist, else the one played most.
NSArray<SCTrack *> *SCDeduplicate(NSArray<SCTrack *> *tracks);

NS_ASSUME_NONNULL_END
