#ifndef LEDGE_MEDIA_ADAPTER_H
#define LEDGE_MEDIA_ADAPTER_H

#import <Foundation/Foundation.h>

/// The single entry point, installed as a Perl XSUB by the launcher script.
///
/// It takes no arguments on purpose: an XSUB installed through
/// `DynaLoader::dl_install_xsub` is called with Perl's own `(pTHX_ CV *)`,
/// which a plain C function cannot read without linking libperl. Every
/// parameter therefore arrives through the environment instead.
///
/// Reads `LEDGE_ADAPTER_MODE` (`get` or `stream`) and `LEDGE_ADAPTER_ARTWORK`
/// (`1` to include base64 artwork). Writes newline-delimited JSON to stdout.
__attribute__((visibility("default")))
void ledge_media_adapter_main(void);

/// The host of a media asset URL, and whether it came from inside a `blob:`
/// URL — the parser the adapter uses, exported so it can be tested directly.
///
/// Exported rather than reimplemented in Swift: this is the one piece of the
/// origin path that decides what counts as evidence of a website, and a
/// second copy of it in another language would be a second thing to keep
/// right. The test calls exactly what the helper calls.
///
/// Returns nil for anything that is not an ordinary `http(s)` resource: a
/// file, a non-web scheme, a malformed string. Never returns a path, a query
/// or a fragment — only the host.
///
/// - Parameter fromBlob: set to YES when the host came from a blob's inner
///   URL, which is the only case that stands for a web content origin. May be
///   NULL.
__attribute__((visibility("default")))
NSString *_Nullable ledge_media_adapter_host_of_asset(
    NSString *_Nullable text, BOOL *_Nullable fromBlob
);

#endif
