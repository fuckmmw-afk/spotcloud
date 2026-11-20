#import <Foundation/Foundation.h>

// One line to the system log and to Documents/SpotCloud/spotcloud.log (rotated at 2 MB), from any thread
// but the audio render thread.
void SCLog(NSString *area, NSString *format, ...) NS_FORMAT_FUNCTION(2, 3);
// Documents/SpotCloud, created on first use.
NSString *SCSupportDirectory(void);
