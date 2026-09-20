#import "include/LedgeAudioListen.h"
#include <Block.h>
#include <stdlib.h>

// The registration, kept whole: the listener block CoreAudio holds is the one
// in this struct, so Add and Remove are handed the identical pointer.
struct LedgeAudioListen {
    AudioObjectID object;
    AudioObjectPropertyAddress address;
    dispatch_queue_t queue;
    AudioObjectPropertyListenerBlock block;
};

struct LedgeCMIOListen {
    CMIOObjectID object;
    CMIOObjectPropertyAddress address;
    dispatch_queue_t queue;
    CMIOObjectPropertyListenerBlock block;
};

LedgeAudioListen *ledge_audio_listen_add(
    AudioObjectID object,
    AudioObjectPropertyAddress address,
    dispatch_queue_t queue,
    void (^handler)(void),
    OSStatus *status)
{
    // Storage first. Registering and *then* discovering there is nowhere to
    // record the token leaves a listener installed that nothing can name.
    LedgeAudioListen *listen = calloc(1, sizeof(LedgeAudioListen));
    if (!listen) {
        if (status) { *status = kAudio_MemFullError; }
        return NULL;
    }

    // The handler is copied so it outlives the caller's frame. Copying the
    // wrapper block copies what it captures, so the wrapper owns it from here.
    void (^ownedHandler)(void) = Block_copy(handler);
    AudioObjectPropertyListenerBlock block = Block_copy(
        ^(UInt32 count, const AudioObjectPropertyAddress *addresses) {
            (void)count;
            // HAL owns `addresses` for the duration of this call only; it is
            // deliberately not passed on or kept.
            (void)addresses;
            ownedHandler();
        });
    Block_release(ownedHandler);

    OSStatus result = AudioObjectAddPropertyListenerBlock(object, &address, queue, block);
    if (status) { *status = result; }
    if (result != noErr) {
        Block_release(block);
        free(listen);
        return NULL;
    }

    listen->object = object;
    listen->address = address;
    listen->queue = queue;
    dispatch_retain(listen->queue);
    listen->block = block;
    return listen;
}

OSStatus ledge_audio_listen_remove(LedgeAudioListen *listen)
{
    if (!listen) { return noErr; }
    OSStatus result = AudioObjectRemovePropertyListenerBlock(
        listen->object, &listen->address, listen->queue, listen->block);
    if (result != noErr) {
        // Keep everything. The caller decides whether to retry or abandon.
        return result;
    }
    ledge_audio_listen_abandon(listen);
    return noErr;
}

void ledge_audio_listen_abandon(LedgeAudioListen *listen)
{
    if (!listen) { return; }
    Block_release(listen->block);
    dispatch_release(listen->queue);
    free(listen);
}

LedgeCMIOListen *ledge_cmio_listen_add(
    CMIOObjectID object,
    CMIOObjectPropertyAddress address,
    dispatch_queue_t queue,
    void (^handler)(void),
    OSStatus *status)
{
    LedgeCMIOListen *listen = calloc(1, sizeof(LedgeCMIOListen));
    if (!listen) {
        if (status) { *status = kAudio_MemFullError; }
        return NULL;
    }

    void (^ownedHandler)(void) = Block_copy(handler);
    CMIOObjectPropertyListenerBlock block = Block_copy(
        ^(UInt32 count, const CMIOObjectPropertyAddress *addresses) {
            (void)count;
            (void)addresses;
            ownedHandler();
        });
    Block_release(ownedHandler);

    OSStatus result = CMIOObjectAddPropertyListenerBlock(object, &address, queue, block);
    if (status) { *status = result; }
    if (result != noErr) {
        Block_release(block);
        free(listen);
        return NULL;
    }

    listen->object = object;
    listen->address = address;
    listen->queue = queue;
    dispatch_retain(listen->queue);
    listen->block = block;
    return listen;
}

OSStatus ledge_cmio_listen_remove(LedgeCMIOListen *listen)
{
    if (!listen) { return noErr; }
    OSStatus result = CMIOObjectRemovePropertyListenerBlock(
        listen->object, &listen->address, listen->queue, listen->block);
    if (result != noErr) { return result; }
    ledge_cmio_listen_abandon(listen);
    return noErr;
}

void ledge_cmio_listen_abandon(LedgeCMIOListen *listen)
{
    if (!listen) { return; }
    Block_release(listen->block);
    dispatch_release(listen->queue);
    free(listen);
}
