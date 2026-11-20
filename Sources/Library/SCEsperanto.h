#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

// Spotify's Cosmos Esperanto transport, captured from Spotify's own calls (SCEsperantoHook), so SpotCloud
// can call the core's services (local files) the same way Spotify does.
void SCEsperantoSetCosmosTransport(id transport);
BOOL SCEsperantoReady(void);
// One request, one response (nil on timeout or when no transport was seen yet). Completion on a global queue.
void SCEsperantoCall(NSString *service, NSString *method, NSData *payload, NSTimeInterval timeout,
                     void (^completion)(NSData *_Nullable response));

// Local files (spotify.local_files_esperanto.proto.LocalFiles).
void SCLocalFilesEnableDocuments(void);
// Waits (up to `timeout`) until Spotify's scanner has the file tagged with this title, and answers its URI.
void SCLocalFilesFindURI(NSString *title, NSString *artist, NSTimeInterval timeout, void (^completion)(NSString *_Nullable uri));

NS_ASSUME_NONNULL_END
