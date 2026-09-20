#ifndef LEDGE_AUDIO_LISTEN_H
#define LEDGE_AUDIO_LISTEN_H

#include <CoreAudio/CoreAudio.h>
#include <CoreMediaIO/CMIOHardware.h>
#include <dispatch/dispatch.h>

/// Registration of a CoreAudio / CoreMediaIO property listener, owned by C.
///
/// This target exists for one reason: CoreAudio matches a listener for removal
/// by the *block pointer* it was registered with, and Swift cannot hand it the
/// same pointer twice.
///
/// `AudioObjectPropertyListenerBlock` imports into Swift as a thick closure
/// (two words), not as a block (one word). Every time such a closure crosses
/// into the C function, Swift mints a fresh block to wrap it — so the pointer
/// passed to Remove is never the pointer passed to Add. Removal then matches
/// nothing, leaves the listener installed, **and returns noErr**. Nothing in
/// Swift can detect this, and no amount of care with `@convention(block)`
/// avoids it, because the re-wrapping happens at the imported signature.
///
/// Measured: 12,000 register/unregister cycles from Swift leave 12,000 live
/// listeners, and each further call costs a linear scan of all of them. In
/// production that reached 1.5 million registrations and took the main thread
/// to 100%. The same loop written here, in C, stays flat.
///
/// So the block is created, copied and kept here, and both calls use that one
/// pointer. The token is the registration: holding it is what keeps the
/// listener installed, and removing it is the only way to take it off.

typedef struct LedgeAudioListen LedgeAudioListen;
typedef struct LedgeCMIOListen LedgeCMIOListen;

/// Registers `handler` for `address` on `object`, delivered on `queue`.
///
/// - Returns: the token, or NULL if CoreAudio refused; `status` then carries
///   the reason. The token owns a copy of the handler and a reference to the
///   queue until it is removed.
LedgeAudioListen *_Nullable ledge_audio_listen_add(
    AudioObjectID object,
    AudioObjectPropertyAddress address,
    dispatch_queue_t _Nonnull queue,
    void (^_Nonnull handler)(void),
    OSStatus *_Nullable status);

/// Attempts removal.
///
/// On success the token is freed and must not be used again. **On failure the
/// token is left intact**, so the caller keeps the object, the full address,
/// the queue and the block — everything needed to try again. Freeing it on a
/// failed removal would discard the only identity by which the registration
/// could ever be taken off, which is how the leak this file exists for became
/// unrecoverable rather than merely unnoticed.
///
/// A noErr here means CoreAudio matched the pointer it was given against the
/// pointer it registered. That is a much stronger statement than it was from
/// Swift, where the two were never the same and noErr meant nothing — but it
/// is still CoreAudio's word, not proof that no callback is in flight.
OSStatus ledge_audio_listen_remove(LedgeAudioListen *_Nullable listen);

/// Gives up on a token and frees it without attempting removal.
///
/// For the case where the object is known to be gone — a device unplugged, a
/// process exited — and for the end of a bounded retry policy. The caller is
/// asserting that no further removal can succeed; anything still queued is
/// caught by the handler's own weak capture.
void ledge_audio_listen_abandon(LedgeAudioListen *_Nullable listen);

/// The same, for CoreMediaIO — cameras, which have their own object tree and
/// their own copy of this API with the identical flaw.
LedgeCMIOListen *_Nullable ledge_cmio_listen_add(
    CMIOObjectID object,
    CMIOObjectPropertyAddress address,
    dispatch_queue_t _Nonnull queue,
    void (^_Nonnull handler)(void),
    OSStatus *_Nullable status);

OSStatus ledge_cmio_listen_remove(LedgeCMIOListen *_Nullable listen);

void ledge_cmio_listen_abandon(LedgeCMIOListen *_Nullable listen);

#endif
