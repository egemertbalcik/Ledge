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
    // The handler is copied so it outlives the caller's frame; the listener
    // block wrapping it is copied separately and is what CoreAudio matches on.
    void (^ownedHandler)(void) = Block_copy(handler);
    AudioObjectPropertyListenerBlock block = Block_copy(
        ^(UInt32 count, const AudioObjectPropertyAddress *addresses) {
            (void)count;
            (void)addresses;
            ownedHandler();
        });

    OSStatus result = AudioObjectAddPropertyListenerBlock(object, &address, queue, block);
    if (status) { *status = result; }
    if (result != noErr) {
        Block_release(block);
        Block_release(ownedHandler);
        return NULL;
    }

    LedgeAudioListen *listen = calloc(1, sizeof(LedgeAudioListen));
    if (!listen) {
        AudioObjectRemovePropertyListenerBlock(object, &address, queue, block);
        Block_release(block);
        Block_release(ownedHandler);
        if (status) { *status = kAudio_MemFullError; }
        return NULL;
    }
    listen->object = object;
    listen->address = address;
    listen->queue = queue;
    dispatch_retain(listen->queue);
    listen->block = block;
    // ownedHandler is retained by `block`; releasing our own reference here
    // would be correct only if the wrapper had copied it, which it has.
    Block_release(ownedHandler);
    return listen;
}

OSStatus ledge_audio_listen_remove(LedgeAudioListen *listen)
{
    if (!listen) { return noErr; }
    OSStatus result = AudioObjectRemovePropertyListenerBlock(
        listen->object, &listen->address, listen->queue, listen->block);
    Block_release(listen->block);
    dispatch_release(listen->queue);
    free(listen);
    return result;
}

LedgeCMIOListen *ledge_cmio_listen_add(
    CMIOObjectID object,
    CMIOObjectPropertyAddress address,
    dispatch_queue_t queue,
    void (^handler)(void),
    OSStatus *status)
{
    void (^ownedHandler)(void) = Block_copy(handler);
    CMIOObjectPropertyListenerBlock block = Block_copy(
        ^(UInt32 count, const CMIOObjectPropertyAddress *addresses) {
            (void)count;
            (void)addresses;
            ownedHandler();
        });

    OSStatus result = CMIOObjectAddPropertyListenerBlock(object, &address, queue, block);
    if (status) { *status = result; }
    if (result != noErr) {
        Block_release(block);
        Block_release(ownedHandler);
        return NULL;
    }

    LedgeCMIOListen *listen = calloc(1, sizeof(LedgeCMIOListen));
    if (!listen) {
        CMIOObjectRemovePropertyListenerBlock(object, &address, queue, block);
        Block_release(block);
        Block_release(ownedHandler);
        if (status) { *status = kAudio_MemFullError; }
        return NULL;
    }
    listen->object = object;
    listen->address = address;
    listen->queue = queue;
    dispatch_retain(listen->queue);
    listen->block = block;
    Block_release(ownedHandler);
    return listen;
}

OSStatus ledge_cmio_listen_remove(LedgeCMIOListen *listen)
{
    if (!listen) { return noErr; }
    OSStatus result = CMIOObjectRemovePropertyListenerBlock(
        listen->object, &listen->address, listen->queue, listen->block);
    Block_release(listen->block);
    dispatch_release(listen->queue);
    free(listen);
    return result;
}
